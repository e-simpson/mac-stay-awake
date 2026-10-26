import CoreGraphics
import Darwin
import Foundation

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

    public init(access: DisplayBrightnessAccess = SystemDisplayBrightness(), defaults: UserDefaults = .standard) {
        self.access = access
        self.defaults = defaults
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
        if hasPendingRestore {
            guard let saved = readPending() else { return .unavailable }
            pending = saved
            if pending.dimmed {
                do {
                    let current = try access.read()
                    guard Self.valid(current) else { return .unavailable }
                    return Self.matches(current, 0) ? .dimmed : .preservedExternalChange
                } catch DisplayBrightnessError.displayOffline {
                    return .pending
                } catch {
                    return .unavailable
                }
            }
            if let current = try? access.read(), Self.valid(current),
               !Self.matches(current, 0), !Self.matches(current, pending.brightness) {
                return .preservedExternalChange
            }
        } else {
            let current: Float?
            do {
                current = try access.read()
            } catch DisplayBrightnessError.unavailable {
                return .unavailable
            } catch {
                current = lastOpenBrightness
            }
            guard let current, Self.valid(current) else { return .unavailable }
            pending = Pending(brightness: current, dimmed: false)
            // Persist the original before attempting a write, including when the panel is offline.
            guard save(pending) else { return .unavailable }
        }
        do {
            try access.write(0)
            guard Self.matches(try access.read(), 0) else { return .unavailable }
            pending.dimmed = true
            // The earlier record still permits safe restoration if this second save fails.
            _ = save(pending)
            return .dimmed
        } catch DisplayBrightnessError.displayOffline {
            return .pending
        } catch {
            return .unavailable
        }
    }

    @discardableResult
    public func restore() -> DisplayBrightnessResult {
        guard hasPendingRestore else { return .unchanged }
        guard let pending = readPending() else { return .unavailable }
        do {
            let current = try access.read()
            guard Self.valid(current) else { return .pending }
            // A nonzero value is observable evidence that zero is no longer ours to restore over.
            // This also handles a failed dim operation that left the original value untouched.
            if !Self.matches(current, 0) {
                clearPending()
                lastOpenBrightness = current
                return Self.matches(current, pending.brightness) ? .unchanged : .preservedExternalChange
            }
            try access.write(pending.brightness)
            guard Self.matches(try access.read(), pending.brightness) else { return .pending }
            clearPending()
            lastOpenBrightness = pending.brightness
            return .restored
        } catch DisplayBrightnessError.unavailable {
            return .unavailable
        } catch {
            return .pending
        }
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
