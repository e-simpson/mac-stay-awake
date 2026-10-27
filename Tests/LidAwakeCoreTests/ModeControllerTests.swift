import LidAwakeShared
import XCTest
@testable import LidAwakeCore

private final class FakeAssertion: PowerAssertion {
    var shouldFail = false
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var isHeld = false


    func acquire() throws {
        acquireCount += 1
        if shouldFail {
            throw PowerAssertionError(code: -1)
        }
        isHeld = true
    }

    func release() {
        releaseCount += 1
        isHeld = false
    }
}

@MainActor
private final class FakeHelper: HelperPreparing {
    var notReady: HelperError?
    private(set) var prepareCount = 0

    func prepareForSession() async throws {
        prepareCount += 1
        if let notReady { throw notReady }
    }

    func isReady() async -> Bool {
        notReady == nil
    }
}

@MainActor
private final class FakeSessions: LidSessionService {
    var timerResetError: Error?
    var timerResetOrigin: TimeInterval = 1000
    var onTimerReset: (() async -> Void)?
    var startError: Error?
    var onStart: (() async -> Void)?
    var renewError: Error?
    var endError: Error?
    var onRenew: (() async -> Void)?
    var onStatus: (() async -> Void)?
    var stopRecord: StopRecord?
    var paused = false
    var session: SessionOwnership = .noSession
    var statusError: Error?
    private(set) var calls: [String] = []
    /// The number of other calls made before each status request.
    private(set) var statusRequests: [Int] = []
    private(set) var safety: [SafetySettings] = []

    func startSession(leaseSeconds: Int, safety: SafetySettings) async throws {
        calls.append("start \(leaseSeconds)")
        await onStart?()
        self.safety.append(safety)
        if let startError { throw startError }
    }

    func renewSession(leaseSeconds: Int, safety: SafetySettings) async throws {
        calls.append("renew \(leaseSeconds)")
        await onRenew?()
        self.safety.append(safety)
        if let renewError { throw renewError }
    }

    func resetSessionTimer(timerSeconds: Int) async throws -> TimeInterval {
        calls.append("reset timer \(timerSeconds)")
        await onTimerReset?()
        if let timerResetError { throw timerResetError }
        return timerResetOrigin
    }

    /// Read when the session ends, to see what was true at that moment.
    var probeAtEnd: (() -> Bool)?
    private(set) var probedAtEnd: [Bool] = []

    func endSession() async throws {
        calls.append("end")
        if let endError { throw endError }
        if let probeAtEnd { probedAtEnd.append(probeAtEnd()) }
    }

    func clearLeftover() async throws {
        calls.append("clear")
    }

    func sessionStatus() async throws -> HelperSessionStatus {
        statusRequests.append(calls.count)
        await onStatus?()
        if let statusError { throw statusError }
        return HelperSessionStatus(
            flag: .unknown,
            session: session,
            timerRemaining: nil,
            power: PowerReading(battery: .unknown, source: .unknown),
            thermal: .unknown,
            paused: paused
        )
    }

    func lastStopReason() async throws -> StopRecord? {
        calls.append("reason")
        return stopRecord
    }

    func clearStopReason() async throws {
        calls.append("clear reason")
        stopRecord = nil
    }
}

@MainActor
private final class FakeNotifier: StopNotifying {
    private(set) var authorizationRequests = 0
    private(set) var posts: [String] = []

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func post(title: String, body: String) {
        posts.append("\(title): \(body)")
    }
}

private final class FakePowerSourceMonitor: PowerSourceMonitoring {
    private var handler: (() -> Void)?

    func start(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func change() {
        handler?()
    }
}

private final class FakePowerSource: PowerSourceReading {
    var source: PowerSource = .ac
    private(set) var reads = 0

    func read() -> PowerReading {
        reads += 1
        return PowerReading(battery: .percent(80), source: source)
    }
}

@MainActor
private final class FakeWakeService: ScheduledWakeService {
    var wakes: [Date] = []
    private let sessions: FakeSessions
    /// The enabled minutes of each call and the session calls made before it.
    private(set) var requests: [(minutes: [Int], sessionCalls: [String])] = []

    init(sessions: FakeSessions) {
        self.sessions = sessions
    }

    func setScheduledWakes(minutesOfDay: [Int]) async throws {
        requests.append((minutesOfDay, sessions.calls))
    }

    func scheduledWakes() async throws -> [Date] {
        wakes
    }
}

private final class FakeClockMonitor: ClockChangeMonitoring {
    func start(_ handler: @escaping () -> Void) {}
}

@MainActor
private final class FakeBrightness: DisplayBrightnessControlling {
    var closed = 0
    var restores = 0
    var samples = 0
    var sampleResult = DisplayBrightnessResult.sampled
    var closeResult = DisplayBrightnessResult.dimmed
    var restoreResult = DisplayBrightnessResult.restored
    func sampleWhileOpen() -> DisplayBrightnessResult { samples += 1; return sampleResult }
    func close() -> DisplayBrightnessResult { closed += 1; return closeResult }
    func restore() -> DisplayBrightnessResult { restores += 1; return restoreResult }
}

private final class FakeLidMonitor: LidMonitoring {
    var isClosed: Bool? = false
    private var handler: ((Bool) -> Void)?

    func start(_ handler: @escaping (Bool) -> Void) {
        self.handler = handler
    }

    func change(closed: Bool) {
        isClosed = closed
        handler?(closed)
    }
}

@MainActor
private final class FakeClosedLidSettings: ClosedLidSettingsControlling {
    var calls: [(closed: Bool, mute: Bool, keyboard: Bool)] = []
    var succeeds = true
    func update(closed: Bool, mute: Bool, keyboard: Bool) -> Bool {
        calls.append((closed, mute, keyboard))
        return succeeds
    }
}

private final class FakeScreenLocker: ScreenLocking {
    var isAvailable = true
    private(set) var lockCount = 0

    func lock() {
        lockCount += 1
    }
}

@MainActor
private final class FakeActivityLog: ActivityLogging {
    private(set) var records: [(event: ActivityEvent, time: Date?)] = []

    var events: [ActivityEvent] {
        records.map(\.event)
    }

    func record(_ event: ActivityEvent, at time: Date?) {
        records.append((event, time))
    }
}

@MainActor
private final class FakeIdleEvents: IdleEventFetching {
    var pending: [IdleEvent] = []
    var error: Error?
    private let sessions: FakeSessions
    /// The session calls made before each request, so its place among them can be checked.
    private(set) var requests: [[String]] = []

    init(sessions: FakeSessions) {
        self.sessions = sessions
    }

    func takeIdleEvents() async throws -> [IdleEvent] {
        requests.append(sessions.calls)
        if let error { throw error }
        defer { pending = [] }
        return pending
    }
}

@MainActor
private final class FakeSettingEvents: SettingEventFetching {
    var fetch: () async throws -> [SettingEvent] = { [] }
    func takeSettingEvents() async throws -> [SettingEvent] { try await fetch() }
}

private final class FakeTime {
    var now: TimeInterval = 1000
}

private final class FakeActivity: ActivityHolding {
    private(set) var isActive = false

    func begin() { isActive = true }
    func end() { isActive = false }
}

@MainActor
final class ModeControllerTests: XCTestCase {
    private let assertion = FakeAssertion()
    private let helper = FakeHelper()
    private let sessions = FakeSessions()
    private let activity = FakeActivity()
    private let notifier = FakeNotifier()
    private let powerMonitor = FakePowerSourceMonitor()
    private let lidMonitor = FakeLidMonitor()
    private let brightness = FakeBrightness()
    private let closedLidSettings = FakeClosedLidSettings()
    private let power = FakePowerSource()
    private let locker = FakeScreenLocker()
    private let time = FakeTime()
    private let log = FakeActivityLog()
    private let settingEvents = FakeSettingEvents()
    private lazy var idleEvents = FakeIdleEvents(sessions: sessions)
    private let suiteName = "ModeControllerTests-\(UUID().uuidString)"
    private lazy var preferences: SafetyPreferences = {
        let defaults = UserDefaults(suiteName: suiteName)!
        // These integration scenarios opt out of the timer and explicitly enable screen locking.
        defaults.set(false, forKey: SafetyPreferences.Key.timerEnabled)
        defaults.set(true, forKey: SafetyPreferences.Key.lockOnLidCloseEnabled)
        return SafetyPreferences(defaults: defaults)
    }()

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController(renewalSleep: (() async throws -> Void)? = nil) -> ModeController {
        let time = self.time
        return ModeController(
            displayAssertion: assertion,
            helper: helper,
            sessions: sessions,
            preferences: preferences,
            notifier: notifier,
            activity: activity,
            powerSourceMonitor: powerMonitor,
            powerSource: power,
            lidMonitor: lidMonitor,
            screenLocker: locker,
            activityLog: log,
            idleEvents: idleEvents,
            settingEvents: settingEvents,
            brightness: brightness,
            closedLidSettings: closedLidSettings,
            leaseSeconds: 120,
            renewalSleep: renewalSleep ?? { try await Task.sleep(nanoseconds: 3_600_000_000_000) },
            timerCheckSleep: { try await Task.sleep(nanoseconds: 3_600_000_000_000) },
            now: { time.now }
        )
    }

    func testRefusalNoticeTranslatesProtectionsOnly() {
        // Run without the app bundle, the localized text is the English key, so a translated refusal
        // differs from the helper's text only where the wording differs.
        XCTAssertEqual(
            RefusalNotice.text(for: HelperError.helper(.thermalLimitReached, "The Mac is too hot (thermal state critical).")),
            "The Mac got too hot."
        )
        XCTAssertEqual(
            RefusalNotice.text(for: HelperError.helper(.batteryLimitReached, "The battery is at 18%, at or below the 30% limit.")),
            String(localized: "The battery is at \(18)%, at or below the \(30)% limit.")
        )
        XCTAssertEqual(
            RefusalNotice.text(for: HelperError.helper(.batteryLimitReached, "Something else.")),
            "Something else."
        )
        XCTAssertEqual(
            RefusalNotice.text(for: HelperError.helper(.flagReadFailed, "The battery level could not be read.")),
            "The battery level could not be read."
        )
        XCTAssertEqual(RefusalNotice.text(for: HelperError.timeout), HelperError.timeout.localizedDescription)
    }

    func testClosedLidSettingsFollowLidPreferencesAndQuitRecovery() async throws {
        preferences.muteWhenClosed = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        lidMonitor.change(closed: true)
        await settle { self.closedLidSettings.calls.contains { $0.closed && $0.mute && $0.keyboard } }
        XCTAssertTrue(closedLidSettings.calls.contains { $0.closed && $0.mute && $0.keyboard })
        preferences.displayOffWhenClosed = false
        await settle { self.closedLidSettings.calls.contains { $0.closed && $0.mute && !$0.keyboard } }
        XCTAssertTrue(closedLidSettings.calls.contains { $0.closed && $0.mute && !$0.keyboard })
        lidMonitor.change(closed: false)
        await settle { self.closedLidSettings.calls.last?.closed == false }
        XCTAssertFalse(closedLidSettings.calls.last?.closed ?? true)
        closedLidSettings.succeeds = false
        let pending = await controller.prepareToQuit()
        XCTAssertFalse(pending)
        XCTAssertNotNil(controller.message)
        closedLidSettings.succeeds = true
        let recovered = await controller.prepareToQuit()
        XCTAssertTrue(recovered)
    }

    func testMuteRequiresKnownLidStateEvenWhenDisplayDimmingIsDisabled() async {
        preferences.displayOffWhenClosed = false
        preferences.muteWhenClosed = true
        lidMonitor.isClosed = nil
        let controller = makeController()
        do {
            try await controller.select(.lidClosed)
            XCTFail("A session requiring lid-triggered mute must not start without the lid state")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(closedLidSettings.calls.contains { $0.closed })
        XCTAssertTrue(sessions.calls.contains("end"))
    }

    func testSuspendedSettingFetchCannotDelayRecoveryOrModeTransitions() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        await controller.refreshSettingEvents()
        var resume: CheckedContinuation<[SettingEvent], Never>?
        var calls = 0
        settingEvents.fetch = {
            calls += 1
            if calls == 1 { return await withCheckedContinuation { resume = $0 } }
            return []
        }
        defer { resume?.resume(returning: []) }
        let priorRestores = brightness.restores
        var finished = false
        let leaving = Task {
            try await controller.select(.off)
            finished = true
        }
        await settle { resume != nil }
        await settle { finished }
        XCTAssertTrue(finished, "A suspended observation fetch must not block ending the mode")
        XCTAssertGreaterThan(brightness.restores, priorRestores, "Display recovery must finish before event delivery")
        XCTAssertFalse(controller.isBusy)
        if !finished {
            resume?.resume(returning: [])
            resume = nil
            try await leaving.value
            return
        }
        try await leaving.value

        // A fetch already in flight must not block any other lifecycle path either.
        try await controller.select(.lidClosed)
        sessions.renewError = HelperError.timeout
        sessions.endError = HelperError.helper(.powerModeFailed, "Recovery pending")
        let beforeFailedRenewal = brightness.restores
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertGreaterThan(brightness.restores, beforeFailedRenewal)
        sessions.startError = HelperError.timeout
        let beforeRollback = brightness.restores
        do { try await controller.select(.lidClosed); XCTFail("Start must fail") } catch {}
        XCTAssertGreaterThan(brightness.restores, beforeRollback)
        XCTAssertFalse(controller.isBusy)
        sessions.endError = nil
        await controller.clearLeftover()
        let canQuit = await controller.prepareToQuit()
        XCTAssertTrue(canQuit)
        XCTAssertEqual(calls, 1, "In-flight requests must be coalesced")
        resume?.resume(returning: [])
        resume = nil
        await controller.refreshSettingEvents()
        XCTAssertEqual(calls, 2, "Changes made during a fetch need one final drain")
    }

    func testSettingEventsAreDrainedAfterFailedRollbackAndCleanup() async throws {
        let controller = makeController()
        let event = SettingEvent(time: Date(timeIntervalSince1970: 1234), setting: .powerMode,
            source: .battery, operation: .restore, outcome: .pending, key: .powermode, target: 0)
        var delivered = false
        var requests: [[String]] = []
        settingEvents.fetch = {
            requests.append(self.sessions.calls)
            guard self.sessions.calls.contains("end"), !delivered else { return [] }
            delivered = true
            return [event]
        }
        sessions.startError = HelperError.timeout
        sessions.endError = HelperError.helper(.powerModeFailed, "Recovery pending")
        do { try await controller.select(.lidClosed); XCTFail("Start must fail") } catch {}
        await controller.refreshSettingEvents()
        XCTAssertTrue(delivered)
        XCTAssertTrue(requests.allSatisfy { $0 == ["start 120", "end"] },
                      "Cleanup must begin before best-effort observation delivery")
        XCTAssertEqual(log.records.first(where: { $0.event == .setting(event) })?.time, event.time)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertNotNil(controller.message)

        sessions.startError = nil
        sessions.endError = nil
        delivered = false
        sessions.session = .ours
        await controller.clearLeftover()
        await controller.refreshSettingEvents()
        XCTAssertTrue(delivered)
    }

    func testSettingEventDeliveryFailureDoesNotEndSession() async throws {
        settingEvents.fetch = { throw HelperError.timeout }
        let controller = makeController()
        try await controller.select(.lidClosed)
        await controller.renew()
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertNil(controller.message)
        try await controller.select(.off)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertNil(controller.message)
    }

    func testQuitWaitsForPendingDisplayRecoveryEvenInNormalMode() async {
        let controller = makeController()
        brightness.restoreResult = .pending
        let blocked = await controller.prepareToQuit()
        XCTAssertFalse(blocked)
        XCTAssertNotNil(controller.message)
        brightness.restoreResult = .restored
        do {
            try await controller.select(.lidClosed)
            XCTFail("A pending Quit must not start a new override")
        } catch {}
        let restored = await controller.prepareToQuit()
        XCTAssertTrue(restored)
    }

    func testQuitWaitsForFailedPowerRecoveryAndCanRetry() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.endError = NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Power recovery failed"])
        let blocked = await controller.prepareToQuit()
        XCTAssertFalse(blocked)
        XCTAssertEqual(controller.mode, .off)
        sessions.endError = nil
        let restored = await controller.prepareToQuit()
        XCTAssertTrue(restored)
    }

    func testQuitCannotSkipRecoveryWhenUsedHelperBecomesUnavailable() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.endError = HelperError.timeout
        helper.notReady = .timeout
        let blocked = await controller.prepareToQuit()
        XCTAssertFalse(blocked)
        XCTAssertNotNil(controller.message)
    }

    func testQuitRetriesFailedUnknownCleanupAfterHelperDisappears() async {
        let controller = makeController()
        sessions.endError = HelperError.timeout
        let first = await controller.prepareToQuit()
        XCTAssertFalse(first)
        helper.notReady = .timeout
        let second = await controller.prepareToQuit()
        XCTAssertFalse(second)
    }

    func testQuitRecoveryObligationSurvivesControllerRelaunch() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.endError = HelperError.timeout
        let first = await controller.prepareToQuit()
        XCTAssertFalse(first)
        helper.notReady = .timeout
        let relaunched = makeController()
        let second = await relaunched.prepareToQuit()
        XCTAssertFalse(second)
    }

    func testFailedStartupCleanupCannotBeSkippedByQuit() async {
        let controller = makeController()
        sessions.session = .ours
        sessions.endError = HelperError.timeout
        await controller.clearLeftover()
        helper.notReady = .timeout
        let restored = await controller.prepareToQuit()
        XCTAssertFalse(restored)
    }

    func testQuitWithoutInstalledHelperNeedsNoPowerOperation() async {
        helper.notReady = .notReady("Not installed")
        let controller = makeController()
        let restored = await controller.prepareToQuit()
        XCTAssertTrue(restored)
        XCTAssertTrue(sessions.calls.isEmpty)
    }

    func testLidCycleDimsAndRestoresDuringAnEnabledSession() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        let restores = brightness.restores
        lidMonitor.change(closed: true)
        await settle { self.brightness.closed == 1 }
        XCTAssertEqual(brightness.closed, 1)
        lidMonitor.change(closed: false)
        await settle { self.brightness.restores > restores }
        XCTAssertGreaterThan(brightness.restores, restores)
        XCTAssertEqual(controller.mode, .lidClosed)
        try await controller.select(.off)
    }

    func testDisabledOverridesKeepCoreSessionActiveWithoutBrightnessSupport() async throws {
        preferences.displayOffWhenClosed = false
        preferences.lowPowerWhenClosed = false
        brightness.sampleResult = .unavailable
        brightness.closeResult = .unavailable
        lidMonitor.isClosed = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.safety.last!.lowPowerWhenClosed)
        XCTAssertEqual(brightness.closed, 0)
        XCTAssertEqual(brightness.samples, 0)
        XCTAssertFalse(sessions.calls.contains("end"))
        try await controller.select(.off)
    }

    func testDisplayOverrideOffRestoresDuringClosedSessionAndCanBeReenabled() async throws {
        lidMonitor.isClosed = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        let dimmed = brightness.closed
        let restored = brightness.restores
        preferences.displayOffWhenClosed = false
        await settle { self.brightness.restores > restored && !controller.isBusy }
        XCTAssertEqual(brightness.closed, dimmed)
        XCTAssertGreaterThan(brightness.restores, restored)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertTrue(sessions.safety.last!.lowPowerWhenClosed)

        preferences.displayOffWhenClosed = true
        await settle { self.brightness.closed > dimmed && !controller.isBusy }
        XCTAssertGreaterThan(brightness.closed, dimmed)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.calls.contains("end"))
        try await controller.select(.off)
    }

    func testOverrideChangeDuringRenewalIsSentAfterTheInflightSettings() async throws {
        lidMonitor.isClosed = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        var resume: CheckedContinuation<Void, Never>?
        sessions.onRenew = { await withCheckedContinuation { resume = $0 } }
        let renewing = Task { await controller.renew() }
        await settle { resume != nil }
        let restores = brightness.restores
        let closes = brightness.closed
        preferences.displayOffWhenClosed = false
        preferences.lowPowerWhenClosed = false
        sessions.onRenew = nil
        resume?.resume()
        await renewing.value
        await settle { self.sessions.safety.last?.lowPowerWhenClosed == false && !controller.isBusy }
        XCTAssertFalse(sessions.safety.last!.lowPowerWhenClosed)
        XCTAssertGreaterThan(brightness.restores, restores)
        XCTAssertEqual(brightness.closed, closes)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.calls.contains("end"))
        try await controller.select(.off)
    }

    func testDisabledDisplayRecoveryPendingKeepsSessionAwakeAndRetries() async throws {
        lidMonitor.isClosed = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        brightness.restoreResult = .pending
        let restores = brightness.restores
        let closes = brightness.closed
        preferences.displayOffWhenClosed = false
        await settle { self.brightness.restores > restores && !controller.isBusy }
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.calls.contains("end"))
        guard case .failed(let warning)? = controller.message else {
            return XCTFail("Pending optional recovery must remain visible")
        }
        XCTAssertTrue(warning.contains("brightness"))
        let retries = brightness.restores
        await controller.renew()
        XCTAssertGreaterThan(brightness.restores, retries)
        XCTAssertEqual(brightness.closed, closes)
        XCTAssertEqual(controller.mode, .lidClosed)
        brightness.restoreResult = .restored
        await controller.renew()
        XCTAssertEqual(controller.mode, .lidClosed)
        try await controller.select(.off)
    }

    func testDisabledLowPowerRecoveryFailureKeepsActivationAndRenewalActive() async throws {
        preferences.lowPowerWhenClosed = false
        sessions.session = .ours
        let recovery = HelperError.helper(.powerModeFailed, "Optional power recovery pending")
        sessions.startError = recovery
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.calls.contains("end"))
        XCTAssertEqual(controller.message, .failed("Optional power recovery pending"))
        sessions.renewError = recovery
        await controller.renew()
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.calls.contains("end"))
        sessions.renewError = nil
        await controller.renew()
        XCTAssertEqual(controller.mode, .lidClosed)
        try await controller.select(.off)
    }

    func testRequiredLowPowerActivationFailureStillRollsBack() async {
        sessions.startError = HelperError.helper(.powerModeFailed, "Required power mode unavailable")
        let controller = makeController()
        var resume: CheckedContinuation<Void, Never>?
        sessions.onStart = { await withCheckedContinuation { resume = $0 } }
        let activating = Task { try await controller.select(.lidClosed) }
        await settle { resume != nil }
        preferences.lowPowerWhenClosed = false
        resume?.resume()
        do {
            try await activating.value
            XCTFail("Required override failure must reject activation")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertTrue(sessions.calls.contains("end"))
    }

    func testOptionalPowerWarningCannotClaimANonexistentHelperSession() async {
        preferences.lowPowerWhenClosed = false
        sessions.startError = HelperError.helper(.powerModeFailed, "Power recovery pending")
        sessions.session = .noSession
        let controller = makeController()
        do {
            try await controller.select(.lidClosed)
            XCTFail("An inactive helper cannot keep the core session awake")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertTrue(sessions.calls.contains("end"))
    }

    func testOverrideChangeDuringActivationIsSentAfterTheInflightSettings() async throws {
        lidMonitor.isClosed = true
        let controller = makeController()
        var resume: CheckedContinuation<Void, Never>?
        sessions.onStart = { await withCheckedContinuation { resume = $0 } }
        let activating = Task { try await controller.select(.lidClosed) }
        await settle { resume != nil }
        preferences.displayOffWhenClosed = false
        preferences.lowPowerWhenClosed = false
        await Task.yield()
        resume?.resume()
        try await activating.value
        await settle { self.sessions.safety.last?.lowPowerWhenClosed == false && !controller.isBusy }
        XCTAssertTrue(sessions.safety.first!.lowPowerWhenClosed, "The suspended request held its original settings")
        XCTAssertFalse(sessions.safety.last!.lowPowerWhenClosed)
        XCTAssertEqual(brightness.closed, 0)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(sessions.calls.contains("end"))
        try await controller.select(.off)
    }

    func testBrightnessFailureEndsTheSessionAndReportsUnavailable() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        brightness.closeResult = .unavailable
        lidMonitor.change(closed: true)
        await settle { controller.mode == .off }
        XCTAssertEqual(controller.mode, .off)
        XCTAssertTrue(sessions.calls.contains("end"))
        XCTAssertNotNil(controller.message)
    }

    func testBrightnessFailureCannotHidePowerRecovery() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.endError = NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Simulated power recovery failure"])
        brightness.closeResult = .unavailable
        lidMonitor.change(closed: true)
        await settle { controller.mode == .off }
        guard case .failed(let text)? = controller.message else {
            return XCTFail("Recovery must remain visible")
        }
        XCTAssertTrue(text.contains("Simulated power recovery failure"))
        XCTAssertTrue(text.contains("brightness"))
    }

    func testOffDuringActivationCannotLeaveALateSessionRunning() async throws {
        let controller = makeController()
        var resume: CheckedContinuation<Void, Never>?
        sessions.onStart = { await withCheckedContinuation { resume = $0 } }
        let activating = Task { try await controller.select(.lidClosed) }
        await settle { resume != nil }
        var stopEntered = false
        let stopping = Task { stopEntered = true; try await controller.select(.off) }
        await settle { stopEntered }
        resume?.resume()
        try await activating.value
        try await stopping.value
        XCTAssertEqual(controller.mode, .off)
        XCTAssertTrue(sessions.calls.contains("end"))
        XCTAssertEqual(brightness.closed, 0)
    }

    func testStandardWaitsForRenewalBeforeAnotherSessionCanStart() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        var resume: CheckedContinuation<Void, Never>?
        sessions.onRenew = { await withCheckedContinuation { resume = $0 } }
        let renewing = Task { await controller.renew() }
        await settle { resume != nil }
        var stopEntered = false
        let stopping = Task { stopEntered = true; try await controller.select(.off) }
        await settle { stopEntered }
        XCTAssertFalse(sessions.calls.contains("end"), "Cleanup must not race an older power RPC")
        resume?.resume()
        await renewing.value
        try await stopping.value
        XCTAssertEqual(controller.mode, .off)
        sessions.onRenew = nil
        try await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .lidClosed)
        try await controller.select(.off)
    }

    func testStandardDuringFinalActivationStatusIsNotLost() async throws {
        let controller = makeController()
        var resume: CheckedContinuation<Void, Never>?
        sessions.onStatus = { await withCheckedContinuation { resume = $0 } }
        let activating = Task { try await controller.select(.lidClosed) }
        await settle { resume != nil }
        var stopEntered = false
        let stopping = Task { stopEntered = true; try await controller.select(.off) }
        await settle { stopEntered }
        resume?.resume()
        try await activating.value
        try await stopping.value
        XCTAssertEqual(controller.mode, .off)
        XCTAssertTrue(sessions.calls.contains("end"))
    }

    func testFailedActivationStillAttemptsCleanupOfUncertainHelperState() async {
        let controller = makeController()
        sessions.startError = HelperError.timeout
        do {
            try await controller.select(.lidClosed)
            XCTFail("A timed-out activation must be reported")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertTrue(sessions.calls.contains("end"))
    }

    func testSafetyReasonCannotHideFailedRecovery() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.stopRecord = StopRecord(reason: .timer, time: Date())
        sessions.renewError = HelperError.helper(.noSession, "Session ended")
        sessions.endError = NSError(domain: "test", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Simulated recovery failure"])
        await controller.renew()
        guard case .failed(let text)? = controller.message else { return XCTFail("Recovery must remain visible") }
        XCTAssertTrue(text.contains("Recovery pending"))
        XCTAssertTrue(text.contains("Simulated recovery failure"))
        XCTAssertTrue(text.contains(StopNotice.body(for: StopRecord(reason: .timer, time: Date()))))
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            await Task.yield()
        }
    }

    func testStartsOff() {
        let controller = makeController()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(assertion.isHeld)
    }

    func testKeepScreenOnAcquiresAndOffReleases() async throws {
        let controller = makeController()

        try await controller.select(.keepScreenOn)
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertTrue(assertion.isHeld)

        try await controller.select(.off)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(assertion.isHeld)
    }

    func testRepeatedKeepScreenOnCreatesOneAssertion() async throws {
        let controller = makeController()

        try await controller.select(.keepScreenOn)
        try await controller.select(.keepScreenOn)

        XCTAssertEqual(assertion.acquireCount, 1)
        XCTAssertEqual(controller.mode, .keepScreenOn)
    }

    func testAcquireFailureLeavesModeOff() async {
        assertion.shouldFail = true
        let controller = makeController()

        do {
            try await controller.select(.keepScreenOn)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(controller.message?.title, "Could not turn on")
    }

    func testLidClosedStartsSession() async throws {
        let controller = makeController()

        try await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertEqual(helper.prepareCount, 1)
        XCTAssertEqual(sessions.calls, ["start 120"])
        XCTAssertTrue(activity.isActive)
        XCTAssertNil(controller.message)
    }

    func testLidClosedNeedsReadyHelper() async {
        helper.notReady = .notReady("Install the helper to run with the lid closed.")
        let controller = makeController()

        do {
            try await controller.select(.lidClosed)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(sessions.calls, [])
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(controller.message, .couldNotTurnOn("Install the helper to run with the lid closed."))
    }

    func testLidClosedStartFailureKeepsKeepScreenOn() async throws {
        sessions.startError = HelperError.helper(.flagReadFailed, "Could not read SleepDisabled")
        let controller = makeController()
        try await controller.select(.keepScreenOn)

        do {
            try await controller.select(.lidClosed)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertTrue(assertion.isHeld)
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(controller.message, .couldNotTurnOn("Could not read SleepDisabled"))
    }

    func testKeepScreenOnToLidClosedReleasesAssertion() async throws {
        let controller = makeController()
        try await controller.select(.keepScreenOn)

        try await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(assertion.isHeld)
    }

    func testOffEndsSession() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        try await controller.select(.off)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(sessions.calls, ["start 120", "end"])
        XCTAssertFalse(activity.isActive)
    }

    func testKeepScreenOnEndsSession() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        try await controller.select(.keepScreenOn)
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertEqual(sessions.calls, ["start 120", "end"])
        XCTAssertTrue(assertion.isHeld)
        XCTAssertFalse(activity.isActive)
    }

    func testRenewKeepsMode() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        await controller.renew()
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])
    }

    func testRenewFailureReturnsToOff() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.renewError = HelperError.timeout
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "end"])
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(controller.message, .turnedOffWithError(HelperError.timeout.localizedDescription))
    }

    func testMissingSessionReturnsToOff() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(controller.message, .turnedOffWithError("No active session."))
    }

    func testRenewalsRunOnSchedule() async throws {
        let ticks = AsyncStream<Void>.makeStream()
        var iterator = ticks.stream.makeAsyncIterator()
        let tick = { () async throws -> Void in
            _ = await iterator.next()
            try Task.checkCancellation()
        }
        let controller = makeController(renewalSleep: tick)
        try await controller.select(.lidClosed)

        ticks.continuation.yield()
        for _ in 0..<100 where sessions.calls.count < 2 {
            await Task.yield()
        }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])

        try await controller.select(.off)
        ticks.continuation.yield()
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "end"])
    }

    func testClearLeftoverWhenHelperReady() async {
        let controller = makeController()
        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["clear", "reason"])
    }

    func testClearLeftoverSkippedWithoutHelper() async {
        helper.notReady = .notReady("Install the helper to run with the lid closed.")
        let controller = makeController()
        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, [])
        XCTAssertEqual(sessions.statusRequests, [])
        XCTAssertNil(controller.message)
    }

    func testLaunchStaysOff() async {
        preferences.timerEnabled = true
        let controller = makeController()

        await controller.clearLeftover()
        await settle(until: { false })
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(assertion.acquireCount, 0)
        XCTAssertFalse(sessions.calls.contains("start 120"))
        XCTAssertFalse(activity.isActive)
        XCTAssertNil(controller.modeStartedAt)
    }

    func testLaunchEndsSessionOfEarlierRun() async {
        await assertLaunchEndsSession(.ours)
    }

    func testLaunchEndsForeignSessionOfEarlierRun() async {
        await assertLaunchEndsSession(.foreign)
    }

    private func assertLaunchEndsSession(_ session: SessionOwnership) async {
        sessions.session = session
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["end", "reason"])
        XCTAssertEqual(controller.message, .restarted)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(controller.isBusy)
        XCTAssertEqual(notifier.posts, [])
    }

    func testLaunchWithoutSessionClearsLeftoverQuietly() async {
        sessions.session = .noSession
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(sessions.statusRequests, [0])
        XCTAssertEqual(sessions.calls, ["clear", "reason"])
        XCTAssertNil(controller.message)
        XCTAssertEqual(notifier.posts, [])
    }

    func testLaunchClearsLeftoverWhenStatusFails() async {
        sessions.statusError = HelperError.timeout
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["clear", "reason"])
        XCTAssertNil(controller.message)
    }

    func testStoredReasonWinsOverEndedSession() async {
        sessions.session = .ours
        sessions.stopRecord = StopRecord(reason: .leaseExpired, time: Date())
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["end", "reason", "clear reason"])
        XCTAssertEqual(controller.message, .turnedOff("MacStayAwake closed unexpectedly, so normal sleep was restored."))
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: MacStayAwake closed unexpectedly, so normal sleep was restored."])
    }

    func testLaunchLeavesRunningModeAlone() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.session = .ours

        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["start 120"])
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertNil(controller.message)
    }

    // MARK: Safety limits and notifications

    func testStoredPreferencesAreUsed() {
        XCTAssertFalse(preferences.timerEnabled)
        XCTAssertEqual(preferences.timerSeconds, 7200)
        XCTAssertTrue(preferences.batteryLimitEnabled)
        XCTAssertEqual(preferences.batteryLimitPercent, 20)
        XCTAssertTrue(preferences.thermalProtectionEnabled)
        XCTAssertFalse(preferences.chargingOnlyEnabled)
        XCTAssertEqual(
            preferences.helperSettings,
            SafetySettings(timerSeconds: 0, batteryLimitPercent: 20, thermalProtection: true)
        )
    }

    func testPreferencesUseTheirKeys() {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: "timerEnabled")
        defaults.set(5400, forKey: "timerSeconds")
        defaults.set(false, forKey: "batteryLimitEnabled")
        defaults.set(15, forKey: "batteryLimitPercent")
        defaults.set(false, forKey: "thermalProtectionEnabled")
        defaults.set(true, forKey: "chargingOnlyEnabled")

        let loaded = SafetyPreferences(defaults: defaults)
        XCTAssertEqual(
            loaded.helperSettings,
            SafetySettings(timerSeconds: 5400, batteryLimitPercent: 0, thermalProtection: false, chargingOnly: true)
        )

        loaded.batteryLimitPercent = 40
        XCTAssertEqual(defaults.integer(forKey: "batteryLimitPercent"), 40)
        loaded.thermalProtectionEnabled = true
        XCTAssertTrue(defaults.bool(forKey: "thermalProtectionEnabled"))
        loaded.chargingOnlyEnabled = false
        XCTAssertFalse(defaults.bool(forKey: "chargingOnlyEnabled"))
    }

    func testLidClosedSendsSafetySettings() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 3600
        let controller = makeController()

        try await controller.select(.lidClosed)
        await controller.renew()
        XCTAssertEqual(sessions.safety, [
            SafetySettings(timerSeconds: 3600, batteryLimitPercent: 20, thermalProtection: true),
            SafetySettings(timerSeconds: 3600, batteryLimitPercent: 20, thermalProtection: true),
        ])
    }

    func testInactiveTimerSelectionOnlySavesPreferenceAndRejectsInvalidValues() async throws {
        let controller = makeController()
        try await controller.selectTimer(seconds: 1800)
        try await controller.selectTimer(seconds: 0)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertNil(controller.modeStartedAt)
        XCTAssertFalse(preferences.timerEnabled)
        XCTAssertEqual(preferences.timerSeconds, 1800)
        for seconds in [-1, 59, 86401] {
            do { try await controller.selectTimer(seconds: seconds); XCTFail("Invalid timer must fail") } catch {}
        }
        XCTAssertNotNil(controller.message)
        XCTAssertEqual(sessions.calls, [])
        XCTAssertEqual(preferences.timerSeconds, 1800)
    }

    func testExplicitScreenTimerSelectionRestartsEvenSameValueAndInfinitePreservesFinite() async throws {
        preferences.selectTimer(seconds: 7200)
        let controller = makeController()
        try await controller.select(.keepScreenOn)
        time.now += 2000
        try await controller.selectTimer(seconds: 1800)
        XCTAssertEqual(controller.timerRemaining(), 1800)
        time.now += 30
        try await controller.selectTimer(seconds: 1800)
        XCTAssertEqual(controller.timerRemaining(), 1800)
        XCTAssertEqual(controller.modeStartedAt, time.now)
        try await controller.selectTimer(seconds: 0)
        XCTAssertNil(controller.timerRemaining())
        XCTAssertEqual(preferences.timerSeconds, 1800)
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertEqual(sessions.calls, [])
        XCTAssertEqual(log.events, [.modeOn(.keepScreenOn)])
    }

    func testExpiredScreenTimerCannotBeResurrectedBySelection() async throws {
        preferences.selectTimer(seconds: 60)
        let controller = makeController()
        try await controller.select(.keepScreenOn)
        time.now += 60
        try await controller.selectTimer(seconds: 3600)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertEqual(preferences.timerLimit, 3600)
        XCTAssertNil(controller.modeStartedAt)
        XCTAssertEqual(log.events.last, .modeOff(.keepScreenOn, .stopped(.timer, timerSeconds: 60)))
    }

    func testHelperTimerUsesAcknowledgedOriginAndNeverRenewsOrStartsAnotherSession() async throws {
        preferences.selectTimer(seconds: 7200)
        let controller = makeController()
        try await controller.select(.lidClosed)
        time.now += 2000
        sessions.timerResetOrigin = time.now - 3
        try await controller.selectTimer(seconds: 1800)
        XCTAssertEqual(controller.timerRemaining(), 1797)
        XCTAssertEqual(controller.modeStartedAt, sessions.timerResetOrigin)
        time.now += 20
        sessions.timerResetOrigin = time.now
        try await controller.selectTimer(seconds: 1800)
        XCTAssertEqual(controller.timerRemaining(), 1800)
        try await controller.selectTimer(seconds: 0)
        XCTAssertNil(controller.timerRemaining())
        XCTAssertEqual(preferences.timerSeconds, 1800)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(sessions.calls, ["start 120", "reset timer 1800", "reset timer 1800", "reset timer 0"])
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertTrue(activity.isActive)
        XCTAssertEqual(log.events, [.modeOn(.lidClosed)])
    }

    func testNormalAndQuitWinAgainstSuspendedTimerReset() async throws {
        for quitting in [false, true] {
            preferences.selectTimer(seconds: 7200)
            let controller = makeController()
            try await controller.select(.lidClosed)
            var resume: CheckedContinuation<Void, Never>?
            sessions.onTimerReset = { await withCheckedContinuation { resume = $0 } }
            sessions.timerResetOrigin = .greatestFiniteMagnitude
            let resetting = Task { try await controller.selectTimer(seconds: 1800) }
            await settle { resume != nil }
            let stopping = Task {
                if quitting { return await controller.prepareToQuit() }
                try await controller.select(.off)
                return true
            }
            for _ in 0..<3 { await Task.yield() }
            resume?.resume()
            try await resetting.value
            let stopped = try await stopping.value
            XCTAssertTrue(stopped)
            XCTAssertEqual(controller.mode, .off)
            XCTAssertNil(controller.modeStartedAt)
            XCTAssertFalse(controller.isBusy)
            XCTAssertEqual(preferences.timerSeconds, 7200, "A canceled selection must not adopt the late reply")
            XCTAssertFalse(activity.isActive)
            sessions.onTimerReset = nil
        }
    }

    func testQueuedTimerResetAndConcurrentSettingChangeUseAcceptedTimerAndOrigin() async throws {
        preferences.selectTimer(seconds: 7200)
        let controller = makeController()
        try await controller.select(.lidClosed)
        time.now += 20
        var resumeRenewal: CheckedContinuation<Void, Never>?
        var resumeReset: CheckedContinuation<Void, Never>?
        sessions.onRenew = { await withCheckedContinuation { resumeRenewal = $0 } }
        sessions.onTimerReset = { await withCheckedContinuation { resumeReset = $0 } }
        let renewal = Task { await controller.renew() }
        await settle { resumeRenewal != nil }
        let resetting = Task { try await controller.selectTimer(seconds: 1800) }
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"], "Timer selection must wait for the renewal")
        resumeRenewal?.resume()
        await renewal.value
        sessions.onRenew = nil
        await settle { resumeReset != nil }
        XCTAssertNotNil(resumeReset)
        preferences.batteryLimitPercent = 30
        sessions.timerResetOrigin = time.now - 2
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "reset timer 1800"])
        resumeReset?.resume()
        try await resetting.value
        await settle { sessions.calls.count == 4 && !controller.isBusy }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "reset timer 1800", "renew 120"])
        XCTAssertEqual(sessions.safety.last?.timerSeconds, 1800)
        XCTAssertEqual(sessions.safety.last?.batteryLimitPercent, 30)
        XCTAssertEqual(controller.modeStartedAt, sessions.timerResetOrigin)
        XCTAssertEqual(controller.timerRemaining(), 1798)
        XCTAssertEqual(controller.mode, .lidClosed)
    }

    func testInvalidHelperTimerOriginsRecoverWithoutAdoptingOrStartingAnotherSession() async throws {
        preferences.selectTimer(seconds: 7200)
        let controller = makeController()
        for origin in [time.now + 1, Double.greatestFiniteMagnitude, .infinity, .nan, -1] {
            let callCount = sessions.calls.count
            try await controller.select(.lidClosed)
            sessions.timerResetOrigin = origin
            let restores = brightness.restores
            do { try await controller.selectTimer(seconds: 1800); XCTFail("Invalid timer origin must fail: \(origin)") } catch {}
            XCTAssertEqual(controller.mode, .off)
            XCTAssertNil(controller.modeStartedAt)
            XCTAssertGreaterThan(brightness.restores, restores)
            XCTAssertEqual(preferences.timerSeconds, 7200)
            XCTAssertNotNil(controller.message)
            XCTAssertFalse(activity.isActive)
            XCTAssertEqual(Array(sessions.calls.dropFirst(callCount)), ["start 120", "reset timer 1800", "end"])
        }
    }

    func testTimerResetFailureRecoversWithoutStartingAndKeepsPreviousPreference() async throws {
        preferences.selectTimer(seconds: 7200)
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.timerResetError = HelperError.timeout
        sessions.endError = HelperError.helper(.powerModeFailed, "Power recovery pending")
        let restores = brightness.restores
        do { try await controller.selectTimer(seconds: 1800); XCTFail("Reset must fail") } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertGreaterThan(brightness.restores, restores)
        XCTAssertEqual(preferences.timerSeconds, 7200)
        XCTAssertNotNil(controller.message)
        XCTAssertEqual(sessions.calls, ["start 120", "reset timer 1800", "end"])
        XCTAssertFalse(activity.isActive)
        XCTAssertTrue(preferences.helperRecoveryPending)
        guard case .failed(let detail) = controller.message else {
            XCTFail("Both reset failure and recovery warning must remain visible")
            return
        }
        XCTAssertTrue(detail.contains(HelperError.timeout.localizedDescription))
        XCTAssertTrue(detail.contains("Power recovery pending"))
    }

    func testExpiredHelperResetReportsExistingStopReasonWithoutStarting() async throws {
        preferences.selectTimer(seconds: 60)
        let controller = makeController()
        try await controller.select(.lidClosed)
        sessions.timerResetError = HelperError.helper(.noSession, "Expired")
        sessions.stopRecord = StopRecord(reason: .timer, time: Date())
        do { try await controller.selectTimer(seconds: 1800); XCTFail("Expired session must fail") } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(log.events.last, .modeOff(.lidClosed, .stopped(.timer, timerSeconds: 60)))
        XCTAssertEqual(preferences.timerSeconds, 60)
        XCTAssertEqual(sessions.calls.filter { $0.hasPrefix("start") }, ["start 120"])
        XCTAssertNotNil(controller.message)
    }

    func testKeepScreenOnTimerTurnsOff() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 3600
        let controller = makeController()
        try await controller.select(.keepScreenOn)
        XCTAssertEqual(controller.timerRemaining(), 3600)

        time.now += 3599
        await controller.checkTimer()
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertEqual(controller.timerRemaining(), 1)

        time.now += 1
        await controller.checkTimer()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(assertion.isHeld)
        XCTAssertNil(controller.timerRemaining())
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The timer ran out."])
        XCTAssertEqual(controller.message, .turnedOff("The timer ran out."))
        XCTAssertEqual(sessions.calls, [])
    }

    func testKeepScreenOnIgnoresBatteryLimit() async throws {
        preferences.batteryLimitPercent = 50
        let controller = makeController()
        try await controller.select(.keepScreenOn)

        time.now += 100_000
        await controller.checkTimer()
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertNil(controller.timerRemaining())
        XCTAssertEqual(sessions.calls, [])
    }

    func testKeepScreenOnTimerChangeCountsFromStart() async throws {
        preferences.timerEnabled = true
        let controller = makeController()
        try await controller.select(.keepScreenOn)

        time.now += 2000
        preferences.timerSeconds = 1800
        await settle { controller.mode == .off }
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The timer ran out."])
    }

    func testSettingChangeSendsRenewal() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        preferences.batteryLimitPercent = 30
        await settle { sessions.calls.count >= 2 }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])
        XCTAssertEqual(
            sessions.safety.last,
            SafetySettings(timerSeconds: 0, batteryLimitPercent: 30, thermalProtection: true)
        )

        preferences.timerEnabled = true
        await settle { sessions.calls.count >= 3 }
        XCTAssertEqual(
            sessions.safety.last,
            SafetySettings(timerSeconds: 7200, batteryLimitPercent: 30, thermalProtection: true)
        )
    }

    func testWatchedAppsChangeSendsRenewal() async throws {
        preferences.idleSleepEnabled = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(sessions.safety.last?.watchedAppPaths, [])

        preferences.watchedAppPaths = ["/Applications/Editor.app"]
        await settle { sessions.calls.count >= 2 }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])
        XCTAssertEqual(sessions.safety.last?.watchedAppPaths, ["/Applications/Editor.app"])
        XCTAssertEqual(controller.mode, .lidClosed)
    }

    func testThermalSettingChangeSendsRenewal() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        preferences.thermalProtectionEnabled = false
        await settle { sessions.calls.count >= 2 }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])
        XCTAssertEqual(
            sessions.safety.last,
            SafetySettings(timerSeconds: 0, batteryLimitPercent: 20, thermalProtection: false)
        )

        preferences.thermalProtectionEnabled = true
        await settle { sessions.calls.count >= 3 }
        XCTAssertEqual(sessions.safety.last?.thermalProtection, true)
        XCTAssertEqual(controller.mode, .lidClosed)
    }

    func testSettingChangeWhileOffSendsNothing() async {
        _ = makeController()
        preferences.batteryLimitPercent = 30
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(sessions.calls, [])
    }

    func testNoSessionTurnsOffWithNotification() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.stopRecord = StopRecord(reason: .battery, time: Date(), batteryPercent: 15)
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "end", "reason", "clear reason"])
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The battery dropped to 15%."])
        XCTAssertEqual(controller.message, .turnedOff("The battery dropped to 15%."))
        XCTAssertNil(sessions.stopRecord)
    }

    func testNoSessionAfterThermalStopTurnsOffWithNotification() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.stopRecord = StopRecord(reason: .thermal, time: Date())
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "end", "reason", "clear reason"])
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The Mac got too hot."])
        XCTAssertEqual(controller.message, .turnedOff("The Mac got too hot."))
    }

    func testNoSessionAfterUnreadableThermalStateNotifies() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.stopRecord = StopRecord(reason: .thermalUnreadable, time: Date())
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The thermal state could not be read."])
    }

    func testThermalRefusalShowsError() async {
        sessions.startError = HelperError.helper(.thermalLimitReached, "The Mac is too hot (thermal state serious).")
        let controller = makeController()

        do {
            try await controller.select(.lidClosed)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(activity.isActive)
        XCTAssertEqual(controller.message, .couldNotTurnOn("The Mac got too hot."))
        XCTAssertEqual(notifier.posts, [])
    }

    func testLidClosedTimerAsksHelperEarly() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 1800
        let controller = makeController()
        try await controller.select(.lidClosed)

        time.now += 1799
        await controller.checkTimer()
        XCTAssertEqual(sessions.calls, ["start 120"])

        time.now += 1
        sessions.stopRecord = StopRecord(reason: .timer, time: Date())
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.checkTimer()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The timer ran out."])
    }

    func testBatteryRefusalShowsError() async {
        sessions.startError = HelperError.helper(.batteryLimitReached, "The battery is at 12%, at or below the 20% limit.")
        let controller = makeController()

        do {
            try await controller.select(.lidClosed)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(controller.message, .couldNotTurnOn("The battery is at 12%, at or below the 20% limit."))
        XCTAssertEqual(notifier.posts, [])
    }

    func testLaunchReportsUnclearedReason() async {
        sessions.stopRecord = StopRecord(reason: .leaseExpired, time: Date())
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["clear", "reason", "clear reason"])
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: MacStayAwake closed unexpectedly, so normal sleep was restored."])
        XCTAssertNil(sessions.stopRecord)
    }

    func testLaunchWithoutReasonStaysQuiet() async {
        let controller = makeController()
        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["clear", "reason"])
        XCTAssertEqual(notifier.posts, [])
        XCTAssertNil(controller.message)
    }

    func testLaunchShowsUnclearedReasonInWindow() async {
        sessions.stopRecord = StopRecord(reason: .timer, time: Date())
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(controller.message, .turnedOff("The timer ran out."))
    }

    func testDismissMessageClearsReason() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 1800
        let controller = makeController()
        try await controller.select(.keepScreenOn)
        time.now += 1800
        await controller.checkTimer()
        XCTAssertEqual(controller.message, .turnedOff("The timer ran out."))

        controller.dismissMessage()
        XCTAssertNil(controller.message)
    }

    func testChoosingModeClearsOldReason() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 1800
        let controller = makeController()
        try await controller.select(.keepScreenOn)
        time.now += 1800
        await controller.checkTimer()
        XCTAssertNotNil(controller.message)

        try await controller.select(.keepScreenOn)
        XCTAssertNil(controller.message)
    }

    func testAuthorizationRequestedOnFirstMode() async throws {
        let controller = makeController()
        try await controller.select(.off)
        XCTAssertEqual(notifier.authorizationRequests, 0)

        try await controller.select(.keepScreenOn)
        try await controller.select(.lidClosed)
        try await controller.select(.off)
        try await controller.select(.keepScreenOn)
        XCTAssertEqual(notifier.authorizationRequests, 1)
    }

    func testNoticeTexts() {
        let time = Date()
        XCTAssertEqual(StopNotice.title, "MacStayAwake turned off")
        XCTAssertEqual(StopNotice.body(for: StopRecord(reason: .timer, time: time)), "The timer ran out.")
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .battery, time: time, batteryPercent: 9)),
            "The battery dropped to 9%."
        )
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .batteryUnreadable, time: time)),
            "The battery level could not be read."
        )
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .leaseExpired, time: time)),
            "MacStayAwake closed unexpectedly, so normal sleep was restored."
        )
        XCTAssertEqual(StopNotice.body(for: StopRecord(reason: .thermal, time: time)), "The Mac got too hot.")
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .thermalUnreadable, time: time)),
            "The thermal state could not be read."
        )
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .powerUnreadable, time: time)),
            "The power source could not be read."
        )
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .idle, time: time, idleMinutes: 20)),
            "Nothing was working for 20 minutes."
        )
        XCTAssertEqual(
            StopNotice.body(for: StopRecord(reason: .idle, time: time)),
            "Nothing was working for a while."
        )
        XCTAssertEqual(PauseNotice.title, "MacStayAwake paused")
        XCTAssertEqual(PauseNotice.body, "Running on battery. It resumes when you plug in.")
    }

    // MARK: Charging only

    private let pausedNotice = "MacStayAwake paused: Running on battery. It resumes when you plug in."

    func testPowerSourceChangeSendsRenewalThenAsksForStatus() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(sessions.statusRequests, [1])

        powerMonitor.change()
        await settle { sessions.statusRequests.count >= 2 }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])
        XCTAssertEqual(sessions.statusRequests, [1, 2])
        XCTAssertEqual(controller.mode, .lidClosed)
    }

    func testPowerSourceChangeOutsideLidClosedSendsNothing() async throws {
        let controller = makeController()
        powerMonitor.change()
        try await controller.select(.keepScreenOn)
        powerMonitor.change()
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(sessions.calls, [])
        XCTAssertEqual(sessions.statusRequests, [])
    }

    func testPauseNotifiesOnce() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(notifier.posts, [])

        sessions.paused = true
        powerMonitor.change()
        await settle { controller.isPaused }
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertEqual(notifier.posts, [pausedNotice])

        await controller.renew()
        powerMonitor.change()
        await settle { sessions.statusRequests.count >= 4 }
        XCTAssertEqual(sessions.statusRequests.count, 4)
        XCTAssertEqual(notifier.posts, [pausedNotice])
    }

    func testResumeIsSilent() async throws {
        sessions.paused = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertTrue(controller.isPaused)
        XCTAssertEqual(notifier.posts, [pausedNotice])

        sessions.paused = false
        powerMonitor.change()
        await settle { !controller.isPaused }
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertEqual(notifier.posts, [pausedNotice])
        XCTAssertNil(controller.message)
    }

    func testLeavingModeClearsPause() async throws {
        sessions.paused = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertTrue(controller.isPaused)

        try await controller.select(.off)
        XCTAssertFalse(controller.isPaused)
    }

    func testChargingOnlySettingChangeSendsRenewal() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(sessions.safety.last?.chargingOnly, false)
        XCTAssertEqual(sessions.safety.last?.batteryLimitPercent, 20)

        preferences.chargingOnlyEnabled = true
        await settle { sessions.calls.count >= 2 }
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])
        XCTAssertEqual(
            sessions.safety.last,
            SafetySettings(timerSeconds: 0, batteryLimitPercent: 0, thermalProtection: true, chargingOnly: true)
        )
        await settle { sessions.statusRequests.count >= 2 }
        XCTAssertEqual(sessions.statusRequests, [1, 2])
    }

    func testPowerSourceRefusalShowsError() async {
        sessions.startError = HelperError.helper(.powerUnreadable, "The power source could not be read.")
        let controller = makeController()

        do {
            try await controller.select(.lidClosed)
            XCTFail("expected an error")
        } catch {}
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(controller.message, .couldNotTurnOn("The power source could not be read."))
        XCTAssertEqual(notifier.posts, [])
    }

    func testNoSessionAfterUnreadablePowerSourceNotifies() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.stopRecord = StopRecord(reason: .powerUnreadable, time: Date())
        sessions.renewError = HelperError.helper(.noSession, "The power source could not be read.")
        await controller.renew()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(notifier.posts, ["MacStayAwake turned off: The power source could not be read."])
    }

    func testStoredLockSettingSendsNoRenewal() async throws {
        XCTAssertTrue(preferences.lockOnLidCloseEnabled)
        let controller = makeController()
        try await controller.select(.lidClosed)

        preferences.lockOnLidCloseEnabled = false
        XCTAssertFalse(UserDefaults(suiteName: suiteName)!.bool(forKey: "lockOnLidCloseEnabled"))
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertEqual(sessions.calls, ["start 120"])
    }

    func testLidCloseLocksInLidClosed() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        lidMonitor.change(closed: true)
        XCTAssertEqual(locker.lockCount, 1)
        XCTAssertEqual(controller.mode, .lidClosed)
    }

    func testLidCloseWithSettingOffDoesNotLock() async throws {
        preferences.lockOnLidCloseEnabled = false
        let controller = makeController()
        try await controller.select(.lidClosed)

        lidMonitor.change(closed: true)
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testLidCloseOutsideLidClosedDoesNotLock() async throws {
        let controller = makeController()
        lidMonitor.change(closed: true)
        lidMonitor.change(closed: false)

        try await controller.select(.keepScreenOn)
        lidMonitor.change(closed: true)
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testLidCloseLocksWhilePaused() async throws {
        sessions.paused = true
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertTrue(controller.isPaused)

        lidMonitor.change(closed: true)
        XCTAssertEqual(locker.lockCount, 1)
    }

    func testLidOpenDoesNotLock() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        lidMonitor.change(closed: false)
        XCTAssertEqual(locker.lockCount, 0)
    }

    func testUnavailableLockShowsNotice() async throws {
        locker.isAvailable = false
        let controller = makeController()
        XCTAssertEqual(controller.screenLockNotice, "Screen lock is not available on this macOS version.")

        try await controller.select(.lidClosed)
        lidMonitor.change(closed: true)
        XCTAssertEqual(locker.lockCount, 0)
        XCTAssertEqual(controller.mode, .lidClosed)

        preferences.lockOnLidCloseEnabled = false
        XCTAssertNil(controller.screenLockNotice)
    }

    func testAvailableLockShowsNoNotice() {
        let controller = makeController()
        XCTAssertNil(controller.screenLockNotice)
    }

    // MARK: Activity log

    func testLogKeepScreenOnTurnedOnAndOff() async throws {
        let controller = makeController()

        try await controller.select(.keepScreenOn)
        try await controller.select(.off)
        XCTAssertEqual(log.events, [.modeOn(.keepScreenOn), .modeOff(.keepScreenOn, .user)])
        XCTAssertTrue(log.records.allSatisfy { $0.time == nil })
    }

    func testLogLidClosedTurnedOnAndOff() async throws {
        let controller = makeController()

        try await controller.select(.lidClosed)
        try await controller.select(.off)
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .modeOff(.lidClosed, .user)])
    }

    func testLogOffWhileOffWritesNothing() async throws {
        let controller = makeController()

        try await controller.select(.off)
        await controller.checkTimer()
        XCTAssertEqual(log.events, [])
    }

    func testLogSwitchingModesWritesOffThenOn() async throws {
        let controller = makeController()
        try await controller.select(.keepScreenOn)

        try await controller.select(.lidClosed)
        XCTAssertEqual(log.events, [.modeOn(.keepScreenOn), .modeOff(.keepScreenOn, .user), .modeOn(.lidClosed)])

        try await controller.select(.keepScreenOn)
        XCTAssertEqual(Array(log.events.dropFirst(3)), [.modeOff(.lidClosed, .user), .modeOn(.keepScreenOn)])
    }

    func testLogFailedTurnOnWritesNothing() async throws {
        assertion.shouldFail = true
        helper.notReady = .notReady("Install the helper to run with the lid closed.")
        let controller = makeController()

        try? await controller.select(.keepScreenOn)
        try? await controller.select(.lidClosed)
        XCTAssertEqual(log.events, [])

        assertion.shouldFail = false
        helper.notReady = nil
        sessions.startError = HelperError.timeout
        try await controller.select(.keepScreenOn)
        try? await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertEqual(log.events, [.modeOn(.keepScreenOn)])
    }

    func testLogEveryHelperStopWithItsTimeAndNumbers() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 14400
        let stops: [StopRecord] = [
            StopRecord(reason: .timer, time: Date(timeIntervalSince1970: 1_800_000_001)),
            StopRecord(reason: .battery, time: Date(timeIntervalSince1970: 1_800_000_002), batteryPercent: 15),
            StopRecord(reason: .batteryUnreadable, time: Date(timeIntervalSince1970: 1_800_000_003)),
            StopRecord(reason: .thermal, time: Date(timeIntervalSince1970: 1_800_000_004)),
            StopRecord(reason: .thermalUnreadable, time: Date(timeIntervalSince1970: 1_800_000_005)),
            StopRecord(reason: .powerUnreadable, time: Date(timeIntervalSince1970: 1_800_000_006)),
            StopRecord(reason: .leaseExpired, time: Date(timeIntervalSince1970: 1_800_000_007)),
            StopRecord(reason: .idle, time: Date(timeIntervalSince1970: 1_800_000_008), idleMinutes: 20),
        ]
        let controller = makeController()

        for stop in stops {
            sessions.renewError = nil
            try await controller.select(.lidClosed)
            sessions.stopRecord = stop
            sessions.renewError = HelperError.helper(.noSession, "No active session.")
            await controller.renew()

            XCTAssertEqual(controller.mode, .off)
            let last = log.records.last
            XCTAssertEqual(last?.event, .modeOff(.lidClosed, .stopped(
                stop.reason,
                batteryPercent: stop.batteryPercent,
                idleMinutes: stop.idleMinutes,
                timerSeconds: stop.reason == .timer ? 14400 : nil
            )))
            XCTAssertEqual(last?.time, stop.time)
        }
        XCTAssertEqual(log.records.count, stops.count * 2)
    }

    func testLogKeepScreenOnTimerWithItsLength() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 3600
        let controller = makeController()
        try await controller.select(.keepScreenOn)

        time.now += 3600
        await controller.checkTimer()
        XCTAssertEqual(log.events, [
            .modeOn(.keepScreenOn),
            .modeOff(.keepScreenOn, .stopped(.timer, timerSeconds: 3600)),
        ])
        XCTAssertNotNil(log.records.last?.time)
    }

    func testLogRenewalErrorWithoutReason() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.renewError = HelperError.timeout
        await controller.renew()
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .modeOff(.lidClosed, .error(HelperError.timeout.localizedDescription))])

        sessions.renewError = nil
        try await controller.select(.lidClosed)
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        XCTAssertEqual(log.events.last, .modeOff(.lidClosed, .error("No active session.")))
        XCTAssertEqual(log.events.count, 4)
    }

    func testLogSessionOfEarlierRunAtLaunch() async {
        sessions.session = .ours
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(log.events, [.modeOff(.lidClosed, .previousSession)])
    }

    func testLogReasonFoundAtLaunchWithItsTime() async {
        let stopped = Date(timeIntervalSince1970: 1_800_000_000)
        sessions.session = .ours
        sessions.stopRecord = StopRecord(reason: .idle, time: stopped, idleMinutes: 20)
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(log.events, [.modeOff(.lidClosed, .stopped(.idle, idleMinutes: 20))])
        XCTAssertEqual(log.records.first?.time, stopped)
    }

    func testLogQuietLaunchWritesNothing() async {
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(log.events, [])
    }

    func testLogOneStopIsOneEntry() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.stopRecord = StopRecord(reason: .thermal, time: Date())
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        await controller.renew()
        await controller.clearLeftover()
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .modeOff(.lidClosed, .stopped(.thermal))])
    }

    func testLogPauseAndResume() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)

        sessions.paused = true
        powerMonitor.change()
        await settle { controller.isPaused }
        await controller.renew()
        sessions.paused = false
        powerMonitor.change()
        await settle { !controller.isPaused }
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .paused, .resumed])
    }

    func testLogLeavingModeWhilePausedIsNoResume() async throws {
        sessions.paused = true
        let controller = makeController()
        try await controller.select(.lidClosed)

        try await controller.select(.off)
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .paused, .modeOff(.lidClosed, .user)])

        try await controller.select(.lidClosed)
        sessions.renewError = HelperError.timeout
        await controller.renew()
        XCTAssertFalse(log.events.dropFirst(3).contains(.resumed))
    }

    // MARK: Idle events

    private let eventTime = Date(timeIntervalSince1970: 1_800_000_000)

    func testIdleEventsAreRecordedWithTheirOwnTime() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        idleEvents.pending = [
            IdleEvent(time: eventTime, cause: .app("Example")),
            IdleEvent(time: eventTime + 60, cause: .load(busiest: "example-tool")),
            IdleEvent(time: eventTime + 120, cause: .load(busiest: nil)),
            IdleEvent(time: eventTime + 180, cause: .input),
            IdleEvent(time: eventTime + 240, cause: .idle(minutes: 20)),
        ]

        await controller.renew()
        XCTAssertEqual(log.events, [
            .modeOn(.lidClosed),
            .keptAwakeByApp("Example"),
            .keptAwakeByLoad(busiest: "example-tool"),
            .keptAwakeByLoad(busiest: nil),
            .keptAwakeByInput,
            .idleStarted(minutes: 20),
        ])
        XCTAssertEqual(log.records.dropFirst().map(\.time), [
            eventTime, eventTime + 60, eventTime + 120, eventTime + 180, eventTime + 240,
        ])
    }

    func testIdleEventsAreTakenAfterEachRenewal() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(idleEvents.requests, [])

        await controller.renew()
        await controller.renew()
        XCTAssertEqual(idleEvents.requests, [["start 120", "renew 120"], ["start 120", "renew 120", "renew 120"]])
    }

    func testIdleEventsAreTakenBeforeTheUserEndsTheSession() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        idleEvents.pending = [IdleEvent(time: eventTime, cause: .idle(minutes: 20))]

        try await controller.select(.off)
        XCTAssertEqual(idleEvents.requests, [["start 120"]])
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .idleStarted(minutes: 20), .modeOff(.lidClosed, .user)])

        try await controller.select(.lidClosed)
        try await controller.select(.keepScreenOn)
        XCTAssertEqual(idleEvents.requests.count, 2)
        XCTAssertEqual(idleEvents.requests.last?.last, "start 120")

        // Leaving another mode has no session to take events from.
        try await controller.select(.off)
        XCTAssertEqual(idleEvents.requests.count, 2)
    }

    func testIdleEventsAreTakenWhenTheHelperStoppedTheSession() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        idleEvents.pending = [IdleEvent(time: eventTime, cause: .idle(minutes: 20))]

        sessions.stopRecord = StopRecord(reason: .idle, time: eventTime + 1200, idleMinutes: 20)
        sessions.renewError = HelperError.helper(.noSession, "No active session.")
        await controller.renew()
        XCTAssertEqual(idleEvents.requests, [["start 120", "renew 120", "end"]])
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "end", "reason", "clear reason"])
        XCTAssertEqual(log.events, [
            .modeOn(.lidClosed),
            .idleStarted(minutes: 20),
            .modeOff(.lidClosed, .stopped(.idle, idleMinutes: 20)),
        ])
    }

    func testIdleEventsAreTakenAtLaunchWithTheReasonOfTheLastRun() async {
        sessions.session = .ours
        sessions.stopRecord = StopRecord(reason: .idle, time: eventTime + 600, idleMinutes: 10)
        idleEvents.pending = [IdleEvent(time: eventTime, cause: .idle(minutes: 10))]
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(idleEvents.requests, [["end"]])
        XCTAssertEqual(log.events, [.idleStarted(minutes: 10), .modeOff(.lidClosed, .stopped(.idle, idleMinutes: 10))])
    }

    func testAFailedIdleEventCallChangesNothing() async throws {
        idleEvents.error = HelperError.timeout
        let controller = makeController()
        try await controller.select(.lidClosed)

        await controller.renew()
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertNil(controller.message)
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120"])

        sessions.paused = true
        await controller.renew()
        XCTAssertTrue(controller.isPaused)

        try await controller.select(.off)
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "renew 120", "end"])
        XCTAssertNil(controller.message)
        XCTAssertEqual(log.events, [.modeOn(.lidClosed), .paused, .modeOff(.lidClosed, .user)])

        await controller.clearLeftover()
        XCTAssertNil(controller.message)
        XCTAssertEqual(idleEvents.requests.count, 4)
    }

    // MARK: Sleep when idle lasts one session

    private let noSession = HelperError.helper(.noSession, "No active session.")

    private func turnOnIdleSleep(minutes: Int = 30) {
        preferences.idleSleepEnabled = true
        preferences.idleSleepMinutes = minutes
    }

    private func assertIdleSleepEnded(minutes: Int = 30, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(preferences.idleSleepEnabled, file: file, line: line)
        XCTAssertEqual(preferences.idleSleepMinutes, minutes, file: file, line: line)
    }

    private func assertIdleSleepKept(minutes: Int = 30, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(preferences.idleSleepEnabled, file: file, line: line)
        XCTAssertEqual(preferences.idleSleepMinutes, minutes, file: file, line: line)
    }

    func testIdleSleepEndsWhenTheUserTurnsTheModeOff() async throws {
        let controller = makeController()
        turnOnIdleSleep()
        try await controller.select(.lidClosed)

        try await controller.select(.off)
        assertIdleSleepEnded()
    }

    func testIdleSleepEndsWhenTheUserSwitchesToKeepScreenOn() async throws {
        let controller = makeController()
        turnOnIdleSleep()
        try await controller.select(.lidClosed)

        try await controller.select(.keepScreenOn)
        XCTAssertEqual(controller.mode, .keepScreenOn)
        assertIdleSleepEnded()
    }

    func testIdleSleepEndsOnEveryHelperStop() async throws {
        let reasons: [StopReason] = [
            .idle, .timer, .battery, .batteryUnreadable, .thermal, .thermalUnreadable, .powerUnreadable, .leaseExpired,
        ]
        let controller = makeController()

        for reason in reasons {
            turnOnIdleSleep()
            sessions.renewError = nil
            try await controller.select(.lidClosed)
            sessions.stopRecord = StopRecord(reason: reason, time: Date())
            sessions.renewError = noSession
            await controller.renew()

            XCTAssertEqual(controller.mode, .off, "\(reason)")
            assertIdleSleepEnded()
        }
    }

    func testIdleSleepEndsWhenTheLidClosedTimerRunsOut() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 3600
        turnOnIdleSleep()
        let controller = makeController()
        try await controller.select(.lidClosed)

        time.now += 3600
        sessions.stopRecord = StopRecord(reason: .timer, time: Date())
        sessions.renewError = noSession
        await controller.checkTimer()
        XCTAssertEqual(controller.mode, .off)
        assertIdleSleepEnded()
    }

    func testIdleSleepEndsWhenRenewalFails() async throws {
        let controller = makeController()
        turnOnIdleSleep()
        try await controller.select(.lidClosed)
        sessions.renewError = HelperError.timeout
        await controller.renew()
        XCTAssertEqual(controller.message, .turnedOffWithError(HelperError.timeout.localizedDescription))
        assertIdleSleepEnded()

        turnOnIdleSleep()
        sessions.renewError = nil
        try await controller.select(.lidClosed)
        sessions.renewError = noSession
        await controller.renew()
        XCTAssertEqual(controller.message, .turnedOffWithError("No active session."))
        assertIdleSleepEnded()
    }

    func testIdleSleepEndsWithTheSessionOfAnEarlierRun() async {
        sessions.session = .ours
        turnOnIdleSleep()
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(controller.message, .restarted)
        assertIdleSleepEnded()
    }

    func testIdleSleepEndsWithAReasonFoundAtLaunch() async {
        sessions.stopRecord = StopRecord(reason: .idle, time: Date(), idleMinutes: 30)
        turnOnIdleSleep()
        let controller = makeController()

        await controller.clearLeftover()
        XCTAssertEqual(sessions.calls, ["clear", "reason", "clear reason"])
        assertIdleSleepEnded()

        sessions.session = .ours
        sessions.stopRecord = StopRecord(reason: .leaseExpired, time: Date())
        turnOnIdleSleep()
        await controller.clearLeftover()
        assertIdleSleepEnded()
    }

    func testIdleSleepStaysThroughPauseAndResume() async throws {
        let controller = makeController()
        turnOnIdleSleep()
        try await controller.select(.lidClosed)

        sessions.paused = true
        await controller.renew()
        XCTAssertTrue(controller.isPaused)
        sessions.paused = false
        await controller.renew()
        XCTAssertFalse(controller.isPaused)
        XCTAssertEqual(controller.mode, .lidClosed)
        assertIdleSleepKept()
    }

    func testIdleSleepStaysWhenKeepScreenOnEnds() async throws {
        preferences.timerEnabled = true
        preferences.timerSeconds = 3600
        turnOnIdleSleep()
        let controller = makeController()

        try await controller.select(.keepScreenOn)
        try await controller.select(.off)
        assertIdleSleepKept()

        try await controller.select(.keepScreenOn)
        time.now += 3600
        await controller.checkTimer()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertEqual(controller.message, .turnedOff("The timer ran out."))
        assertIdleSleepKept()
    }

    func testIdleSleepStaysWhenTurningOnFails() async throws {
        turnOnIdleSleep()
        helper.notReady = .notReady("Install the helper to run with the lid closed.")
        let controller = makeController()
        try? await controller.select(.lidClosed)
        assertIdleSleepKept()

        helper.notReady = nil
        sessions.startError = HelperError.timeout
        try? await controller.select(.lidClosed)
        try await controller.select(.keepScreenOn)
        try? await controller.select(.lidClosed)
        XCTAssertEqual(controller.mode, .keepScreenOn)
        assertIdleSleepKept()
    }

    func testIdleSleepStaysOnQuietLaunch() async {
        turnOnIdleSleep()
        let controller = makeController()
        await controller.clearLeftover()
        assertIdleSleepKept()

        sessions.statusError = HelperError.timeout
        await controller.clearLeftover()
        assertIdleSleepKept()

        helper.notReady = .notReady("Install the helper to run with the lid closed.")
        await controller.clearLeftover()
        assertIdleSleepKept()
    }

    func testIdleSleepTurnedOnWhileOffLastsUntilTheNextSessionEnds() async throws {
        let controller = makeController()
        turnOnIdleSleep()
        await settle(until: { false })
        XCTAssertEqual(sessions.calls, [])

        try await controller.select(.lidClosed)
        XCTAssertEqual(sessions.safety.last?.idleSleepMinutes, 30)
        await controller.renew()
        XCTAssertEqual(sessions.safety.last?.idleSleepMinutes, 30)
        assertIdleSleepKept()

        try await controller.select(.off)
        assertIdleSleepEnded()

        try await controller.select(.lidClosed)
        XCTAssertEqual(sessions.safety.last?.idleSleepMinutes, 0)
    }

    func testIdleSleepTurnedOnDuringASessionLastsUntilItEnds() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        XCTAssertEqual(sessions.safety.last?.idleSleepMinutes, 0)

        turnOnIdleSleep()
        await settle { sessions.safety.last?.idleSleepMinutes == 30 }
        XCTAssertEqual(sessions.safety.last?.idleSleepMinutes, 30)
        assertIdleSleepKept()

        try await controller.select(.off)
        assertIdleSleepEnded()
    }

    func testIdleSleepEndsOnlyAfterTheSessionHasEnded() async throws {
        let suiteName = self.suiteName
        sessions.probeAtEnd = {
            UserDefaults(suiteName: suiteName)!.bool(forKey: SafetyPreferences.Key.idleSleepEnabled)
        }
        let controller = makeController()
        turnOnIdleSleep()

        try await controller.select(.lidClosed)
        await controller.renew()
        try await controller.select(.off)
        await settle(until: { false })
        XCTAssertEqual(sessions.calls, ["start 120", "renew 120", "end"])
        XCTAssertEqual(sessions.safety.map(\.idleSleepMinutes), [30, 30])
        XCTAssertEqual(sessions.probedAtEnd, [true])
        assertIdleSleepEnded()

        turnOnIdleSleep()
        try await controller.select(.lidClosed)
        sessions.stopRecord = StopRecord(reason: .idle, time: Date(), idleMinutes: 30)
        sessions.renewError = noSession
        await controller.renew()
        await settle(until: { false })
        XCTAssertEqual(Array(sessions.calls.dropFirst(3)), ["start 120", "renew 120", "end", "reason", "clear reason"])
        XCTAssertEqual(sessions.safety.map(\.idleSleepMinutes), [30, 30, 30, 30])
        XCTAssertEqual(sessions.probedAtEnd, [true, true])
        assertIdleSleepEnded()
    }

    func testEndingIdleSleepDoesNotTouchOtherProtections() async throws {
        preferences.timerEnabled = true
        preferences.batteryLimitPercent = 40
        preferences.thermalProtectionEnabled = false
        preferences.chargingOnlyEnabled = true
        turnOnIdleSleep()
        let controller = makeController()
        try await controller.select(.lidClosed)

        try await controller.select(.off)
        assertIdleSleepEnded()
        XCTAssertTrue(preferences.timerEnabled)
        XCTAssertEqual(preferences.batteryLimitPercent, 40)
        XCTAssertFalse(preferences.thermalProtectionEnabled)
        XCTAssertTrue(preferences.chargingOnlyEnabled)
    }

    // MARK: Wake on schedule

    private let wakeSuiteName = "ModeControllerTests-wake-\(UUID().uuidString)"
    private let wakeTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// A scheduler that remembers `wakeTime` with the setting on, for a controller made by the test.
    private func makeScheduler(_ controller: ModeController, wakeService: FakeWakeService) async -> WakeScheduler {
        let wakePreferences = WakePreferences(defaults: UserDefaults(suiteName: wakeSuiteName)!)
        wakePreferences.save(WakeAlarm(minuteOfDay: 480, isEnabled: true))
        wakeService.wakes = [wakeTime]
        let scheduler = WakeScheduler(
            preferences: wakePreferences,
            helper: helper,
            service: wakeService,
            mode: controller,
            log: log,
            clockMonitor: FakeClockMonitor(),
            now: { [wakeTime] in wakeTime.addingTimeInterval(1) }
        )
        await scheduler.sync()
        await settle { wakeService.requests.count >= 2 }
        UserDefaults().removePersistentDomain(forName: wakeSuiteName)
        return scheduler
    }

    func testWakeOnScheduleOnPowerTurnsOnRunWithLidClosedWithSleepWhenIdle() async {
        preferences.idleSleepMinutes = 30
        let controller = makeController()
        let wakeService = FakeWakeService(sessions: sessions)
        let scheduler = await makeScheduler(controller, wakeService: wakeService)
        let requestsBefore = wakeService.requests.count

        scheduler.macDidWake()
        await settle { wakeService.requests.count > requestsBefore }

        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertTrue(preferences.idleSleepEnabled, "Sleep when idle is on for this session")
        XCTAssertEqual(preferences.idleSleepMinutes, 30, "the saved minutes do not change")
        XCTAssertEqual(sessions.safety.first?.idleSleepMinutes, 30, "the session starts with Sleep when idle")
        XCTAssertEqual(helper.prepareCount, 1)
        XCTAssertEqual(log.events.prefix(2), [.scheduledWake, .modeOnBySchedule(.lidClosed)])
        XCTAssertFalse(log.events.contains(.modeOn(.lidClosed)))
        XCTAssertFalse(log.events.contains(.wake))
        let request = wakeService.requests.last!
        XCTAssertEqual(request.minutes, [480])
        XCTAssertEqual(request.sessionCalls.first, "start 120", "the helper is asked after the mode is on")
    }

    func testAfterTheScheduledSessionEndsSleepWhenIdleIsOff() async throws {
        let controller = makeController()
        await controller.turnOnBySchedule()
        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertTrue(preferences.idleSleepEnabled)

        try await controller.select(.off)
        XCTAssertFalse(preferences.idleSleepEnabled)
        XCTAssertEqual(preferences.idleSleepMinutes, 20)
        XCTAssertEqual(log.events, [
            .modeOnBySchedule(.lidClosed),
            .modeOff(.lidClosed, .user),
        ])
    }

    func testScheduledTurnOnDoesNotSendTheSettingTwice() async {
        let controller = makeController()
        await controller.turnOnBySchedule()
        await settle { false }
        XCTAssertEqual(sessions.calls, ["start 120"])
    }

    func testScheduledWakeOnBatteryOrUnknownPowerLeavesTheModeOff() async {
        for source in [PowerSource.battery, .unknown] {
            power.source = source
            let controller = makeController()
            let wakeService = FakeWakeService(sessions: sessions)
            let scheduler = await makeScheduler(controller, wakeService: wakeService)
            let requestsBefore = wakeService.requests.count
            let eventsBefore = log.events.count

            scheduler.macDidWake()
            await settle { wakeService.requests.count > requestsBefore }

            XCTAssertEqual(controller.mode, .off, "\(source)")
            XCTAssertFalse(preferences.idleSleepEnabled, "\(source)")
            XCTAssertEqual(helper.prepareCount, 0, "\(source)")
            XCTAssertEqual(sessions.calls, [], "\(source)")
            XCTAssertEqual(Array(log.events.dropFirst(eventsBefore)), [
                .scheduledWake,
                .modeSkipped(.lidClosed, .notOnPower),
            ], "\(source)")
        }
    }

    func testScheduledTurnOnFailureIsRecordedAndSleepWhenIdleGoesBackOff() async {
        helper.notReady = .notReady("The helper is not ready.")
        let controller = makeController()
        await controller.turnOnBySchedule()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(preferences.idleSleepEnabled)
        XCTAssertEqual(log.events, [.modeSkipped(.lidClosed, .error("The helper is not ready."))])

        helper.notReady = nil
        sessions.startError = HelperError.helper(.flagWriteFailed, "The sleep setting could not be changed.")
        await controller.turnOnBySchedule()
        XCTAssertEqual(controller.mode, .off)
        XCTAssertFalse(preferences.idleSleepEnabled)
        XCTAssertEqual(log.events.last, .modeSkipped(.lidClosed, .error("The sleep setting could not be changed.")))
    }

    func testScheduledTurnOnFailureKeepsSleepWhenIdleThatWasAlreadyOn() async {
        preferences.idleSleepEnabled = true
        helper.notReady = .notReady("The helper is not ready.")
        let controller = makeController()
        await controller.turnOnBySchedule()
        XCTAssertTrue(preferences.idleSleepEnabled)
    }

    func testScheduledWakeLeavesKeepScreenOnAlone() async throws {
        let controller = makeController()
        try await controller.select(.keepScreenOn)
        let wakeService = FakeWakeService(sessions: sessions)
        let scheduler = await makeScheduler(controller, wakeService: wakeService)
        let requestsBefore = wakeService.requests.count
        let eventsBefore = log.events.count

        scheduler.macDidWake()
        await settle { wakeService.requests.count > requestsBefore }

        XCTAssertEqual(controller.mode, .keepScreenOn)
        XCTAssertFalse(preferences.idleSleepEnabled)
        XCTAssertEqual(power.reads, 0)
        XCTAssertEqual(Array(log.events.dropFirst(eventsBefore)), [.scheduledWake])
    }

    func testScheduledWakeLeavesARunningSessionAlone() async throws {
        let controller = makeController()
        try await controller.select(.lidClosed)
        let wakeService = FakeWakeService(sessions: sessions)
        let scheduler = await makeScheduler(controller, wakeService: wakeService)
        let requestsBefore = wakeService.requests.count
        let eventsBefore = log.events.count
        let callsBefore = sessions.calls

        scheduler.macDidWake()
        await settle { wakeService.requests.count > requestsBefore }

        XCTAssertEqual(controller.mode, .lidClosed)
        XCTAssertFalse(preferences.idleSleepEnabled)
        XCTAssertEqual(helper.prepareCount, 1)
        XCTAssertEqual(sessions.calls, callsBefore)
        XCTAssertEqual(Array(log.events.dropFirst(eventsBefore)), [.scheduledWake])
    }
}
