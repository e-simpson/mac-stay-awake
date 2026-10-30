import CoreAudio
import Darwin
import Foundation
import LidAwakeShared
import ObjectiveC

/// A device identity remains attached to the saved value, even if the default output changes.
protocol ClosedLidDeviceAccess {
    func currentDevice() -> String?
    func read(_ device: String) throws -> Double
    func write(_ device: String, value: Double) throws
}

enum ClosedLidDeviceError: Error { case unavailable, disconnected }

/// Persists each original value before writing; never overwrites a visible external change.
@MainActor
final class ClosedLidOverride {
    private struct Saved: Codable {
        let original: Double
        var applied: Bool
        var restoring: Bool? = nil
    }
    private let access: ClosedLidDeviceAccess
    private let defaults: UserDefaults
    private let key: String
    private let target: Double
    private let report: (SettingEvent.Operation, SettingEvent.Outcome, Double?, Double?, Double?) -> Void
    private var seen: Set<String> = []
    private var lastObservation: [SettingEvent.Operation: Observation] = [:]
    private struct Observation: Equatable {
        let outcome: SettingEvent.Outcome
        let prior: Double?
        let current: Double?
        let target: Double?
    }

    init(access: ClosedLidDeviceAccess, defaults: UserDefaults, key: String, target: Double,
         report: @escaping (SettingEvent.Operation, SettingEvent.Outcome, Double?, Double?, Double?) -> Void = { _, _, _, _, _ in }) {
        self.access = access
        self.defaults = defaults
        self.key = key
        self.target = target
        self.report = report
    }

    /// False indicates unavailable hardware or an unresolved recovery, without stopping the session.
    func update(enabled: Bool) -> Bool {
        var saved: [String: Saved]
        if let data = defaults.data(forKey: key) {
            guard let decoded = try? JSONDecoder().decode([String: Saved].self, from: data),
                  decoded.values.allSatisfy({ $0.original.isFinite && (0...1).contains($0.original) }) else { return false }
            saved = decoded
        } else if defaults.object(forKey: key) != nil {
            return false
        } else {
            saved = [:]
        }

        let current = enabled ? access.currentDevice() : nil
        var ok = !enabled || current != nil
        // Restore previous output devices even when the active output changes while closed.
        for (device, entry) in saved where device != current || entry.restoring == true {
            do {
                let value = try access.read(device)
                guard valid(value) else { record(.restore, .pending, target: entry.original); ok = false; continue }
                if device == current && entry.restoring == true && matches(value, target) {
                    // Restoration did not take effect, and this output is active again.
                    // Keep it muted/dimmed instead of briefly restoring and reapplying.
                    var resumed = entry
                    resumed.restoring = nil
                    resumed.applied = true
                    saved[device] = resumed
                    seen.insert(device)
                    if !save(saved) { ok = false }
                    continue
                }
                if matches(value, target) && !matches(entry.original, target) {
                    var recovering = entry
                    recovering.restoring = true
                    saved[device] = recovering
                    guard save(saved) else { ok = false; continue }
                    try access.write(device, value: entry.original)
                    let restored = try access.read(device)
                    guard matches(restored, entry.original) else { record(.restore, .pending, prior: value, target: entry.original); ok = false; continue }
                    record(.restore, .verified, prior: value, current: restored, target: entry.original)
                    seen.remove(device)
                } else {
                    record(.restore, matches(value, entry.original) ? .alreadyAtTarget : .externalChangePreserved,
                           prior: value, current: value, target: entry.original)
                    if entry.restoring == true && matches(value, entry.original) { seen.remove(device) }
                }
                saved.removeValue(forKey: device)
                if !save(saved) { return false }
            } catch ClosedLidDeviceError.disconnected {
                // A disconnected accessory cannot be restored; do not retain ownership of it.
                saved.removeValue(forKey: device)
                guard save(saved) else { return false }
                seen.remove(device)
                record(.restore, .failed, target: entry.original)
            } catch { record(.restore, .pending, target: entry.original); ok = false }
        }
        if !enabled { seen.removeAll(); return ok && saved.isEmpty }
        guard let device = current else { record(.apply, .failed, target: target); return false }
        do {
            let value = try access.read(device)
            guard valid(value) else { return false }
            if var entry = saved[device] {
                if entry.applied && !matches(value, target) {
                    // The user or system changed the setting after our write.
                    record(.apply, .externalChangePreserved, prior: entry.original, current: value, target: target)
                    saved.removeValue(forKey: device)
                    seen.insert(device)
                    return save(saved) && ok
                }
                if !entry.applied && !matches(value, target) && !matches(value, entry.original) {
                    record(.apply, .externalChangePreserved, prior: entry.original, current: value, target: target)
                    saved.removeValue(forKey: device)
                    seen.insert(device)
                    return save(saved) && ok
                }
                if entry.applied { return ok }
                let needsWrite = !matches(value, target)
                if needsWrite { try access.write(device, value: target) }
                let observed = try access.read(device)
                guard matches(observed, target) else { record(.apply, .pending, prior: entry.original, target: target); return false }
                if !entry.applied || needsWrite {
                    record(.apply, needsWrite ? .verified : .alreadyAtTarget, prior: entry.original, current: observed, target: target)
                }
                entry.applied = true
                saved[device] = entry
                seen.insert(device)
                return save(saved) && ok
            }
            guard !seen.contains(device) else { return ok }
            seen.insert(device)
            if matches(value, target) { record(.apply, .alreadyAtTarget, prior: value, current: value, target: target); return ok }
            saved[device] = Saved(original: value, applied: false)
            guard save(saved) else { seen.remove(device); return false }
            try access.write(device, value: target)
            let observed = try access.read(device)
            guard matches(observed, target) else { record(.apply, .pending, prior: value, target: target); return false }
            record(.apply, .verified, prior: value, current: observed, target: target)
            saved[device]?.applied = true
            return save(saved) && ok
        } catch { record(.apply, .failed, target: target); return false }
    }

    private func valid(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
    private func matches(_ a: Double, _ b: Double) -> Bool { valid(a) && abs(a - b) <= 0.005 }
    private func record(_ operation: SettingEvent.Operation, _ outcome: SettingEvent.Outcome,
                        prior: Double? = nil, current: Double? = nil, target: Double? = nil) {
        let observation = Observation(outcome: outcome, prior: prior, current: current, target: target)
        if outcome != .verified && lastObservation[operation] == observation { return }
        lastObservation[operation] = observation
        report(operation, outcome, prior, current, target)
    }
    private func save(_ saved: [String: Saved]) -> Bool {
        let previous = defaults.object(forKey: key)
        if saved.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
        else { return false }
        guard defaults.synchronize() else {
            // A failed deletion must not look complete on the next recovery attempt.
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            _ = defaults.synchronize()
            return false
        }
        return true
    }
}

@MainActor
public protocol ClosedLidSettingsControlling {
    /// Applies enabled settings when closed, otherwise restores any owned values.
    func update(closed: Bool, mute: Bool, keyboard: Bool) -> Bool
}

@MainActor
public struct NoClosedLidSettings: ClosedLidSettingsControlling {
    public nonisolated init() {}
    public func update(closed: Bool, mute: Bool, keyboard: Bool) -> Bool { true }
}

@MainActor
public final class ClosedLidSettings: ClosedLidSettingsControlling {
    private let sound: ClosedLidOverride
    private let keyboard: ClosedLidOverride
    public init(defaults: UserDefaults = .standard, activityLog: ActivityLogging = NoActivityLog()) {
        func reporter(_ setting: SettingEvent.Setting, _ source: SettingEvent.Source, _ key: SettingEvent.Key)
            -> (SettingEvent.Operation, SettingEvent.Outcome, Double?, Double?, Double?) -> Void {
            { operation, outcome, prior, current, target in
                let event = SettingEvent(time: Date(), setting: setting, source: source, operation: operation,
                                         outcome: outcome, key: key, prior: prior, current: current, target: target)
                if event.isValid { activityLog.record(.setting(event), at: event.time) }
            }
        }
        sound = ClosedLidOverride(access: SystemOutputMute(), defaults: defaults, key: "outputMutePendingRestore", target: 1,
                                  report: reporter(.outputMute, .audioOutput, .mute))
        keyboard = ClosedLidOverride(access: SystemKeyboardBacklight(), defaults: defaults, key: "keyboardBacklightPendingRestore", target: 0,
                                     report: reporter(.keyboardBrightness, .builtInKeyboard, .keyboardBrightness))
    }
    public func update(closed: Bool, mute: Bool, keyboard: Bool) -> Bool {
        let soundOK = sound.update(enabled: closed && mute)
        let keyboardOK = self.keyboard.update(enabled: closed && keyboard)
        return soundOK && keyboardOK
    }
}

/// Uses the current default output's stable Core Audio UID, not a transient device ID.
private struct SystemOutputMute: ClosedLidDeviceAccess {
    func currentDevice() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return uid(device)
    }
    func read(_ device: String) throws -> Double {
        let id = try resolve(device)
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, value <= 1 else { throw ClosedLidDeviceError.unavailable }
        return Double(value)
    }
    func write(_ device: String, value: Double) throws {
        let id = try resolve(device)
        var address = muteAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { throw ClosedLidDeviceError.unavailable }
        var mute = UInt32(value.rounded())
        guard AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute) == noErr else { throw ClosedLidDeviceError.unavailable }
    }
    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }
    private func uid(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard device != 0, AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private func resolve(_ uid: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { throw ClosedLidDeviceError.unavailable }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !devices.isEmpty,
              AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { throw ClosedLidDeviceError.unavailable }
        let identities = devices.map { (device: $0, uid: self.uid($0)) }
        if let match = identities.first(where: { $0.uid == uid }) { return match.device }
        guard identities.allSatisfy({ $0.uid != nil }) else { throw ClosedLidDeviceError.unavailable }
        throw ClosedLidDeviceError.disconnected
    }
}

/// CoreBrightness is private; absence or a changed API leaves the keyboard untouched.
private final class SystemKeyboardBacklight: ClosedLidDeviceAccess {
    private typealias Read = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias Write = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias BuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private let client: NSObject?
    private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
    private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")
    private let builtInSelector = NSSelectorFromString("isKeyboardBuiltIn:")
    init() {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW | RTLD_LOCAL)
        client = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }
    func currentDevice() -> String? {
        guard let client, compatible(client, NSSelectorFromString("copyKeyboardBacklightIDs"), result: "@", arguments: []),
              compatible(client, getSelector, result: "f", arguments: ["Q"]),
              compatible(client, setSelector, result: "B", arguments: ["f", "Q"]),
              compatible(client, builtInSelector, result: "B", arguments: ["Q"]),
              let method = class_getInstanceMethod(type(of: client), builtInSelector),
              let ids = client.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return nil }
        let builtIn = unsafeBitCast(method_getImplementation(method), to: BuiltIn.self)
        guard let first = ids.first(where: { builtIn(client, builtInSelector, $0.uint64Value) }) else { return nil }
        return first.stringValue
    }
    func read(_ device: String) throws -> Double {
        guard currentDevice() == device, let client, let id = UInt64(device), let method = class_getInstanceMethod(type(of: client), getSelector) else { throw ClosedLidDeviceError.unavailable }
        let f = unsafeBitCast(method_getImplementation(method), to: Read.self)
        let value = Double(f(client, getSelector, id))
        guard value.isFinite, (0...1).contains(value) else { throw ClosedLidDeviceError.unavailable }
        return value
    }
    func write(_ device: String, value: Double) throws {
        guard currentDevice() == device, let client, let id = UInt64(device), let method = class_getInstanceMethod(type(of: client), setSelector) else { throw ClosedLidDeviceError.unavailable }
        let f = unsafeBitCast(method_getImplementation(method), to: Write.self)
        guard f(client, setSelector, Float(value), id) else { throw ClosedLidDeviceError.unavailable }
    }
    private func compatible(_ client: NSObject, _ selector: Selector, result: String, arguments: [String]) -> Bool {
        guard let method = class_getInstanceMethod(type(of: client), selector),
              method_getNumberOfArguments(method) == arguments.count + 2 else { return false }
        let returned = method_copyReturnType(method)
        defer { free(returned) }
        guard String(cString: returned) == result else { return false }
        for (index, expected) in arguments.enumerated() {
            guard let argument = method_copyArgumentType(method, UInt32(index + 2)) else { return false }
            let matches = String(cString: argument) == expected
            free(argument)
            if !matches { return false }
        }
        return true
    }
}
