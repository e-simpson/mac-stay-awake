import Foundation
import LidAwakeShared
import XCTest
@testable import LidAwakeCore

@MainActor
final class ClosedLidSettingsTests: XCTestCase {
    private enum Failure: Error { case unavailable }
    private final class Device: ClosedLidDeviceAccess {
        var current: String? = "built-in"
        var values = ["built-in": 0.7]
        var unavailable: Set<String> = []
        var disconnected: Set<String> = []
        var failAfterWrite = false
        var failBeforeWrite = false
        var writes: [(String, Double)] = []
        func currentDevice() -> String? { current }
        func read(_ device: String) throws -> Double {
            if disconnected.contains(device) { throw ClosedLidDeviceError.disconnected }
            guard !unavailable.contains(device), let value = values[device] else { throw Failure.unavailable }
            return value
        }
        func write(_ device: String, value: Double) throws {
            guard !unavailable.contains(device), values[device] != nil else { throw Failure.unavailable }
            if failBeforeWrite { failBeforeWrite = false; throw Failure.unavailable }
            writes.append((device, value))
            values[device] = value
            if failAfterWrite { failAfterWrite = false; throw Failure.unavailable }
        }
    }

    private final class FailingDefaults: UserDefaults {
        var failsToSave = false
        override func synchronize() -> Bool { failsToSave ? false : super.synchronize() }
    }

    private let suite = "ClosedLidSettingsTests-\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: suite)!
    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testDisconnectedOutputIsForgottenWhileConnectedOutputRestores() {
        let device = Device()
        device.values = ["built-in": 0, "headphones": 0]
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        device.disconnected.insert("built-in")
        device.current = "headphones"
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["headphones"], 1)
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["headphones"], 0)
        XCTAssertNil(defaults.object(forKey: "mute"))

        device.disconnected.remove("built-in")
        let writes = device.writes.count
        let relaunched = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(relaunched.update(enabled: false))
        XCTAssertEqual(device.writes.count, writes, "A forgotten device must not be changed after reconnecting")
        XCTAssertEqual(device.values["built-in"], 1)
    }

    func testFailedJournalDeletionKeepsBlockingUntilSaved() {
        let store = FailingDefaults(suiteName: suite)!
        let device = Device()
        let setting = ClosedLidOverride(access: device, defaults: store, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        device.disconnected.insert("built-in")
        store.failsToSave = true
        XCTAssertFalse(setting.update(enabled: false))
        XCTAssertNotNil(store.object(forKey: "mute"))
        XCTAssertFalse(setting.update(enabled: false), "A failed save must not look complete on the next attempt")
        store.failsToSave = false
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertNil(store.object(forKey: "mute"))
    }

    func testCloseRestoresOriginalAfterRelaunchWithoutRepeatingWrites() {
        let device = Device()
        let first = ClosedLidOverride(access: device, defaults: defaults, key: "keyboard", target: 0)
        XCTAssertTrue(first.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 0)
        XCTAssertTrue(first.update(enabled: true))
        XCTAssertEqual(device.writes.count, 1)
        let relaunched = ClosedLidOverride(access: device, defaults: defaults, key: "keyboard", target: 0)
        XCTAssertTrue(relaunched.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0.7)
        XCTAssertNil(defaults.object(forKey: "keyboard"))
    }

    func testExternalChangeIsPreservedUntilNextSession() {
        let device = Device()
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "keyboard", target: 0)
        XCTAssertTrue(setting.update(enabled: true))
        device.values["built-in"] = 0.4
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 0.4)
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 0)
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0.4)
    }

    func testOutputSwitchRestoresOldDeviceAndMutesNewOne() {
        let device = Device()
        device.values = ["built-in": 0, "headphones": 0]
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        device.current = "headphones"
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 0)
        XCTAssertEqual(device.values["headphones"], 1)
        device.current = "built-in"
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 1)
        XCTAssertEqual(device.values["headphones"], 0)
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0)
    }

    func testUnreadableDeviceKeepsRecoveryAndStillMutesNewDevice() {
        let device = Device()
        device.values = ["built-in": 0, "headphones": 0]
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        device.unavailable.insert("built-in")
        device.current = "headphones"
        XCTAssertFalse(setting.update(enabled: true))
        XCTAssertEqual(device.values["headphones"], 1)
        XCTAssertFalse(setting.update(enabled: false))
        XCTAssertEqual(device.values["headphones"], 0)
        device.unavailable.remove("built-in")
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0)
    }

    func testUncertainRestoreThenSwitchBackMutesCurrentOutputAgain() {
        let device = Device()
        device.values = ["built-in": 0, "headphones": 0]
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        device.current = "headphones"
        device.failAfterWrite = true
        XCTAssertFalse(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 0)
        XCTAssertEqual(device.values["headphones"], 1)
        device.current = "built-in"
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 1)
        XCTAssertEqual(device.values["headphones"], 0)
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0)
    }

    func testFailedRestoreThenSwitchBackDoesNotUnmuteCurrentOutput() {
        let device = Device()
        device.values = ["built-in": 0, "headphones": 0]
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        device.current = "headphones"
        device.failBeforeWrite = true
        XCTAssertFalse(setting.update(enabled: true))
        let beforeSwitchBack = device.writes.count
        device.current = "built-in"
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 1)
        XCTAssertFalse(device.writes.dropFirst(beforeSwitchBack).contains { $0.0 == "built-in" })
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0)
    }

    func testUncertainWriteAndCorruptRecoveryNeverLoseOriginal() {
        let device = Device()
        device.failAfterWrite = true
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "keyboard", target: 0)
        XCTAssertFalse(setting.update(enabled: true))
        XCTAssertEqual(device.values["built-in"], 0)
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 0.7)
        defaults.set(Data("invalid".utf8), forKey: "keyboard")
        let writes = device.writes.count
        XCTAssertFalse(setting.update(enabled: false))
        XCTAssertFalse(setting.update(enabled: true))
        XCTAssertEqual(device.writes.count, writes)
    }

    func testAlreadyMutedOutputRemainsMutedAfterRestore() {
        let device = Device()
        device.values["built-in"] = 1
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "mute", target: 1)
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(device.values["built-in"], 1)
        XCTAssertTrue(device.writes.isEmpty)
    }

    func testReportsOnlyObservedApplyAndRestore() {
        let device = Device()
        var events: [(SettingEvent.Operation, SettingEvent.Outcome, Double?, Double?, Double?)] = []
        let setting = ClosedLidOverride(access: device, defaults: defaults, key: "keyboard", target: 0) {
            events.append(($0, $1, $2, $3, $4))
        }
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertTrue(setting.update(enabled: true))
        XCTAssertTrue(setting.update(enabled: false))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].0, .apply)
        XCTAssertEqual(events[0].1, .verified)
        XCTAssertEqual(events[0].2, 0.7)
        XCTAssertEqual(events[0].3, 0)
        XCTAssertEqual(events[1].0, .restore)
        XCTAssertEqual(events[1].1, .verified)
        XCTAssertEqual(events[1].3, 0.7)
    }
}
