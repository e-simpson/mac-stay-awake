import Combine
import Foundation
import LidAwakeShared

public struct WakeAlarm: Codable, Equatable, Identifiable {
    public let id: UUID
    public var minuteOfDay: Int
    public var isEnabled: Bool

    public init(id: UUID = UUID(), minuteOfDay: Int, isEnabled: Bool = false) {
        self.id = id
        self.minuteOfDay = minuteOfDay
        self.isEnabled = isEnabled
    }
}

/// Daily alarms on the local clock. Legacy settings load as one alarm until the first edit saves the list.
@MainActor
public final class WakePreferences: ObservableObject {
    public enum Key {
        public static let alarms = "dailyWakeAlarms"
        public static let wakeEnabled = "wakeEnabled"
        public static let wakeMinuteOfDay = "wakeMinuteOfDay"
        public static let scheduledWakeTimes = "scheduledWakeTimes"
    }

    public static let defaultMinuteOfDay = 480
    @Published public private(set) var alarms: [WakeAlarm]
    public let changes = PassthroughSubject<Void, Never>()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Key.alarms) != nil {
            let saved = defaults.data(forKey: Key.alarms)
                .flatMap { try? JSONDecoder().decode([WakeAlarm].self, from: $0) } ?? []
            var times: Set<Int> = []
            var ids: Set<UUID> = []
            alarms = Array(saved.filter {
                ScheduledWake.minutes.contains($0.minuteOfDay)
                    && times.insert($0.minuteOfDay).inserted && ids.insert($0.id).inserted
            }.prefix(ScheduledWake.maximumAlarms)).sorted { $0.minuteOfDay < $1.minuteOfDay }
        } else if defaults.object(forKey: Key.wakeEnabled) != nil || defaults.object(forKey: Key.wakeMinuteOfDay) != nil {
            let stored = defaults.object(forKey: Key.wakeMinuteOfDay) as? Int ?? Self.defaultMinuteOfDay
            let minute = ScheduledWake.minutes.contains(stored) ? stored : Self.defaultMinuteOfDay
            alarms = [WakeAlarm(minuteOfDay: minute, isEnabled: defaults.bool(forKey: Key.wakeEnabled))]
        } else {
            alarms = []
        }
    }

    public var enabledMinutesOfDay: [Int] { alarms.filter(\.isEnabled).map(\.minuteOfDay) }
    public var hasEnabledAlarms: Bool { alarms.contains(where: \.isEnabled) }

    /// Adds or edits one alarm; another alarm at the same time is never overwritten.
    @discardableResult
    public func save(_ alarm: WakeAlarm) -> Bool {
        guard ScheduledWake.minutes.contains(alarm.minuteOfDay),
              !alarms.contains(where: { $0.id != alarm.id && $0.minuteOfDay == alarm.minuteOfDay }),
              alarms.contains(where: { $0.id == alarm.id }) || alarms.count < ScheduledWake.maximumAlarms else { return false }
        var updated = alarms.filter { $0.id != alarm.id }
        updated.append(alarm)
        return persist(updated.sorted { $0.minuteOfDay < $1.minuteOfDay })
    }

    public func remove(id: UUID) {
        _ = persist(alarms.filter { $0.id != id })
    }

    private func persist(_ updated: [WakeAlarm]) -> Bool {
        guard updated != alarms else { return true }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: Key.alarms)
        alarms = updated
        changes.send()
        return true
    }

    /// Last confirmed helper events survive restart; changing this cache does not reschedule.
    public var scheduledWakeTimes: [Date] {
        get { defaults.array(forKey: Key.scheduledWakeTimes)?.compactMap { $0 as? Date } ?? [] }
        set { defaults.set(newValue, forKey: Key.scheduledWakeTimes) }
    }
}

/// Local clock formatting shared by the daily alarm editor.
public enum WakeRow {
    /// The time in the pill, in the 12- or 24-hour form the system uses.
    public static func time(minuteOfDay: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(minuteOfDay * 60)))
    }

    /// A date at the minute of the day, for the time picker. The day is fixed, away from any
    /// daylight saving change, so every minute exists on it.
    public static func date(minuteOfDay: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let components = DateComponents(year: 2001, month: 1, day: 1, hour: minuteOfDay / 60, minute: minuteOfDay % 60)
        return calendar.date(from: components) ?? Date(timeIntervalSinceReferenceDate: TimeInterval(minuteOfDay * 60))
    }

    public static func minuteOfDay(of date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
