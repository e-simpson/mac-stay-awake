import Combine
import Foundation
import LidAwakeShared

@MainActor
public final class SafetyPreferences: ObservableObject {
    public enum Key {
        public static let timerEnabled = "timerEnabled"
        public static let timerSeconds = "timerSeconds"
        public static let batteryLimitEnabled = "batteryLimitEnabled"
        public static let batteryLimitPercent = "batteryLimitPercent"
        public static let thermalProtectionEnabled = "thermalProtectionEnabled"
        public static let chargingOnlyEnabled = "chargingOnlyEnabled"
        public static let displayOffWhenClosed = "displayOffWhenClosed"
        public static let lowPowerWhenClosed = "lowPowerWhenClosed"
        public static let muteWhenClosed = "muteWhenClosed"
        public static let lockOnLidCloseEnabled = "lockOnLidCloseEnabled"
        public static let idleSleepEnabled = "idleSleepEnabled"
        public static let idleSleepMinutes = "idleSleepMinutes"
        public static let watchedAppPaths = "watchedAppPaths"
    }

    public static let timerChoices = [120, 300, 600, 1800, 3600, 7200, 14_400, 28_800, 57_600, 86_400]
    public static let batteryLimitChoices = [10, 20, 30, 40, 50]
    public static let idleSleepChoices = [10, 20, 30, 60]

    @Published public var timerEnabled: Bool {
        didSet { save(timerEnabled, Key.timerEnabled) }
    }
    @Published public var timerSeconds: Int {
        didSet { save(timerSeconds, Key.timerSeconds) }
    }
    @Published public var batteryLimitEnabled: Bool {
        didSet { save(batteryLimitEnabled, Key.batteryLimitEnabled) }
    }
    @Published public var batteryLimitPercent: Int {
        didSet { save(batteryLimitPercent, Key.batteryLimitPercent) }
    }
    @Published public var thermalProtectionEnabled: Bool {
        didSet { save(thermalProtectionEnabled, Key.thermalProtectionEnabled) }
    }
    @Published public var chargingOnlyEnabled: Bool {
        didSet { save(chargingOnlyEnabled, Key.chargingOnlyEnabled) }
    }
    @Published public var displayOffWhenClosed: Bool {
        didSet { save(displayOffWhenClosed, Key.displayOffWhenClosed) }
    }
    @Published public var lowPowerWhenClosed: Bool {
        didSet { save(lowPowerWhenClosed, Key.lowPowerWhenClosed) }
    }
    @Published public var muteWhenClosed: Bool {
        didSet { save(muteWhenClosed, Key.muteWhenClosed) }
    }
    @Published public var idleSleepEnabled: Bool {
        didSet { save(idleSleepEnabled, Key.idleSleepEnabled) }
    }
    @Published public var idleSleepMinutes: Int {
        didSet { save(idleSleepMinutes, Key.idleSleepMinutes) }
    }
    /// Apps whose started programs count as work for Sleep when idle.
    @Published public var watchedAppPaths: [String] {
        didSet { save(watchedAppPaths, Key.watchedAppPaths) }
    }
    /// Not sent to the helper, so changing it does not fire `changes`.
    @Published public var lockOnLidCloseEnabled: Bool {
        didSet { defaults.set(lockOnLidCloseEnabled, forKey: Key.lockOnLidCloseEnabled) }
    }

    /// Fires after any setting has changed.
    public let changes = PassthroughSubject<Void, Never>()

    private let defaults: UserDefaults
    private var sendsChanges = true

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.timerEnabled: true,
            Key.timerSeconds: 7200,
            Key.batteryLimitEnabled: true,
            Key.batteryLimitPercent: 20,
            Key.thermalProtectionEnabled: true,
            Key.chargingOnlyEnabled: false,
            Key.displayOffWhenClosed: true,
            Key.lowPowerWhenClosed: true,
            Key.muteWhenClosed: false,
            Key.lockOnLidCloseEnabled: false,
            Key.idleSleepEnabled: false,
            Key.idleSleepMinutes: 20,
            Key.watchedAppPaths: [String](),
        ])
        timerEnabled = defaults.bool(forKey: Key.timerEnabled)
        timerSeconds = Self.clamp(defaults.integer(forKey: Key.timerSeconds), to: SafetySettings.timerRange)
        batteryLimitEnabled = defaults.bool(forKey: Key.batteryLimitEnabled)
        batteryLimitPercent = Self.clamp(
            defaults.integer(forKey: Key.batteryLimitPercent),
            to: SafetySettings.batteryLimitRange
        )
        thermalProtectionEnabled = defaults.bool(forKey: Key.thermalProtectionEnabled)
        chargingOnlyEnabled = defaults.bool(forKey: Key.chargingOnlyEnabled)
        displayOffWhenClosed = defaults.bool(forKey: Key.displayOffWhenClosed)
        lowPowerWhenClosed = defaults.bool(forKey: Key.lowPowerWhenClosed)
        muteWhenClosed = defaults.bool(forKey: Key.muteWhenClosed)
        lockOnLidCloseEnabled = defaults.bool(forKey: Key.lockOnLidCloseEnabled)
        idleSleepEnabled = defaults.bool(forKey: Key.idleSleepEnabled)
        idleSleepMinutes = Self.clamp(defaults.integer(forKey: Key.idleSleepMinutes), to: SafetySettings.idleSleepRange)
        watchedAppPaths = defaults.stringArray(forKey: Key.watchedAppPaths) ?? []
    }

    /// The timer applies in both modes; the other protections only in Stay Awake.
    public var timerLimit: Int? {
        timerEnabled ? timerSeconds : nil
    }

    /// Only while charging already pauses the session on battery, so the battery limit is not used then.
    public var batteryLimitApplies: Bool {
        !chargingOnlyEnabled
    }

    // An ownership hint only: the helper's protected journal remains authoritative.
    var helperRecoveryPending: Bool {
        get { defaults.bool(forKey: "helperRecoveryPending") }
        set {
            defaults.set(newValue, forKey: "helperRecoveryPending")
            defaults.synchronize()
        }
    }

    public var helperSettings: SafetySettings {
        SafetySettings(
            timerSeconds: timerEnabled ? timerSeconds : 0,
            batteryLimitPercent: batteryLimitApplies && batteryLimitEnabled ? batteryLimitPercent : 0,
            thermalProtection: thermalProtectionEnabled,
            chargingOnly: chargingOnlyEnabled,
            idleSleepMinutes: idleSleepEnabled ? idleSleepMinutes : 0,
            watchedAppPaths: idleSleepEnabled ? Self.acceptedWatchedAppPaths(watchedAppPaths) : [],
            lowPowerWhenClosed: lowPowerWhenClosed
        )
    }

    /// Paths the helper would reject are left out rather than failing the session; repeats are sent once.
    static func acceptedWatchedAppPaths(_ paths: [String]) -> [String] {
        var accepted: [String] = []
        for path in paths where WatchedApps.isValidPath(path) && !accepted.contains(path) {
            accepted.append(path)
        }
        return Array(accepted.prefix(WatchedApps.maximumCount))
    }

    /// Turns Sleep when idle on for a session about to start, which reads the setting itself,
    /// so `changes` does not fire.
    public func beginIdleSleepSession() {
        guard !idleSleepEnabled else { return }
        sendsChanges = false
        defer { sendsChanges = true }
        idleSleepEnabled = true
    }

    /// Sleep when idle lasts one Stay Awake session. The session has already ended, so there is
    /// nothing to send to the helper and `changes` does not fire.
    public func endIdleSleepSession() {
        guard idleSleepEnabled else { return }
        sendsChanges = false
        defer { sendsChanges = true }
        idleSleepEnabled = false
    }

    /// Explicit timer selection is acknowledged separately, so it must not trigger renewal.
    /// Zero disables the timer and keeps the last finite choice for later.
    func selectTimer(seconds: Int) {
        sendsChanges = false
        defer { sendsChanges = true }
        if seconds > 0 { timerSeconds = seconds }
        timerEnabled = seconds != 0
    }

    /// A stored value the helper would reject is read as the nearest one it accepts.
    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        if sendsChanges {
            changes.send()
        }
    }
}
