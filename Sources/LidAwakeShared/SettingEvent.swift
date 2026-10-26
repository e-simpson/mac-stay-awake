import Foundation

/// A factual observation made by the owner of a temporary setting, at the time of verification.
public struct SettingEvent: Codable, Equatable {
    public enum Setting: String, Codable { case brightness, powerMode, keyboardBrightness, outputMute }
    public enum Source: String, Codable { case builtInDisplay, builtInKeyboard, audioOutput, battery, ac, unknown }
    public enum Operation: String, Codable { case apply, restore }
    public enum Outcome: String, Codable {
        case verified, alreadyAtTarget, externalChangePreserved, pending, failed
    }
    public enum Key: String, Codable { case brightness, keyboardBrightness, mute, powermode, lowpowermode }

    public let time: Date
    public let setting: Setting
    public let source: Source
    public let operation: Operation
    public let outcome: Outcome
    public let key: Key?
    /// Observed values, never an assumed result of a successful command.
    public let prior: Double?
    public let current: Double?
    public let target: Double?
    public let detail: String?

    public init(time: Date, setting: Setting, source: Source, operation: Operation,
                outcome: Outcome, key: Key? = nil, prior: Double? = nil,
                current: Double? = nil, target: Double? = nil, detail: String? = nil) {
        self.time = time
        self.setting = setting
        self.source = source
        self.operation = operation
        self.outcome = outcome
        self.key = key
        self.prior = prior
        self.current = current
        self.target = target
        self.detail = detail.map { String($0.prefix(512)) }
    }

    public var isValid: Bool {
        guard time.timeIntervalSince1970.isFinite, time.timeIntervalSince1970 >= 0,
              (detail?.utf8.count ?? 0) <= 2048 else { return false }
        let values = [prior, current, target].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite }) else { return false }
        if outcome == .verified || outcome == .alreadyAtTarget {
            guard let current, let target, source != .unknown, key != nil,
                  abs(current - target) <= (setting == .brightness || setting == .keyboardBrightness ? 0.005 : 0) else { return false }
        }
        if key == nil, outcome != .pending && outcome != .failed { return false }
        switch setting {
        case .brightness:
            return source == .builtInDisplay && key == .brightness && values.allSatisfy { (0...1).contains($0) }
        case .keyboardBrightness:
            return source == .builtInKeyboard && key == .keyboardBrightness && values.allSatisfy { (0...1).contains($0) }
        case .outputMute:
            return source == .audioOutput && key == .mute && values.allSatisfy { $0 == 0 || $0 == 1 }
        case .powerMode:
            return [.battery, .ac, .unknown].contains(source) && (key == .powermode || key == .lowpowermode || key == nil) && values.allSatisfy {
                $0.rounded() == $0 && (0...(key == .lowpowermode ? 1 : 2)).contains($0)
            }
        }
    }
}

/// Bounded, best-effort transport. Invalid payloads are rejected as a whole.
public enum SettingEventWire {
    public static let maximumCount = 128
    public static let maximumBytes = 512 * 1024

    public static func encode(_ events: [SettingEvent]) -> String {
        let valid = events.suffix(maximumCount).filter(\.isValid)
        guard let data = try? JSONEncoder().encode(valid), data.count <= maximumBytes else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [SettingEvent]? {
        guard text.utf8.count <= maximumBytes,
              let events = try? JSONDecoder().decode([SettingEvent].self, from: Data(text.utf8)),
              events.count <= maximumCount, events.allSatisfy(\.isValid) else { return nil }
        return events
    }
}
