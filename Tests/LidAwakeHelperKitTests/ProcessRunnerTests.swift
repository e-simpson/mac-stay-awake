import Darwin
import Foundation
import XCTest
@testable import LidAwakeHelperKit

final class ProcessRunnerTests: XCTestCase {
    func testTimedOutWriterIsDeadBeforeReturning() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if let text = try? String(contentsOf: pidFile), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidFile)
        }
        let writer = "echo $$ > \"$1\"; trap '' TERM; while :; do :; done"
        XCTAssertThrowsError(try ProcessRunner().run("/bin/sh", ["-c", writer, "writer", pidFile.path], timeout: 0.15))
        let text = try String(contentsOf: pidFile)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "Timed-out process must not outlive recovery")
        XCTAssertEqual(errno, ESRCH)
    }
}
