import CoreGraphics
import Darwin
import Foundation
import LidAwakeShared

public enum DisplayBrightnessResult: Equatable {
    case unchanged, sampled, dimmed, restored, preservedExternalChange, pending, unavailable
}

@MainActor
public protocol DisplayBrightnessControlling {
    @discardableResult func sampleWhileOpen() -> DisplayBrightnessResult
    @discardableResult func close() -> DisplayBrightnessResult
    @discardableResult func restore() -> DisplayBrightnessResult
}

/// Accesses only the built-in display. A disconnected panel must throw, never supply a default value.
public protocol DisplayBrightnessAccess {
    func read() throws -> Float
    func write(_ brightness: Float) throws
}

public enum DisplayBrightnessError: Error {
    case unavailable, displayOffline, readFailed, writeFailed
}

/// Owns the saved brightness until restoration succeeds or an observable external change takes over.
/// Call only while an enabled session owns the lid behavior; sampling requires an open lid.
@MainActor
public final class DisplayBrightness: DisplayBrightnessControlling {
    private struct Pending: Codable {
        let brightness: Float
        var dimmed: Bool
    }

    private static let pendingKey = "displayBrightnessPendingRestore"
    private let access: DisplayBrightnessAccess
    private let defaults: UserDefaults
    private var lastOpenBrightness: Float?
    private let activityLog: ActivityLogging
    private let now: () -> Date
    private var lastObservations: [SettingEvent.Operation: SettingEvent] = [:]

    public init(access: DisplayBrightnessAccess = SystemDisplayBrightness(), defaults: UserDefaults = .standard,
                activityLog: ActivityLogging = NoActivityLog(), now: @escaping () -> Date = Date.init) {
        self.access = access
        self.defaults = defaults
        self.activityLog = activityLog
        self.now = now
    }

    public var hasPendingRestore: Bool { defaults.object(forKey: Self.pendingKey) != nil }

    @discardableResult
    public func sampleWhileOpen() -> DisplayBrightnessResult {
        guard !hasPendingRestore else { return .pending }
        guard let brightness = try? access.read(), Self.valid(brightness) else { return .unavailable }
        lastOpenBrightness = brightness
        return .sampled
    }

    @discardableResult
    public func close() -> DisplayBrightnessResult {
        var pending: Pending
        var prior: Float?
        if hasPendingRestore {
            guard let saved = readPending() else {
                record(.apply, .pending, target: 0)
                return .unavailable
            }
            pending = saved
            if pending.dimmed {
                do {
                    let current = try access.read()
                    guard Self.valid(current) else {
                        record(.apply, .pending, target: 0)
                        return .unavailable
                    }
                    if !Self.matches(current, 0) {
                        record(.apply, .externalChangePreserved, prior: pending.brightness, current: current, target: 0)
                    }
                    return Self.matches(current, 0) ? .dimmed : .preservedExternalChange
                } catch DisplayBrightnessError.displayOffline {
                    record(.apply, .pending, target: 0)
                    return .pending
                } catch {
                    record(.apply, .pending, target: 0)
                    return .unavailable
                }
            }
            if let current = try? access.read(), Self.valid(current) {
                prior = current
            }
            if let current = prior, !Self.matches(current, 0), !Self.matches(current, pending.brightness) {
                record(.apply, .externalChangePreserved, prior: pending.brightness, current: current, target: 0)
                return .preservedExternalChange
            }
        } else {
            let current: Float?
            do {
                current = try access.read()
                prior = current
            } catch DisplayBrightnessError.unavailable {
                record(.apply, .failed, target: 0)
                return .unavailable
            } catch {
                current = lastOpenBrightness
            }
            guard let current, Self.valid(current) else {
                record(.apply, .failed, target: 0)
                return .unavailable
            }
            pending = Pending(brightness: current, dimmed: false)
            // Persist the original before attempting a write, including when the panel is offline.
            guard save(pending) else {
                record(.apply, .failed, prior: prior, target: 0)
                return .unavailable
            }
        }
        do {
            try access.write(0)
            let current = try access.read()
            guard Self.matches(current, 0) else {
                record(.apply, .failed, prior: pending.brightness, current: Self.valid(current) ? current : nil, target: 0)
                return .unavailable
            }
            record(.apply, prior.map { Self.matches($0, 0) } == true ? .alreadyAtTarget : .verified,
                   prior: prior, current: current, target: 0)
            pending.dimmed = true
            // The earlier record still permits safe restoration if this second save fails.
            if !save(pending) {
                record(.apply, .pending, prior: pending.brightness, current: current, target: 0)
            }
            return .dimmed
        } catch DisplayBrightnessError.displayOffline {
            record(.apply, .pending, prior: pending.brightness, target: 0)
            return .pending
        } catch {
            record(.apply, .failed, prior: pending.brightness, target: 0)
            return .unavailable
        }
    }

    @discardableResult
    public func restore() -> DisplayBrightnessResult {
        guard hasPendingRestore else { return .unchanged }
        guard let pending = readPending() else {
            record(.restore, .pending)
            return .unavailable
        }
        do {
            let current = try access.read()
            guard Self.valid(current) else {
                record(.restore, .pending, target: pending.brightness)
                return .pending
            }
            // A nonzero value is observable evidence that zero is no longer ours to restore over.
            // This also handles a failed dim operation that left the original value untouched.
            if !Self.matches(current, 0) {
                clearPending()
                lastOpenBrightness = current
                record(.restore, Self.matches(current, pending.brightness) ? .alreadyAtTarget : .externalChangePreserved,
                       prior: current, current: current, target: pending.brightness)
                return Self.matches(current, pending.brightness) ? .unchanged : .preservedExternalChange
            }
            try access.write(pending.brightness)
            let restored = try access.read()
            guard Self.matches(restored, pending.brightness) else {
                record(.restore, .pending, prior: current, current: Self.valid(restored) ? restored : nil, target: pending.brightness)
                return .pending
            }
            record(.restore, Self.matches(current, pending.brightness) ? .alreadyAtTarget : .verified,
                   prior: current, current: restored, target: pending.brightness)
            clearPending()
            lastOpenBrightness = pending.brightness
            return .restored
        } catch DisplayBrightnessError.unavailable {
            record(.restore, .pending, target: pending.brightness)
            return .unavailable
        } catch {
            record(.restore, .pending, target: pending.brightness)
            return .pending
        }
    }

    private func record(_ operation: SettingEvent.Operation, _ outcome: SettingEvent.Outcome,
                        prior: Float? = nil, current: Float? = nil, target: Float? = nil) {
        let event = SettingEvent(time: now(), setting: .brightness, source: .builtInDisplay,
            operation: operation, outcome: outcome, key: .brightness,
            prior: prior.map(Double.init), current: current.map(Double.init), target: target.map(Double.init))
        if outcome != .verified, let last = lastObservations[operation],
           last.operation == event.operation, last.outcome == event.outcome, last.prior == event.prior,
           last.current == event.current, last.target == event.target { return }
        lastObservations[operation] = event
        activityLog.record(.setting(event), at: event.time)
    }

    private static func valid(_ brightness: Float) -> Bool {
        brightness.isFinite && (0...1).contains(brightness)
    }

    private static func matches(_ brightness: Float, _ expected: Float) -> Bool {
        // Allow small native quantization while using the same ownership test on later reads.
        valid(brightness) && abs(brightness - expected) <= 0.005
    }

    private func readPending() -> Pending? {
        guard let data = defaults.data(forKey: Self.pendingKey),
              let pending = try? JSONDecoder().decode(Pending.self, from: data),
              Self.valid(pending.brightness) else { return nil }
        return pending
    }

    private func save(_ pending: Pending) -> Bool {
        guard let data = try? JSONEncoder().encode(pending) else { return false }
        defaults.set(data, forKey: Self.pendingKey)
        return defaults.synchronize()
    }

    private func clearPending() {
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.synchronize()
    }
}

/// DisplayServices is private and may be absent or reject a panel; those cases remain unavailable.
public final class SystemDisplayBrightness: DisplayBrightnessAccess {
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private let library: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?

    public init() {
        let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW | RTLD_LOCAL)
        self.library = library
        getBrightness = library.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map {
            unsafeBitCast($0, to: GetBrightness.self)
        }
        setBrightness = library.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map {
            unsafeBitCast($0, to: SetBrightness.self)
        }
    }

    deinit {
        if let library { dlclose(library) }
    }

    public func read() throws -> Float {
        guard let getBrightness, setBrightness != nil else { throw DisplayBrightnessError.unavailable }
        let display = try builtInDisplay()
        var brightness: Float = 0
        guard getBrightness(display, &brightness) == 0 else { throw DisplayBrightnessError.readFailed }
        return brightness
    }

    public func write(_ brightness: Float) throws {
        guard let setBrightness else { throw DisplayBrightnessError.unavailable }
        guard brightness.isFinite, (0...1).contains(brightness) else { throw DisplayBrightnessError.writeFailed }
        guard setBrightness(try builtInDisplay(), brightness) == 0 else { throw DisplayBrightnessError.writeFailed }
    }

    private func builtInDisplay() throws -> CGDirectDisplayID {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw DisplayBrightnessError.displayOffline }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard count > 0, CGGetOnlineDisplayList(count, &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw DisplayBrightnessError.displayOffline
        }
        return display
    }
}
