import Foundation
import LidAwakeShared

public struct SessionResult: Equatable {
    public let code: HelperResultCode
    public let message: String?

    public static let ok = SessionResult(code: .ok, message: nil)

    static func failure(_ code: HelperResultCode, _ error: Error) -> SessionResult {
        SessionResult(code: code, message: error.localizedDescription)
    }
}

public struct SessionStatus: Equatable {
    public let flag: SleepFlagState
    public let session: SessionOwnership
    /// Whole seconds, rounded up; nil when the timer is off or no session is active.
    public let timerRemaining: Int?
    public let power: PowerReading
    public let thermal: ThermalState
    public let paused: Bool
    public let message: String?
}

/// Keeps SleepDisabled set while a leased session is active and ends it when a safety limit trips.
/// With charging-only protection the session pauses on battery power and resumes on AC power.
///
/// Not thread-safe: the helper calls it from one queue.
public final class LidSession {
    public enum Ownership: Equatable {
        case ours
        case foreign
    }

    private struct LimitStop {
        let reason: StopReason
        let percent: Int?
        let message: String
    }

    private enum PowerCheck {
        case run
        case pause
        case unreadable
    }

    private let flag: SleepFlag
    private let marker: OwnershipMarker
    private let clock: SessionClock
    private let awakeClock: SessionClock
    private let power: PowerSourceReading
    private let thermal: ThermalStateReading
    private let idle: IdleWatching
    private let stopReasons: StopReasonStore
    private let closedPower: ClosedLidPowerManaging
    private let lidClosed: () -> Bool?
    private let wallClock: () -> Date

    public private(set) var ownership: Ownership?
    public private(set) var deadline: TimeInterval?
    public private(set) var startedAt: TimeInterval?
    public private(set) var safety: SafetySettings = .off
    /// True while charging-only protection holds the session on battery power.
    public private(set) var isPaused = false
    private var lastLeftoverAttempt: TimeInterval?

    public static let leftoverRetryInterval: TimeInterval = 30

    public var isActive: Bool { ownership != nil }

    public init(
        flag: SleepFlag,
        marker: OwnershipMarker,
        clock: SessionClock,
        awakeClock: SessionClock,
        power: PowerSourceReading,
        thermal: ThermalStateReading,
        idle: IdleWatching,
        stopReasons: StopReasonStore,
        closedPower: ClosedLidPowerManaging,
        lidClosed: @escaping () -> Bool? = SystemLidState.read,
        wallClock: @escaping () -> Date = Date.init
    ) {
        self.flag = flag
        self.marker = marker
        self.clock = clock
        self.awakeClock = awakeClock
        self.power = power
        self.thermal = thermal
        self.idle = idle
        self.stopReasons = stopReasons
        self.closedPower = closedPower
        self.lidClosed = lidClosed
        self.wallClock = wallClock
    }

    public func start(lease: TimeInterval, safety: SafetySettings) -> SessionResult {
        guard safety.isValid else { return Self.invalidSafety }
        if isActive {
            return renew(lease: lease, safety: safety)
        }
        if let stop = thermalStop(enabled: safety.thermalProtection) {
            return SessionResult(code: .thermalLimitReached, message: stop.message)
        }
        if let stop = batteryStop(limit: safety.batteryLimitPercent) {
            return SessionResult(code: .batteryLimitReached, message: stop.message)
        }
        let power = chargingCheck(enabled: safety.chargingOnly)
        if power == .unreadable {
            return SessionResult(code: .powerUnreadable, message: Self.powerUnreadableMessage)
        }

        if safety.lowPowerWhenClosed {
            do {
                try closedPower.restore()
            } catch {
                return .failure(.powerModeFailed, error)
            }
        }
        let isSet: Bool
        do {
            isSet = try flag.read()
        } catch {
            return .failure(.flagReadFailed, error)
        }

        if isSet && !marker.isSet {
            begin(.foreign, lease: lease, safety: safety, paused: power == .pause)
            return updateClosedPower()
        }
        if power == .pause {
            // A flag left over from an earlier session of ours is released, not kept through the pause.
            if marker.isSet {
                let released = releaseFlag()
                guard released == .ok else { return released }
            }
            begin(.ours, lease: lease, safety: safety, paused: true)
            return updateClosedPower()
        }

        // The marker goes first: a crash after it leaves a flag that the next
        // cleanup clears, never a flag that looks foreign.
        do {
            try marker.set()
        } catch {
            return .failure(.markerFailed, error)
        }
        if !isSet {
            do {
                try flag.write(true)
            } catch {
                if (try? flag.write(false)) != nil {
                    try? marker.clear()
                }
                return .failure(.flagWriteFailed, error)
            }
        }
        begin(.ours, lease: lease, safety: safety, paused: false)
        return updateClosedPower()
    }

    public func renew(lease: TimeInterval, safety: SafetySettings) -> SessionResult {
        guard safety.isValid else { return Self.invalidSafety }
        guard isActive else {
            return SessionResult(code: .noSession, message: "No active session.")
        }
        deadline = awakeClock.now + lease
        self.safety = safety
        updateIdleRequirement()

        switch chargingCheck(enabled: safety.chargingOnly) {
        case .unreadable:
            stop(.powerUnreadable, batteryPercent: nil)
            return SessionResult(code: .noSession, message: Self.powerUnreadableMessage)
        case .pause:
            return pause()
        case .run:
            let resumed = resume()
            guard resumed == .ok else { return resumed }
        }

        let isSet: Bool
        do {
            isSet = try flag.read()
        } catch {
            return .failure(.flagReadFailed, error)
        }
        guard !isSet else { return updateClosedPower() }
        if ownership == .foreign {
            let result = takeOver()
            return result == .ok ? updateClosedPower() : result
        }
        let claimed = claimFlag()
        return claimed == .ok ? updateClosedPower() : claimed
    }

    public func end() -> SessionResult {
        guard let ended = ownership else {
            return clearLeftover()
        }
        let wasPaused = isPaused
        ownership = nil
        deadline = nil
        startedAt = nil
        safety = .off
        isPaused = false
        updateIdleRequirement()
        // Attempt energy restoration first, but never defeat a safety stop just to retry it.
        return restorePowerAndSleep(releaseSleep: ended == .ours && !wasPaused)
    }

    /// Ends the session when the timer runs out, the Mac gets too hot, the battery reaches its limit,
    /// the power source cannot be read, the lease runs out or nothing has been working for the set
    /// number of minutes, checked in that order; otherwise pauses or resumes it as the power source
    /// requires. Returns nil when nothing changed.
    ///
    /// The idle readings are taken even without a session, so the helper can report what it sees.
    @discardableResult
    public func enforceLimits() -> SessionResult? {
        updateIdleRequirement()
        idle.sample()
        guard isActive else { return nil }
        if let remaining = timerRemaining, remaining <= 0 {
            return stop(.timer, batteryPercent: nil)
        }
        if let thermal = thermalStop(enabled: safety.thermalProtection) {
            return stop(thermal.reason, batteryPercent: nil)
        }
        if let battery = batteryStop(limit: safety.batteryLimitPercent) {
            return stop(battery.reason, batteryPercent: battery.percent)
        }
        let power = chargingCheck(enabled: safety.chargingOnly)
        if power == .unreadable {
            return stop(.powerUnreadable, batteryPercent: nil)
        }
        if let deadline, awakeClock.now >= deadline {
            return stop(.leaseExpired, batteryPercent: nil)
        }
        if safety.idleSleepMinutes > 0, idle.countedMinutes >= safety.idleSleepMinutes {
            return stop(.idle, batteryPercent: nil, idleMinutes: idle.countedMinutes)
        }
        switch power {
        case .pause:
            return isPaused ? nil : pause()
        case .run:
            let wasPaused = isPaused
            if wasPaused {
                let result = resume()
                guard result == .ok else { return result }
            }
            let result = updateClosedPower()
            return result == .ok && !wasPaused ? nil : result
        case .unreadable:
            return nil
        }
    }

    public func clearLeftover() -> SessionResult {
        guard !isActive else { return .ok }
        return restorePowerAndSleep(releaseSleep: marker.isSet)
    }

    /// True while the helper has to stay running: a session is active or a flag it set is still left over.
    public var needsHelper: Bool {
        isActive || marker.isSet || closedPower.hasPendingRestore
    }

    /// Clears a flag left by an earlier run, at most once per `leftoverRetryInterval`.
    /// Returns nil when there was nothing to do or the last attempt is too recent.
    @discardableResult
    public func retryLeftover() -> SessionResult? {
        guard !isActive, marker.isSet || closedPower.hasPendingRestore else { return nil }
        if let lastLeftoverAttempt, clock.now - lastLeftoverAttempt < Self.leftoverRetryInterval {
            return nil
        }
        lastLeftoverAttempt = clock.now
        return clearLeftover()
    }

    public func status() -> SessionStatus {
        let session: SessionOwnership
        switch ownership {
        case nil: session = .noSession
        case .ours: session = .ours
        case .foreign: session = .foreign
        }
        let remaining = timerRemaining.map { Int(max(0, $0).rounded(.up)) }
        let reading = power.read()
        let thermalState = thermal.read()
        do {
            return SessionStatus(
                flag: try flag.read() ? .on : .off,
                session: session,
                timerRemaining: remaining,
                power: reading,
                thermal: thermalState,
                paused: isPaused,
                message: nil
            )
        } catch {
            return SessionStatus(
                flag: .unknown,
                session: session,
                timerRemaining: remaining,
                power: reading,
                thermal: thermalState,
                paused: isPaused,
                message: error.localizedDescription
            )
        }
    }

    public func takeSettingEvents() -> [SettingEvent] { closedPower.takeSettingEvents() }

    public func lastStopReason() -> StopRecord? {
        stopReasons.read()
    }

    public func clearStopReason() -> SessionResult {
        do {
            try stopReasons.clear()
        } catch {
            return .failure(.stopReasonFailed, error)
        }
        return .ok
    }

    private func updateClosedPower() -> SessionResult {
        if !safety.lowPowerWhenClosed {
            do {
                try closedPower.restore()
                return .ok
            } catch {
                // Optional recovery must remain visible and retryable without releasing keep-awake.
                return .failure(.powerModeFailed, error)
            }
        }
        do {
            guard let closed = lidClosed() else {
                throw NSError(domain: "LidAwake", code: 1, userInfo: [NSLocalizedDescriptionKey: "The lid state could not be read."])
            }
            let apply = isActive && !isPaused && closed
            try closedPower.update(closed: apply, source: apply ? power.read().source : .unknown)
            return .ok
        } catch {
            try? stopReasons.write(StopRecord(reason: .powerModeFailed, time: wallClock(), batteryPercent: nil))
            let cleanup = end()
            let detail = cleanup == .ok ? error.localizedDescription : "\(error.localizedDescription) Recovery pending: \(cleanup.message ?? "power settings could not be restored")"
            return SessionResult(code: .powerModeFailed, message: detail)
        }
    }

    private static let powerUnreadableMessage = "The power source could not be read."

    private static let invalidSafety = SessionResult(
        code: .invalidArgument,
        message: "Timer must be 0 or \(SafetySettings.timerRange.lowerBound) to \(SafetySettings.timerRange.upperBound) seconds; battery limit must be 0 to 100 percent; idle sleep must be 0 or \(SafetySettings.idleSleepRange.lowerBound) to \(SafetySettings.idleSleepRange.upperBound) minutes; at most \(WatchedApps.maximumCount) watched apps, each an absolute path ending in .app."
    )

    // Counted from the start of the session, even after the timer setting changes, and through sleep.
    private var timerRemaining: TimeInterval? {
        guard let startedAt, safety.timerSeconds > 0 else { return nil }
        return TimeInterval(safety.timerSeconds) - (clock.now - startedAt)
    }

    private func thermalStop(enabled: Bool) -> LimitStop? {
        guard enabled else { return nil }
        let state = thermal.read()
        switch state {
        case .nominal, .fair:
            return nil
        case .serious, .critical:
            return LimitStop(reason: .thermal, percent: nil, message: "The Mac is too hot (thermal state \(state.token)).")
        case .unknown:
            return LimitStop(reason: .thermalUnreadable, percent: nil, message: "The thermal state could not be read.")
        }
    }

    private func batteryStop(limit: Int) -> LimitStop? {
        guard limit > 0 else { return nil }
        let reading = power.read()
        switch reading.battery {
        case .none:
            return nil
        case .unknown:
            return LimitStop(reason: .batteryUnreadable, percent: nil, message: "The battery level could not be read.")
        case .percent(let percent):
            switch reading.source {
            case .ac:
                return nil
            case .unknown:
                return LimitStop(reason: .batteryUnreadable, percent: nil, message: "The power source could not be read.")
            case .battery:
                guard percent <= limit else { return nil }
                return LimitStop(
                    reason: .battery,
                    percent: percent,
                    message: "The battery is at \(percent)%, at or below the \(limit)% limit."
                )
            }
        }
    }

    // A Mac without a battery always counts as running on AC power.
    private func chargingCheck(enabled: Bool) -> PowerCheck {
        guard enabled else { return .run }
        let reading = power.read()
        guard reading.battery != .none else { return .run }
        switch reading.source {
        case .ac: return .run
        case .battery: return .pause
        case .unknown: return .unreadable
        }
    }

    // A foreign flag stays untouched; only our own flag and marker are released.
    private func pause() -> SessionResult {
        guard !isPaused else { return .ok }
        let restored = restorePowerAndSleep(releaseSleep: ownership == .ours)
        if restored == .ok || restored.code == .powerModeFailed {
            // Sleep was released even if energy recovery remains pending.
            isPaused = true
            updateIdleRequirement()
        }
        return restored
    }

    private func resume() -> SessionResult {
        guard isPaused else { return .ok }
        if ownership == .ours {
            // Another program may have set the flag during the pause; it stays foreign.
            let isSet: Bool
            do {
                isSet = try flag.read()
            } catch {
                return .failure(.flagReadFailed, error)
            }
            if isSet {
                ownership = .foreign
                isPaused = false
                updateIdleRequirement()
                return .ok
            }
            let claimed = claimFlag()
            guard claimed == .ok else { return claimed }
        }
        isPaused = false
        updateIdleRequirement()
        return .ok
    }

    /// The idle count runs only while a session actually holds the Mac awake.
    private func updateIdleRequirement() {
        let holdsAwake = isActive && !isPaused
        idle.require(minutes: holdsAwake ? safety.idleSleepMinutes : 0)
        idle.watch(appPaths: holdsAwake ? safety.watchedAppPaths : [])
    }

    @discardableResult
    private func stop(_ reason: StopReason, batteryPercent: Int?, idleMinutes: Int? = nil) -> SessionResult {
        // The session ends even when the reason cannot be saved.
        try? stopReasons.write(StopRecord(
            reason: reason,
            time: wallClock(),
            batteryPercent: batteryPercent,
            idleMinutes: idleMinutes
        ))
        return end()
    }

    private func takeOver() -> SessionResult {
        let claimed = claimFlag()
        guard claimed == .ok else { return claimed }
        ownership = .ours
        return .ok
    }

    // Same order as start: the marker before the flag.
    private func claimFlag() -> SessionResult {
        do {
            try marker.set()
        } catch {
            return .failure(.markerFailed, error)
        }
        do {
            try flag.write(true)
        } catch {
            if (try? flag.write(false)) != nil {
                try? marker.clear()
            }
            return .failure(.flagWriteFailed, error)
        }
        return .ok
    }

    private func begin(_ ownership: Ownership, lease: TimeInterval, safety: SafetySettings, paused: Bool) {
        self.ownership = ownership
        self.safety = safety
        isPaused = paused
        startedAt = clock.now
        deadline = awakeClock.now + lease
        updateIdleRequirement()
        idle.restart()
    }

    private func restorePowerAndSleep(releaseSleep: Bool) -> SessionResult {
        var energyFailure: SessionResult?
        do {
            try closedPower.restore()
        } catch {
            energyFailure = .failure(.powerModeFailed, error)
        }
        if releaseSleep {
            let released = releaseFlag()
            if released != .ok {
                if let energyFailure {
                    return SessionResult(code: released.code,
                        message: "\(released.message ?? "Sleep recovery failed.") \(energyFailure.message ?? "Energy recovery pending.")")
                }
                return released
            }
        }
        return energyFailure ?? .ok
    }

    // The marker stays when the flag cannot be cleared, so a later cleanup retries.
    private func releaseFlag() -> SessionResult {
        do {
            try marker.validate()
        } catch {
            return .failure(.markerFailed, error)
        }
        do {
            try flag.write(false)
        } catch {
            return .failure(.flagWriteFailed, error)
        }
        do {
            try marker.clear()
        } catch {
            return .failure(.markerFailed, error)
        }
        return .ok
    }
}
