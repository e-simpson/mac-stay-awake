import Darwin
import Foundation
import LidAwakeShared
import XCTest
@testable import LidAwakeHelperKit

private func canonicalTemporaryDirectory() throws -> URL {
    let path = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

final class ClosedLidPowerTests: XCTestCase {
    private final class Pmset: CommandRunning {
        var key = "powermode"
        var modes = ["-b": 0, "-c": 2]
        var rawOutput: String?
        var failingWriteScope: String?
        var readFailure = false
        var failReadAfterWrite = false
        var appliesWrites = true
        var beforeWrite: (() -> Void)?
        var beforeRead: (() -> Void)?
        var calls: [(String, [String])] = []

        var writes: [[String]] { calls.map(\.1).filter { $0.first != "-g" } }

        func run(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
            calls.append((path, arguments))
            if arguments == ["-g", "custom"] {
                beforeRead?()
                guard !readFailure else { return CommandResult(status: 8, output: "") }
                return CommandResult(status: 0, output: rawOutput ?? "Battery Power:\n \(key) \(modes["-b"]!)\nAC Power:\n \(key) \(modes["-c"]!)\n")
            }
            beforeWrite?()
            guard arguments.count == 3, arguments[1] == key,
                  let value = Int(arguments[2]), modes[arguments[0]] != nil else {
                return CommandResult(status: 99, output: "")
            }
            guard failingWriteScope != arguments[0] else { return CommandResult(status: 9, output: "") }
            if appliesWrites { modes[arguments[0]] = value }
            if failReadAfterWrite { readFailure = true }
            return CommandResult(status: 0, output: "")
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try canonicalTemporaryDirectory()
            .appendingPathComponent("ClosedLidPowerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testEventsDescribeVerifiedWritesAndEachPartialRestore() throws {
        let pmset = Pmset()
        let time = Date(timeIntervalSince1970: 1234)
        let power = ClosedLidPower(runner: pmset, directory: directory, now: { time })
        try power.update(closed: true, source: .battery)
        try power.update(closed: true, source: .battery)
        try power.update(closed: true, source: .ac)
        let applied = power.takeSettingEvents()
        XCTAssertEqual(applied.map(\.outcome), [.verified, .verified])
        XCTAssertEqual(applied.map(\.source), [.battery, .ac])
        XCTAssertEqual(applied.map(\.prior), [0, 2])
        XCTAssertEqual(applied.map(\.current), [1, 1])
        XCTAssertEqual(applied.map(\.time), [time, time])
        pmset.failingWriteScope = "-b"
        pmset.modes["-c"] = 0
        XCTAssertThrowsError(try power.restore())
        let partial = power.takeSettingEvents()
        XCTAssertEqual(partial.map(\.outcome), [.pending, .externalChangePreserved])
        XCTAssertEqual(partial.map(\.source), [.battery, .ac])
        XCTAssertEqual(partial.last?.current, 0)
        XCTAssertThrowsError(try power.restore())
        XCTAssertTrue(power.takeSettingEvents().isEmpty, "Unchanged pending recovery is not repeated")
        pmset.failingWriteScope = nil
        try power.restore()
        XCTAssertEqual(power.takeSettingEvents().map(\.outcome), [.verified])
    }

    func testIgnoredWritesAreNotVerifiedAndAlreadyLowIsNotOwned() throws {
        let pmset = Pmset()
        pmset.appliesWrites = false
        let power = ClosedLidPower(runner: pmset, directory: directory)
        XCTAssertThrowsError(try power.update(closed: true, source: .battery))
        let failed = power.takeSettingEvents()
        XCTAssertEqual(failed.map(\.outcome), [.failed])
        XCTAssertEqual(failed.first?.current, 0)
        try power.restore()
        XCTAssertEqual(power.takeSettingEvents().map(\.outcome), [.alreadyAtTarget])
        pmset.modes["-b"] = 1
        try power.update(closed: true, source: .battery)
        try power.update(closed: true, source: .battery)
        XCTAssertEqual(power.takeSettingEvents().map(\.outcome), [.alreadyAtTarget])
        XCTAssertFalse(power.hasPendingRestore)
    }

    func testVerifiedWriteSurvivesRecoveryJournalSaveFailureInEvents() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        let journal = directory.appendingPathComponent("closed-lid-power.json")
        pmset.beforeWrite = { try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.path) }
        XCTAssertThrowsError(try power.update(closed: true, source: .battery))
        let events = power.takeSettingEvents()
        XCTAssertEqual(events.map(\.outcome), [.verified, .pending])
        XCTAssertEqual(events.map(\.current), [1, 1])
        XCTAssertEqual(pmset.modes["-b"], 1)
        XCTAssertTrue(power.hasPendingRestore)
    }

    func testObservedTargetAndFailedRecoveryRecordNeverClaimAChangeFailed() throws {
        let pmset = Pmset()
        pmset.failReadAfterWrite = true
        let power = ClosedLidPower(runner: pmset, directory: directory)
        XCTAssertThrowsError(try power.update(closed: true, source: .battery))
        _ = power.takeSettingEvents()
        pmset.readFailure = false
        let journal = directory.appendingPathComponent("closed-lid-power.json")
        // Make the next save fail after the existing unverified record is read and target observed.
        pmset.beforeRead = {
            try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: journal.path)
        }
        XCTAssertThrowsError(try power.update(closed: true, source: .battery))
        XCTAssertEqual(power.takeSettingEvents().map(\.outcome), [.alreadyAtTarget, .pending])
    }

    func testEventQueueKeepsOnlyNewestBoundedObservations() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        for _ in 0..<70 {
            try power.update(closed: true, source: .battery)
            try power.restore()
        }
        let events = power.takeSettingEvents()
        XCTAssertEqual(events.count, SettingEventWire.maximumCount)
        XCTAssertEqual(events.last?.operation, .restore)
        XCTAssertTrue(events.allSatisfy { $0.outcome == .verified })
        XCTAssertTrue(power.takeSettingEvents().isEmpty)
    }

    func testLegacyHighPowerIsRejectedBeforeAnyChanges() throws {
        let pmset = Pmset()
        pmset.rawOutput = "Battery Power:\n lowpowermode 0\n highpowermode 1\n"
        let power = ClosedLidPower(runner: pmset, directory: directory)
        XCTAssertThrowsError(try power.update(closed: true, source: .battery))
        XCTAssertTrue(pmset.writes.isEmpty)
        XCTAssertFalse(power.hasPendingRestore)
    }

    func testModernAndLegacyApplyOnlyCurrentSourceAndRestoreOriginal() throws {
        for key in ["powermode", "lowpowermode"] {
            let pmset = Pmset()
            pmset.key = key
            pmset.modes = ["-b": 0, "-c": 0]
            let power = ClosedLidPower(runner: pmset, directory: directory)
            pmset.beforeWrite = {
                XCTAssertTrue(power.hasPendingRestore, "Original must be durable before the OS write")
            }
            try power.update(closed: true, source: .battery)
            XCTAssertEqual(pmset.modes, ["-b": 1, "-c": 0])
            XCTAssertTrue(power.hasPendingRestore)
            try power.update(closed: false, source: .unknown)
            XCTAssertEqual(pmset.modes, ["-b": 0, "-c": 0])
            XCTAssertFalse(power.hasPendingRestore)
            XCTAssertEqual(pmset.writes, [["-b", key, "1"], ["-b", key, "0"]])
            XCTAssertTrue(pmset.calls.allSatisfy { $0.0 == "/usr/bin/pmset" })
        }
    }

    func testPriorLowRemainsUnownedAndPriorHighRestoresAsHigh() throws {
        for original in [1, 2] {
            let pmset = Pmset()
            pmset.modes["-c"] = original
            let power = ClosedLidPower(runner: pmset, directory: directory)
            try power.update(closed: true, source: .ac)
            XCTAssertEqual(power.hasPendingRestore, original != 1)
            try power.restore()
            XCTAssertEqual(pmset.modes["-c"], original)
            XCTAssertEqual(pmset.writes, original == 1 ? [] : [["-c", "powermode", "1"], ["-c", "powermode", "2"]])
        }
    }

    func testSourceChangesCaptureBothScopesAndNewHelperRecoversBoth() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        try power.update(closed: true, source: .battery)
        try power.update(closed: true, source: .ac)
        try power.update(closed: true, source: .battery)
        XCTAssertEqual(pmset.modes, ["-b": 1, "-c": 1])
        XCTAssertEqual(pmset.writes.count, 2)
        let restarted = ClosedLidPower(runner: pmset, directory: directory)
        XCTAssertTrue(restarted.hasPendingRestore)
        try restarted.restore()
        XCTAssertEqual(pmset.modes, ["-b": 0, "-c": 2])
        XCTAssertFalse(restarted.hasPendingRestore)
    }

    func testUnknownMalformedAndMissingSettingsCannotCauseWrites() throws {
        let invalid = [
            "Battery Power:\n powermode 3\nAC Power:\n powermode 0\n",
            "Battery Power:\n lowpowermode 2\n",
            "Battery Power:\n powermode 0 extra\n",
            "Battery Power:\n powermode 0\n powermode 1\n",
            "AC Power:\n powermode 0\n",
            "Battery Power:\n displaysleep 10\n",
            "Usage: pmset <options>\n"
        ]
        for output in invalid {
            let pmset = Pmset()
            pmset.rawOutput = output
            let power = ClosedLidPower(runner: pmset, directory: directory)
            XCTAssertThrowsError(try power.update(closed: true, source: .battery))
            XCTAssertTrue(pmset.writes.isEmpty)
            XCTAssertFalse(power.hasPendingRestore)
        }
        let pmset = Pmset()
        XCTAssertThrowsError(try ClosedLidPower(runner: pmset, directory: directory).update(closed: true, source: .unknown))
        XCTAssertTrue(pmset.calls.isEmpty)
    }

    func testModernSettingTakesPrecedenceAndOtherSourcesDoNotSupplyFallback() throws {
        let pmset = Pmset()
        pmset.rawOutput = "Battery Power:\n powermode 1\n lowpowermode 0\nAC Power:\n powermode 2\n"
        let power = ClosedLidPower(runner: pmset, directory: directory)
        try power.update(closed: true, source: .battery)
        XCTAssertTrue(pmset.writes.isEmpty)
        XCTAssertFalse(power.hasPendingRestore)
    }

    func testFailedWriteOrReadbackRetainsRecoveryForAnotherHelper() throws {
        for failure in ["write", "unchanged", "read"] {
            let pmset = Pmset()
            pmset.failingWriteScope = failure == "write" ? "-b" : nil
            pmset.appliesWrites = failure != "unchanged"
            pmset.failReadAfterWrite = failure == "read"
            let power = ClosedLidPower(runner: pmset, directory: directory)
            XCTAssertThrowsError(try power.update(closed: true, source: .battery))
            XCTAssertTrue(power.hasPendingRestore)
            pmset.failingWriteScope = nil
            pmset.appliesWrites = true
            pmset.failReadAfterWrite = false
            pmset.readFailure = false
            let restarted = ClosedLidPower(runner: pmset, directory: directory)
            try restarted.update(closed: true, source: .battery)
            XCTAssertEqual(pmset.modes["-b"], 1)
            try restarted.restore()
            XCTAssertEqual(pmset.modes["-b"], 0)
            XCTAssertFalse(restarted.hasPendingRestore)
        }
    }

    func testPartialRestoreKeepsOnlyFailedScopeAndPreservesExternalChanges() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        try power.update(closed: true, source: .battery)
        try power.update(closed: true, source: .ac)
        pmset.failingWriteScope = "-b"
        pmset.modes["-c"] = 0
        XCTAssertThrowsError(try power.restore())
        XCTAssertEqual(pmset.modes, ["-b": 1, "-c": 0])
        XCTAssertTrue(power.hasPendingRestore)
        pmset.failingWriteScope = nil
        let writes = pmset.writes.count
        let restarted = ClosedLidPower(runner: pmset, directory: directory)
        try restarted.restore()
        XCTAssertEqual(pmset.modes, ["-b": 0, "-c": 0])
        XCTAssertEqual(Array(pmset.writes.dropFirst(writes)), [["-b", "powermode", "0"]])
        XCTAssertFalse(restarted.hasPendingRestore)
    }

    func testExternalChangesAfterVerifiedApplicationAreNotRedimmed() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        try power.update(closed: true, source: .battery)
        pmset.modes["-b"] = 2
        try power.update(closed: true, source: .battery)
        try power.restore()
        XCTAssertEqual(pmset.modes["-b"], 2)
        XCTAssertEqual(pmset.writes, [["-b", "powermode", "1"]])
        XCTAssertFalse(power.hasPendingRestore)
    }

    func testRecoveryFileIsPrivateAndMalformedOrUnboundedRecordsBlockChanges() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        try power.update(closed: true, source: .battery)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, geteuid())
        let invalid = [
            Data("not json".utf8),
            Data(#"{"version":1,"touches":[{"scope":"-a","key":"powermode","original":0,"applied":true}]}"#.utf8),
            Data(#"{"version":1,"touches":[{"scope":"-b","key":"sleep","original":0,"applied":true}]}"#.utf8),
            Data(#"{"version":1,"touches":[{"scope":"-b","key":"lowpowermode","original":2,"applied":true}]}"#.utf8),
            Data(repeating: 32, count: 4097)
        ]
        let writes = pmset.writes.count
        for data in invalid {
            try data.write(to: file)
            XCTAssertTrue(power.hasPendingRestore)
            XCTAssertThrowsError(try power.restore())
            XCTAssertThrowsError(try power.update(closed: true, source: .ac))
            XCTAssertEqual(pmset.writes.count, writes)
        }
    }

    func testSymlinkJournalAndDirectoryAreRejectedWithoutFollowingTarget() throws {
        let pmset = Pmset()
        let power = ClosedLidPower(runner: pmset, directory: directory)
        try power.update(closed: true, source: .battery)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let target = directory.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertTrue(power.hasPendingRestore)
        XCTAssertThrowsError(try power.restore())
        XCTAssertThrowsError(try power.update(closed: true, source: .ac))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))

        let link = directory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let linked = ClosedLidPower(runner: pmset, directory: link)
        XCTAssertTrue(linked.hasPendingRestore)
        XCTAssertThrowsError(try linked.restore())
        XCTAssertEqual(pmset.writes.count, 1)
    }
}
