import Combine
import Foundation
import LidAwakeShared

@MainActor
public final class ModeController: ObservableObject, ScheduledModeStarting {
    @Published public private(set) var mode: Mode = .off
    @Published public private(set) var message: ModeMessage?
    @Published public private(set) var isBusy = false {
        didSet {
            if !isBusy {
                let waiters = idleWaiters
                idleWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
    }
    /// Monotonic time the current mode started; the timer counts from here.
    @Published public private(set) var modeStartedAt: TimeInterval?
    /// True while the helper holds Stay Awake paused on battery power.
    @Published public private(set) var isPaused = false

    @Published public private(set) var isQuitting = false

    public let preferences: SafetyPreferences

    private let displayAssertion: PowerAssertion
    private let helper: HelperPreparing
    private let sessions: LidSessionService
    private let activity: ActivityHolding
    private let powerSourceMonitor: PowerSourceMonitoring
    private let powerSource: PowerSourceReading
    private let notifier: StopNotifying
    private let lidMonitor: LidMonitoring
    private let screenLocker: ScreenLocking
    private let activityLog: ActivityLogging
    private let idleEvents: IdleEventFetching
    private let settingEvents: SettingEventFetching
    private let brightness: DisplayBrightnessControlling
    private let closedLidSettings: ClosedLidSettingsControlling
    private var helperRecoveryNeeded: Bool {
        get { preferences.helperRecoveryPending }
        set { preferences.helperRecoveryPending = newValue }
    }
    private let leaseSeconds: Int
    private let renewalSleep: () async throws -> Void
    private let timerCheckSleep: () async throws -> Void
    private let now: () -> TimeInterval
    private var renewalTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var settingEventTask: Task<Void, Never>?
    private var settingEventRefreshNeeded = false
    private var preferenceChanges: AnyCancellable?
    private var requestedAuthorization = false
    private var stopRequested = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        displayAssertion: PowerAssertion = DisplaySleepAssertion(),
        helper: HelperPreparing,
        sessions: LidSessionService,
        preferences: SafetyPreferences,
        notifier: StopNotifying,
        activity: ActivityHolding = AppNapActivity(),
        powerSourceMonitor: PowerSourceMonitoring = IOKitPowerSourceMonitor(),
        powerSource: PowerSourceReading = IOKitPowerSource(),
        lidMonitor: LidMonitoring = IOKitLidMonitor(),
        screenLocker: ScreenLocking = LoginScreenLocker(),
        activityLog: ActivityLogging = NoActivityLog(),
        idleEvents: IdleEventFetching = NoIdleEvents(),
        settingEvents: SettingEventFetching = NoSettingEvents(),
        brightness: DisplayBrightnessControlling,
        closedLidSettings: ClosedLidSettingsControlling = NoClosedLidSettings(),
        leaseSeconds: Int = 120,
        renewalSleep: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 30_000_000_000) },
        timerCheckSleep: @escaping () async throws -> Void = { try await Task.sleep(nanoseconds: 5_000_000_000) },
        now: @escaping () -> TimeInterval = { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }
    ) {
        self.displayAssertion = displayAssertion
        self.helper = helper
        self.sessions = sessions
        self.preferences = preferences
        self.notifier = notifier
        self.activity = activity
        self.powerSourceMonitor = powerSourceMonitor
        self.powerSource = powerSource
        self.lidMonitor = lidMonitor
        self.screenLocker = screenLocker
        self.activityLog = activityLog
        self.idleEvents = idleEvents
        self.settingEvents = settingEvents
        self.brightness = brightness
        self.closedLidSettings = closedLidSettings
        self.leaseSeconds = leaseSeconds
        self.renewalSleep = renewalSleep
        self.timerCheckSleep = timerCheckSleep
        self.now = now
        preferenceChanges = preferences.changes.sink { [weak self] in
            Task { @MainActor in await self?.safetyChanged() }
        }
        powerSourceMonitor.start { [weak self] in
            Task { @MainActor in await self?.powerSourceChanged() }
        }
        lidMonitor.start { [weak self] closed in
            MainActor.assumeIsolated { self?.lidChanged(closed: closed) }
        }
        timerTask = repeating(timerCheckSleep) { controller in
            await controller.checkTimer()
            await controller.reconcileBrightness()
        }
        try? syncBrightness(active: false)
    }

    /// Shown under the lock setting when it is on but this macOS cannot lock the screen.
    public var screenLockNotice: String? {
        preferences.lockOnLidCloseEnabled && !screenLocker.isAvailable ? ScreenLockNotice.unavailable : nil
    }

    /// Seconds left on the timer of the current mode; nil when the timer is off or no mode runs.
    public func timerRemaining() -> TimeInterval? {
        guard let modeStartedAt, let limit = preferences.timerLimit else { return nil }
        return max(0, TimeInterval(limit) - (now() - modeStartedAt))
    }

    /// Quit completes only after temporary power and display overrides have recovered.
    public func prepareToQuit() async -> Bool {
        isQuitting = true
        do {
            try await select(.off)
        } catch {
            showFailure(error.localizedDescription)
            return false
        }
        while isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        isBusy = true
        defer { isBusy = false }
        var recovered = true
        let display = brightness.restore()
        if display == .pending || display == .unavailable {
            showFailure("Waiting for the built-in display to restore brightness before quitting.")
            recovered = false
        }
        if !closedLidSettings.update(closed: false, mute: false, keyboard: false) {
            showFailure("Waiting for closed-lid settings to be restored before quitting.")
            recovered = false
        }
        if await helper.isReady() {
            do {
                try await endHelperSession()
            } catch {
                showFailure("Power recovery pending: \(error.localizedDescription)")
                recovered = false
            }
        } else if helperRecoveryNeeded {
            showFailure("Waiting for the helper to restore power settings before quitting.")
            recovered = false
        }
        if recovered { message = nil }
        return recovered
    }

    public func select(_ newMode: Mode) async throws {
        try await select(newMode, bySchedule: false)
    }

    /// An explicit choice starts a fresh countdown, including when the value is unchanged.
    public func selectTimer(seconds: Int) async throws {
        guard seconds == 0 || SafetySettings.timerRange.contains(seconds) else {
            let error = HelperError.helper(.invalidArgument, "The timer must be off or between 60 and 86400 seconds.")
            showFailure(error.localizedDescription)
            throw error
        }
        while isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
        guard !isQuitting else { return }
        // An expired local timer must stop before a new preference can be saved for a future session.
        if mode == .keepScreenOn, let remaining = timerRemaining(), remaining <= 0 {
            await checkTimer()
        }
        isBusy = true
        stopRequested = false
        defer { isBusy = false }
        switch mode {
        case .off:
            preferences.selectTimer(seconds: seconds)
        case .keepScreenOn:
            preferences.selectTimer(seconds: seconds)
            modeStartedAt = now()
        case .lidClosed:
            do {
                let origin = try await sessions.resetSessionTimer(timerSeconds: seconds)
                if stopRequested || isQuitting {
                    await leaveCurrentMode()
                    mode = .off
                    recordTurnedOffByUser(.lidClosed)
                    modeEnded(.lidClosed)
                    return
                }
                guard origin.isFinite, origin >= 0, origin <= now() else {
                    throw HelperError.connection(String(localized: "Unexpected helper reply."))
                }
                preferences.selectTimer(seconds: seconds)
                modeStartedAt = origin
            } catch {
                await leaveCurrentMode()
                mode = .off
                if stopRequested || isQuitting {
                    recordTurnedOffByUser(.lidClosed)
                    modeEnded(.lidClosed)
                    return
                }
                if case HelperError.helper(.noSession, _) = error,
                   await reportStopReason(mode: .lidClosed) { throw error }
                let detail = error.localizedDescription
                if case .failed(let recovery)? = message {
                    message = .failed("\(detail) Recovery pending: \(recovery)")
                } else {
                    message = .turnedOffWithError(detail)
                }
                activityLog.record(.modeOff(.lidClosed, .error(detail)))
                modeEnded(.lidClosed)
                throw error
            }
        }
    }

    /// Stay Awake with Sleep when idle for this session, only from Off and only on power.
    /// Called after the Mac woke on schedule.
    public func turnOnBySchedule() async {
        guard mode == .off, !isBusy else { return }
        guard powerSource.read().source == .ac else {
            activityLog.record(.modeSkipped(.lidClosed, .notOnPower))
            return
        }
        let idleSleepWasOn = preferences.idleSleepEnabled
        preferences.beginIdleSleepSession()
        do {
            try await select(.lidClosed, bySchedule: true)
        } catch {
            activityLog.record(.modeSkipped(.lidClosed, .error(error.localizedDescription)))
            if !idleSleepWasOn {
                preferences.endIdleSleepSession()
            }
        }
    }

    private func select(_ newMode: Mode, bySchedule: Bool) async throws {
        if isQuitting, newMode != .off {
            throw HelperError.notReady("Restoring settings before quitting.")
        }
        if isBusy {
            if newMode == .off {
                stopRequested = true
                await withCheckedContinuation { idleWaiters.append($0) }
                if mode != .off { try await select(.off, bySchedule: false) }
            }
            return
        }
        guard newMode != mode else { return }
        stopRequested = false
        isBusy = true
        defer { isBusy = false }
        message = nil
        if newMode != .off {
            requestNotificationAuthorization()
        }

        if mode == .lidClosed {
            // The session's last events, taken before it ends.
            await recordIdleEvents()
        }

        do {
            switch newMode {
            case .off:
                let previous = mode
                await leaveCurrentMode()
                mode = .off
                recordTurnedOffByUser(previous)
                modeEnded(previous)
            case .keepScreenOn:
                let previous = mode
                await leaveCurrentMode()
                mode = .off
                recordTurnedOffByUser(previous)
                modeEnded(previous)
                guard !stopRequested else { return }
                try displayAssertion.acquire()
                mode = .keepScreenOn
                activityLog.record(.modeOn(.keepScreenOn))
                startTimer()
            case .lidClosed:
                try await helper.prepareForSession()
                if stopRequested {
                    await leaveCurrentMode()
                    mode = .off
                    return
                }
                do {
                    // A timeout can arrive after the helper applied changes; reconcile it too.
                    let safety = preferences.helperSettings
                    do {
                        helperRecoveryNeeded = true
                        try await sessions.startSession(leaseSeconds: leaseSeconds, safety: safety)
                    } catch {
                        if !(await acceptOptionalPowerRecovery(error, safety: safety)) { throw error }
                    }
                    guard !stopRequested else { throw CancellationError() }
                    try syncBrightness(active: true)
                    queueSettingEventRefresh()
                } catch {
                    do {
                        try await endHelperSession()
                    } catch {
                        message = .failed("Power recovery pending: \(error.localizedDescription)")
                    }
                    _ = brightness.restore()
                    _ = closedLidSettings.update(closed: false, mute: false, keyboard: false)
                    if stopRequested {
                        await leaveCurrentMode()
                        mode = .off
                        return
                    }
                    throw error
                }
                displayAssertion.release()
                activity.begin()
                recordTurnedOffByUser(mode)
                mode = .lidClosed
                activityLog.record(bySchedule ? .modeOnBySchedule(.lidClosed) : .modeOn(.lidClosed))
                startRenewals()
                startTimer()
                await updatePauseState()
                if stopRequested {
                    await leaveCurrentMode()
                    mode = .off
                    modeEnded(.lidClosed)
                }
            }
        } catch {
            if message == nil { message = .couldNotTurnOn(RefusalNotice.text(for: error)) }
            throw error
        }
    }

    /// Removes the current message; choosing a mode card does this so an old reason does not stay.
    public func dismissMessage() {
        message = nil
    }

    /// Ends a session or clears a lid-closed flag left over from an earlier run and reports why the helper
    /// last stopped, if the helper is ready.
    public func clearLeftover() async {
        guard await helper.isReady(), mode == .off, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        var endedSession = false
        do {
            // A session the helper still holds belongs to an earlier run of the app; its lease would keep
            // the Mac awake for up to two minutes. Without a status the flag is cleared as before.
            if let status = try? await sessions.sessionStatus(), status.session != .noSession {
                try await endHelperSession()
                endedSession = true
            } else {
                helperRecoveryNeeded = true
                do {
                    try await sessions.clearLeftover()
                } catch {
                    queueSettingEventRefresh()
                    throw error
                }
                queueSettingEventRefresh()
                helperRecoveryNeeded = false
            }
        } catch {
            message = .failed(error.localizedDescription)
        }
        await recordIdleEvents()
        if await reportStopReason(mode: .lidClosed) {
            return
        }
        if endedSession {
            message = .restarted
            activityLog.record(.modeOff(.lidClosed, .previousSession))
            modeEnded(.lidClosed)
        }
    }

    func renew() async {
        guard mode == .lidClosed, !isBusy else { return }
        // Serialize the complete RPC/status lifecycle with mode transitions. Standard/Quit waits
        // for it, so old replies cannot end or update the pause state of a newer session.
        isBusy = true
        stopRequested = false
        defer { isBusy = false }
        do {
            let safety = preferences.helperSettings
            do {
                try await sessions.renewSession(leaseSeconds: leaseSeconds, safety: safety)
            } catch {
                if !(await acceptOptionalPowerRecovery(error, safety: safety)) { throw error }
            }
            queueSettingEventRefresh()
            await recordIdleEvents()
            await updatePauseState()
            if stopRequested {
                await leaveCurrentMode()
                mode = .off
                modeEnded(.lidClosed)
            } else {
                try syncBrightness(active: !isPaused)
            }
        } catch {
            await leaveCurrentMode()
            mode = .off
            if case HelperError.helper(.noSession, _) = error {
                await recordIdleEvents()
                if await reportStopReason(mode: .lidClosed) { return }
            }
            let detail = error.localizedDescription
            if case .failed(let recovery)? = message {
                message = .failed("\(detail) Recovery pending: \(recovery)")
            } else {
                message = .turnedOffWithError(detail)
            }
            activityLog.record(.modeOff(.lidClosed, .error(detail)))
            modeEnded(.lidClosed)
        }
    }

    private func acceptOptionalPowerRecovery(_ error: Error, safety: SafetySettings) async -> Bool {
        guard !safety.lowPowerWhenClosed, case HelperError.helper(.powerModeFailed, let detail) = error,
              let status = try? await sessions.sessionStatus(), status.session != .noSession else { return false }
        showFailure(detail)
        return true
    }

    func checkTimer() async {
        guard !isBusy, let remaining = timerRemaining(), remaining <= 0 else { return }
        switch mode {
        case .off:
            break
        case .keepScreenOn:
            isBusy = true
            defer { isBusy = false }
            await leaveCurrentMode()
            mode = .off
            report(StopRecord(reason: .timer, time: Date()), mode: .keepScreenOn)
        case .lidClosed:
            // The helper ends the session on its own; renewing finds out sooner.
            await renew()
        }
    }

    private func safetyChanged() async {
        // A change during a helper RPC must be sent once that operation releases the controller.
        while isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        switch mode {
        case .off:
            break
        case .keepScreenOn:
            await checkTimer()
        case .lidClosed:
            await renew()
        }
    }

    // Stay Awake keeps the Mac awake, so the usual lock on sleep never happens.
    private func lidChanged(closed: Bool) {
        if closed, mode == .lidClosed, preferences.lockOnLidCloseEnabled, screenLocker.isAvailable {
            screenLocker.lock()
        }
        Task { @MainActor [weak self] in await self?.reconcileBrightness() }
    }

    private func syncBrightness(active: Bool) throws {
        let displayActive = active && preferences.displayOffWhenClosed
        let lidState = lidMonitor.isClosed
        if active && lidState == nil && (preferences.displayOffWhenClosed || preferences.muteWhenClosed) {
            throw brightnessError("The lid state could not be read.")
        }
        let closed = lidState == true
        if !closedLidSettings.update(closed: active && closed, mute: preferences.muteWhenClosed,
                                     keyboard: preferences.displayOffWhenClosed) {
            showFailure("A closed-lid audio or keyboard setting could not be applied or restored.")
        }
        let result: DisplayBrightnessResult
        if displayActive && closed {
            result = brightness.close()
        } else {
            result = brightness.restore()
            if preferences.displayOffWhenClosed, lidState == false, result != .pending, result != .unavailable,
               brightness.sampleWhileOpen() == .unavailable, displayActive {
                throw brightnessError("Built-in display brightness is unavailable.")
            }
        }
        if !preferences.displayOffWhenClosed, result == .pending || result == .unavailable {
            showFailure("Display brightness recovery is pending until the built-in display is available.")
            return
        }
        if result == .unavailable {
            throw brightnessError("Built-in display brightness is unavailable; recovery may still be pending.")
        }
        if result == .pending && !(displayActive && closed) {
            throw brightnessError("Display brightness recovery is pending until the built-in display is available.")
        }
        if displayActive && closed && result == .preservedExternalChange {
            throw brightnessError("Another brightness setting was preserved. Re-enable the session to try again.")
        }
    }

    private func brightnessError(_ message: String) -> NSError {
        NSError(domain: HelperConstants.appBundleIdentifier, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func reconcileBrightness() async {
        guard !isBusy else { return }
        do {
            try syncBrightness(active: mode == .lidClosed && !isPaused)
        } catch {
            if mode == .lidClosed {
                isBusy = true
                await leaveCurrentMode()
                mode = .off
                modeEnded(.lidClosed)
                isBusy = false
            }
            showFailure(error.localizedDescription)
        }
    }

    private func showFailure(_ detail: String) {
        if case .failed(let existing)? = message {
            if !existing.contains(detail) { message = .failed("\(existing) \(detail)") }
        } else {
            message = .failed(detail)
        }
    }

    private func powerSourceChanged() async {
        guard mode == .lidClosed else { return }
        await renew()
    }

    /// Asks the helper whether the session is paused and announces a new pause.
    private func updatePauseState() async {
        guard let status = try? await sessions.sessionStatus(), mode == .lidClosed else { return }
        let wasPaused = isPaused
        isPaused = status.paused
        if isPaused && !wasPaused {
            notifier.post(title: PauseNotice.title, body: PauseNotice.body)
            activityLog.record(.paused)
        } else if !isPaused && wasPaused {
            activityLog.record(.resumed)
        }
    }

    /// Writes what the helper saw during the idle count, at the times it saw it. The log only informs,
    /// so a failed call is dropped.
    private func recordIdleEvents() async {
        guard let events = try? await idleEvents.takeIdleEvents() else { return }
        for event in events {
            activityLog.record(ActivityEvent(event.cause), at: event.time)
        }
    }

    /// Log opening may wait for delivery; required recovery and mode transitions never do.
    public func refreshSettingEvents() async {
        await queueSettingEventRefresh().value
    }

    /// Coalesce requests, including one final drain for changes made during an in-flight fetch.
    @discardableResult
    private func queueSettingEventRefresh() -> Task<Void, Never> {
        settingEventRefreshNeeded = true
        if let settingEventTask { return settingEventTask }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { settingEventTask = nil }
            while settingEventRefreshNeeded {
                settingEventRefreshNeeded = false
                guard let events = try? await settingEvents.takeSettingEvents() else { continue }
                for event in events { activityLog.record(.setting(event), at: event.time) }
            }
        }
        settingEventTask = task
        return task
    }

    private func requestNotificationAuthorization() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        notifier.requestAuthorization()
    }

    /// Shows and clears the reason the helper last ended a session; false when there is none.
    @discardableResult
    private func reportStopReason(mode: Mode) async -> Bool {
        let record: StopRecord?
        do {
            record = try await sessions.lastStopReason()
        } catch {
            return false
        }
        guard let record else { return false }
        report(record, mode: mode)
        do {
            try await sessions.clearStopReason()
        } catch {
            message = .failed(error.localizedDescription)
        }
        return true
    }

    // The window shows the text too, so it is seen even without notification permission.
    private func report(_ record: StopRecord, mode: Mode) {
        let body = StopNotice.body(for: record)
        notifier.post(title: StopNotice.title, body: body)
        if case .failed(let recovery)? = message {
            message = .failed("\(body) Recovery pending: \(recovery)")
        } else {
            message = .turnedOff(body)
        }
        let reason = ModeOffReason.stopped(
            record.reason,
            batteryPercent: record.batteryPercent,
            idleMinutes: record.idleMinutes,
            timerSeconds: record.reason == .timer ? preferences.timerLimit : nil
        )
        // The helper's time, since a stop found after the Mac woke happened before it slept.
        activityLog.record(.modeOff(mode, reason), at: record.time)
        modeEnded(mode)
    }

    private func recordTurnedOffByUser(_ previous: Mode) {
        guard previous != .off else { return }
        activityLog.record(.modeOff(previous, .user))
    }

    /// Called after the mode is left, so the helper got its last settings with the session still running.
    private func modeEnded(_ previous: Mode) {
        guard previous == .lidClosed else { return }
        preferences.endIdleSleepSession()
    }

    private func endHelperSession() async throws {
        helperRecoveryNeeded = true
        do {
            try await sessions.endSession()
        } catch {
            queueSettingEventRefresh()
            throw error
        }
        queueSettingEventRefresh()
        helperRecoveryNeeded = false
    }

    private func leaveCurrentMode() async {
        modeStartedAt = nil
        switch mode {
        case .off:
            break
        case .keepScreenOn:
            displayAssertion.release()
        case .lidClosed:
            renewalTask?.cancel()
            renewalTask = nil
            isPaused = false
            do {
                try await endHelperSession()
            } catch {
                showFailure(error.localizedDescription)
            }
            activity.end()
        }
        let restored = brightness.restore()
        if !closedLidSettings.update(closed: false, mute: false, keyboard: false) {
            showFailure("Closed-lid audio or keyboard recovery is pending.")
        }
        if restored == .pending || restored == .unavailable {
            showFailure("Display brightness recovery is pending until the built-in display is available.")
        }
    }

    private func startRenewals() {
        renewalTask = repeating(renewalSleep) { await $0.renew() }
    }

    private func startTimer() {
        modeStartedAt = now()

    }

    private func repeating(
        _ sleep: @escaping () async throws -> Void,
        _ action: @escaping (ModeController) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            while true {
                do {
                    try await sleep()
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await action(self)
            }
        }
    }
}
