import Foundation
import XCTest
@testable import LidAwakeShared

final class SettingEventTests: XCTestCase {
    func testTransportRoundTripAndRejectsInvalidOrUnboundedPayloads() throws {
        let event = SettingEvent(time: Date(timeIntervalSince1970: 1234), setting: .powerMode,
            source: .battery, operation: .restore, outcome: .verified, key: .powermode,
            prior: 1, current: 2, target: 2)
        XCTAssertEqual(SettingEventWire.decode(SettingEventWire.encode([event])), [event])
        let encoder = JSONEncoder()
        let tooMany = String(decoding: try encoder.encode(Array(repeating: event, count: SettingEventWire.maximumCount + 1)), as: UTF8.self)
        XCTAssertNil(SettingEventWire.decode(tooMany))
        XCTAssertEqual(SettingEventWire.decode(SettingEventWire.encode(Array(repeating: event, count: 200)))?.count, 128)
        for text in ["garbage", "{}", String(repeating: " ", count: SettingEventWire.maximumBytes + 1),
                     SettingEventWire.encode([event]).replacingOccurrences(of: "powermode", with: "brightness"),
                     SettingEventWire.encode([event]).replacingOccurrences(of: "battery", with: "builtInDisplay")] {
            XCTAssertNil(SettingEventWire.decode(text))
        }
        let failedUnknown = SettingEvent(time: event.time, setting: .powerMode, source: .unknown,
            operation: .apply, outcome: .failed, target: 1)
        XCTAssertEqual(SettingEventWire.decode(SettingEventWire.encode([failedUnknown])), [failedUnknown])
        let missingVerification = SettingEvent(time: event.time, setting: .powerMode, source: .battery,
            operation: .apply, outcome: .verified, key: .powermode, current: 0, target: 1)
        XCTAssertNil(SettingEventWire.decode(String(decoding: try encoder.encode([missingVerification]), as: UTF8.self)))
        let invalid = SettingEvent(time: event.time, setting: .brightness, source: .builtInDisplay,
            operation: .apply, outcome: .verified, key: .brightness, current: 2)
        XCTAssertNil(SettingEventWire.decode(String(decoding: try encoder.encode([invalid]), as: UTF8.self)))
    }
}
