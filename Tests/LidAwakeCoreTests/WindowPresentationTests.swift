import LidAwakeShared
import XCTest
@testable import LidAwakeCore

final class StatusLineTests: XCTestCase {
    private let eightyMinutes: TimeInterval = 80 * 60

    func testOffShowsNothing() {
        XCTAssertNil(StatusLine.text(mode: .off, isPaused: false, timerRemaining: nil, battery: .percent(82), powerSource: .battery, thermal: .nominal))
    }

    func testKeepScreenOnWithoutTimer() {
        XCTAssertEqual(
            StatusLine.text(mode: .keepScreenOn, isPaused: false, timerRemaining: nil, battery: .percent(82), powerSource: .battery, thermal: .nominal),
            "Screen stays on"
        )
    }

    func testKeepScreenOnWithTimer() {
        XCTAssertEqual(
            StatusLine.text(mode: .keepScreenOn, isPaused: false, timerRemaining: eightyMinutes, battery: .percent(82), powerSource: .battery, thermal: .nominal),
            "1h 20m left"
        )
    }

    func testLidClosedWithTimer() {
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: eightyMinutes, battery: .percent(82), powerSource: .battery, thermal: .nominal),
            "1h 20m left · Battery 82% · Nominal thermals"
        )
    }

    func testLidClosedWithoutTimer() {
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: .percent(82), powerSource: .battery, thermal: .nominal),
            "Battery 82% · Nominal thermals"
        )
    }

    func testLidClosedPaused() {
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: true, timerRemaining: eightyMinutes, battery: .percent(82), powerSource: .battery, thermal: .nominal),
            "Paused · on battery · Nominal thermals"
        )
    }

    func testUnreadableBattery() {
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: eightyMinutes, battery: .unknown, powerSource: .battery, thermal: .nominal),
            "1h 20m left · Battery unknown · Nominal thermals"
        )
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: .unknown, powerSource: .battery, thermal: .nominal),
            "Battery unknown · Nominal thermals"
        )
    }

    func testMacWithoutBattery() {
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: eightyMinutes, battery: .none, powerSource: .battery, thermal: .nominal),
            "1h 20m left · Nominal thermals"
        )
        XCTAssertEqual(StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: .none, powerSource: .battery, thermal: .nominal), "Nominal thermals")
    }

    func testDisabledStatusFieldsAreOmitted() {
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: eightyMinutes, battery: .percent(82), powerSource: .battery, thermal: nil),
            "1h 20m left · Battery 82%"
        )
        XCTAssertNil(StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: .none, powerSource: .battery, thermal: nil))
        XCTAssertEqual(
            StatusLine.text(mode: .lidClosed, isPaused: true, timerRemaining: nil, battery: .none, powerSource: .battery, thermal: nil),
            "Paused · on battery"
        )
    }

    func testPluggedInReplacesVisibleBatteryLevelWithCharging() {
        for battery in [BatteryLevel.percent(82), .unknown] {
            XCTAssertEqual(
                StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: battery, powerSource: .ac, thermal: nil),
                "Charging"
            )
        }
        XCTAssertNil(StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: .none, powerSource: .ac, thermal: nil))
    }

    func testCompactCountdownRoundsUpToMinutes() {
        for (seconds, expected) in [(1.0, "0h 1m left"), (7200, "2h 0m left"), (4741, "1h 20m left")] {
            XCTAssertEqual(
                StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: seconds, battery: .none, powerSource: .battery, thermal: nil),
                expected
            )
        }
    }

    func testThermalCategories() {
        let cases: [(ThermalState, String)] = [
            (.nominal, "Nominal"), (.fair, "Fair"), (.serious, "Serious"),
            (.critical, "Critical"), (.unknown, "Unknown"),
        ]
        for (state, category) in cases {
            XCTAssertEqual(
                StatusLine.text(mode: .lidClosed, isPaused: false, timerRemaining: nil, battery: .none, powerSource: .battery, thermal: state),
                "\(category) thermals"
            )
        }
    }

    func testRemainingTimeRoundsUpToMinutes() {
        XCTAssertEqual(DurationFormat.remaining(1), "1 min")
        XCTAssertEqual(DurationFormat.remaining(45 * 60), "45 min")
        XCTAssertEqual(DurationFormat.remaining(7200), "2 h")
        XCTAssertEqual(DurationFormat.remaining(4741), "1 h 20 min")
    }
}

final class SafetyLayoutTests: XCTestCase {
    func testLayoutFollowsMode() {
        XCTAssertEqual(SafetyLayout(mode: .off), .all)
        XCTAssertEqual(SafetyLayout(mode: .lidClosed), .all)
        XCTAssertEqual(SafetyLayout(mode: .keepScreenOn), .timerOnly)
    }
}

final class WindowMessageTests: XCTestCase {
    private func only(helper: HelperPrompt? = nil, mode: ModeMessage? = nil) -> WindowMessage? {
        let messages = WindowMessage.list(helper: helper, mode: mode)
        XCTAssertEqual(messages.count, 1)
        return messages.first
    }

    func testNothingToSay() {
        XCTAssertEqual(WindowMessage.list(helper: nil, mode: nil), [])
    }

    func testApproval() {
        let message = only(helper: .approval)
        XCTAssertEqual(message?.kind, .actionNeeded)
        XCTAssertEqual(message?.title, "Permission needed")
        XCTAssertEqual(
            message?.text,
            "Allow MacStayAwake in System Settings > General > Login Items & Extensions. The mode turns on as soon as you do."
        )
        XCTAssertEqual(message?.action, .openSystemSettings)
        XCTAssertEqual(message?.actionTitle, "Open System Settings")
    }

    func testApprovalExpired() {
        let message = only(helper: .approvalExpired)
        XCTAssertEqual(message?.kind, .actionNeeded)
        XCTAssertEqual(message?.title, "Permission needed")
        XCTAssertEqual(
            message?.text,
            "Allow MacStayAwake in System Settings > General > Login Items & Extensions, then choose Stay Awake again."
        )
        XCTAssertEqual(message?.action, .openSystemSettings)
        XCTAssertEqual(message?.actionTitle, "Open System Settings")
    }

    func testMoveToApplications() {
        let message = only(helper: .moveToApplications)
        XCTAssertEqual(message?.kind, .actionNeeded)
        XCTAssertEqual(message?.title, "Move MacStayAwake to Applications")
        XCTAssertEqual(message?.text, "Stay Awake needs the app in the Applications folder.")
        XCTAssertNil(message?.action)
        XCTAssertNil(message?.actionTitle)
    }

    func testHelperFailed() {
        let message = only(helper: .failed("Broken"))
        XCTAssertEqual(message?.kind, .error)
        XCTAssertEqual(message?.title, "The helper did not start")
        XCTAssertEqual(message?.text, "Broken")
        XCTAssertEqual(message?.action, .tryAgain)
        XCTAssertEqual(message?.actionTitle, "Try Again")
    }

    func testCouldNotTurnOn() {
        let message = only(mode: .couldNotTurnOn("The battery is at 12%, at or below the 20% limit."))
        XCTAssertEqual(message?.kind, .error)
        XCTAssertEqual(message?.title, "Could not turn on")
        XCTAssertEqual(message?.text, "The battery is at 12%, at or below the 20% limit.")
        XCTAssertNil(message?.action)
        XCTAssertNil(message?.actionTitle)
    }

    func testTurnedOff() {
        let message = only(mode: .turnedOff("The timer ran out."))
        XCTAssertEqual(message?.kind, .info)
        XCTAssertEqual(message?.title, "MacStayAwake turned off")
        XCTAssertEqual(message?.text, "The timer ran out.")
        XCTAssertNil(message?.action)
        XCTAssertNil(message?.actionTitle)
    }

    func testTurnedOffWithError() {
        let message = only(mode: .turnedOffWithError("The helper did not respond."))
        XCTAssertEqual(message?.kind, .error)
        XCTAssertEqual(message?.title, "MacStayAwake turned off")
        XCTAssertEqual(message?.text, "The helper did not respond.")
        XCTAssertNil(message?.actionTitle)
    }

    func testFailed() {
        let message = only(mode: .failed("Broken"))
        XCTAssertEqual(message?.kind, .error)
        XCTAssertEqual(message?.title, "Something went wrong")
        XCTAssertEqual(message?.text, "Broken")
        XCTAssertNil(message?.actionTitle)
    }

    func testRestarted() {
        let message = only(mode: .restarted)
        XCTAssertEqual(message?.kind, .info)
        XCTAssertEqual(message?.title, "MacStayAwake turned off")
        XCTAssertEqual(message?.text, "MacStayAwake was restarted. Turn the mode on again if you need it.")
        XCTAssertNil(message?.action)
        XCTAssertNil(message?.actionTitle)
    }

    func testHelperMessageStandsAboveModeMessage() {
        let messages = WindowMessage.list(helper: .approval, mode: .turnedOff("The timer ran out."))
        XCTAssertEqual(messages.map(\.source), [.helper, .mode])
        XCTAssertEqual(messages.map(\.title), ["Permission needed", "MacStayAwake turned off"])
    }
}

final class OpeningFocusTests: XCTestCase {
    func testOffFocusesOff() {
        XCTAssertEqual(OpeningFocus.card(selected: .off), .off)
    }

    func testKeepScreenOnFocusesKeepScreenOn() {
        XCTAssertEqual(OpeningFocus.card(selected: .keepScreenOn), .keepScreenOn)
    }

    func testLidClosedFocusesLidClosed() {
        XCTAssertEqual(OpeningFocus.card(selected: .lidClosed), .lidClosed)
    }

    func testFocusOnSelectedCardFollowsNewSelection() {
        XCTAssertEqual(OpeningFocus.card(focused: .keepScreenOn, previous: .keepScreenOn, selected: .lidClosed), .lidClosed)
    }

    func testFocusOnOtherCardMovesToNewSelection() {
        XCTAssertEqual(OpeningFocus.card(focused: .off, previous: .keepScreenOn, selected: .lidClosed), .lidClosed)
    }

    func testFocusOnCardMovesToOffWhenModeEndsOnItsOwn() {
        XCTAssertEqual(OpeningFocus.card(focused: .lidClosed, previous: .lidClosed, selected: .off), .off)
    }

    func testFocusOnCardThatBecomesSelectedStaysOnIt() {
        XCTAssertEqual(OpeningFocus.card(focused: .lidClosed, previous: .off, selected: .lidClosed), .lidClosed)
    }

    func testNoFocusOnCardsStaysAsIs() {
        XCTAssertNil(OpeningFocus.card(focused: nil, previous: .off, selected: .lidClosed))
        XCTAssertNil(OpeningFocus.card(focused: nil, previous: .lidClosed, selected: .off))
    }

    func testUnchangedModeKeepsFocus() {
        XCTAssertEqual(OpeningFocus.card(focused: .off, previous: .keepScreenOn, selected: .keepScreenOn), .off)
        XCTAssertEqual(OpeningFocus.card(focused: .lidClosed, previous: .lidClosed, selected: .lidClosed), .lidClosed)
        XCTAssertNil(OpeningFocus.card(focused: nil, previous: .keepScreenOn, selected: .keepScreenOn))
    }
}
