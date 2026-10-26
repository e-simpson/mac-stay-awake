import Foundation
import XCTest
@testable import LidAwakeCore

@MainActor
final class DisplayBrightnessTests: XCTestCase {
    private final class Panel: DisplayBrightnessAccess {
        var brightness: Float = 0.72
        var readError: DisplayBrightnessError?
        var writeError: DisplayBrightnessError?
        var ignoredWrites = false
        var writeAdjustment: Float = 0
        var writes: [Float] = []

        func read() throws -> Float {
            if let readError { throw readError }
            return brightness
        }

        func write(_ brightness: Float) throws {
            if let writeError { throw writeError }
            writes.append(brightness)
            if !ignoredWrites { self.brightness = min(1, max(0, brightness + writeAdjustment)) }
        }
    }

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DisplayBrightnessTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testRepeatedCloseAndSamplingCannotReplaceTheOriginalWithAppZero() {
        let panel = Panel()
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.close(), .dimmed)
        XCTAssertEqual(panel.brightness, 0)
        XCTAssertEqual(brightness.close(), .dimmed)
        XCTAssertEqual(brightness.sampleWhileOpen(), .pending)
        XCTAssertEqual(brightness.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72)
        XCTAssertFalse(brightness.hasPendingRestore)
        XCTAssertEqual(panel.writes, [0, 0.72])
    }

    func testNewOwnerRecoversPersistedBrightnessAfterCrash() {
        let panel = Panel()
        XCTAssertEqual(DisplayBrightness(access: panel, defaults: defaults).close(), .dimmed)
        let restarted = DisplayBrightness(access: panel, defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(restarted.hasPendingRestore)
        XCTAssertEqual(restarted.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72)
    }

    func testOfflineCloseRetainsLastOpenSampleAndRetriesWhenPanelReturns() {
        let panel = Panel()
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.sampleWhileOpen(), .sampled)
        panel.readError = .displayOffline
        panel.writeError = .displayOffline
        XCTAssertEqual(brightness.close(), .pending)
        XCTAssertTrue(brightness.hasPendingRestore)
        XCTAssertEqual(brightness.restore(), .pending)
        panel.readError = nil
        panel.writeError = nil
        XCTAssertEqual(brightness.close(), .dimmed)
        XCTAssertEqual(brightness.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72)
    }

    func testUnavailableOrInvalidSampleNeverInventsBrightnessOrDims() {
        for value in [Float.nan, -Float.infinity, -0.1, 1.1] {
            let panel = Panel()
            panel.brightness = value
            let brightness = DisplayBrightness(access: panel, defaults: defaults)
            XCTAssertEqual(brightness.sampleWhileOpen(), .unavailable)
            XCTAssertEqual(brightness.close(), .unavailable)
            XCTAssertTrue(panel.writes.isEmpty)
            XCTAssertFalse(brightness.hasPendingRestore)
        }
        for error in [DisplayBrightnessError.unavailable, .displayOffline, .readFailed] {
            let panel = Panel()
            panel.readError = error
            let brightness = DisplayBrightness(access: panel, defaults: defaults)
            XCTAssertEqual(brightness.close(), .unavailable)
            XCTAssertTrue(panel.writes.isEmpty)
            XCTAssertFalse(brightness.hasPendingRestore)
        }
    }

    func testFailedRestoreRemainsRecoverableAcrossAnotherLaunch() {
        let panel = Panel()
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.close(), .dimmed)
        panel.writeError = .writeFailed
        XCTAssertEqual(brightness.restore(), .pending)
        XCTAssertTrue(brightness.hasPendingRestore)
        panel.writeError = nil
        XCTAssertEqual(DisplayBrightness(access: panel, defaults: defaults).restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72)
    }

    func testIgnoredDimIsUnavailableAndOriginalSurvivesRecreationAndRetry() {
        let panel = Panel()
        panel.ignoredWrites = true
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.close(), .unavailable)
        XCTAssertEqual(panel.brightness, 0.72)
        XCTAssertTrue(brightness.hasPendingRestore)

        panel.ignoredWrites = false
        let restarted = DisplayBrightness(access: panel, defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(restarted.close(), .dimmed)
        XCTAssertEqual(panel.brightness, 0)
        XCTAssertEqual(restarted.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72)
        XCTAssertFalse(restarted.hasPendingRestore)
    }

    func testIgnoredRestoreRetainsOriginalAcrossRecreationUntilVerifiedRetry() {
        let panel = Panel()
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.close(), .dimmed)
        panel.ignoredWrites = true
        XCTAssertEqual(brightness.restore(), .pending)
        XCTAssertEqual(panel.brightness, 0)
        XCTAssertTrue(brightness.hasPendingRestore)

        let restarted = DisplayBrightness(access: panel, defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(restarted.hasPendingRestore)
        panel.ignoredWrites = false
        XCTAssertEqual(restarted.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72)
        XCTAssertFalse(restarted.hasPendingRestore)
    }

    func testSmallNativeRoundingStillVerifiesAndRemainsOwnedUntilRestore() {
        let panel = Panel()
        panel.writeAdjustment = 0.002
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.close(), .dimmed)
        XCTAssertEqual(brightness.close(), .dimmed)
        XCTAssertEqual(brightness.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0.72, accuracy: 0.005)
        XCTAssertFalse(brightness.hasPendingRestore)
    }

    func testObservableExternalChangeIsPreservedDuringCloseAndRestore() {
        for initialFailure in [false, true] {
            let panel = Panel()
            panel.writeError = initialFailure ? .writeFailed : nil
            let brightness = DisplayBrightness(access: panel, defaults: defaults)
            XCTAssertEqual(brightness.close(), initialFailure ? .unavailable : .dimmed)
            panel.writeError = nil
            panel.brightness = 0.35
            XCTAssertEqual(brightness.close(), .preservedExternalChange)
            XCTAssertEqual(brightness.restore(), .preservedExternalChange)
            XCTAssertEqual(panel.brightness, 0.35)
            XCTAssertEqual(panel.writes, initialFailure ? [] : [0])
            XCTAssertFalse(brightness.hasPendingRestore)
        }
    }

    func testUserZeroIsAValidOriginalAndFailedDimDoesNotCreateANewSetting() {
        let panel = Panel()
        panel.brightness = 0
        let brightness = DisplayBrightness(access: panel, defaults: defaults)
        XCTAssertEqual(brightness.close(), .dimmed)
        XCTAssertEqual(brightness.restore(), .restored)
        XCTAssertEqual(panel.brightness, 0)
        panel.brightness = 0.72
        panel.writeError = .writeFailed
        XCTAssertEqual(brightness.close(), .unavailable)
        XCTAssertEqual(brightness.restore(), .unchanged)
        XCTAssertEqual(panel.brightness, 0.72)
        XCTAssertFalse(brightness.hasPendingRestore)
    }
}
