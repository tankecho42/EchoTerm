import XCTest
import AppKit
@testable import EchoTerm

final class ShellTests: XCTestCase {
    @MainActor func testRealPTYStateOutputExitAndInterrupt() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.start()
        try await wait { session.ready }
        session.draft = "export ECHOTERM_TEST_VALUE=retained; cd /; printf '你好\\n'; /bin/false"
        session.execute()
        try await wait { !session.running }
        XCTAssertEqual(session.blocks.last?.exitCode, 1)
        XCTAssertTrue(session.blocks.last?.output.contains("你好") == true)
        XCTAssertEqual(session.directory, "/")
        session.draft = "printf '%s\\n' \"$ECHOTERM_TEST_VALUE\""
        session.execute()
        try await wait { !session.running }
        XCTAssertEqual(session.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines), "retained")
        session.draft = "sleep 30"
        session.execute()
        try await Task.sleep(nanoseconds: 250_000_000)
        session.interrupt()
        try await wait { !session.running }
        XCTAssertEqual(session.blocks.last?.exitCode, 130)
        session.draft = "printf 'after interrupt\\n'"
        session.execute()
        try await wait { !session.running }
        XCTAssertTrue(session.blocks.last?.output.contains("after interrupt") == true)
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for shell")
        throw AIError.message("shell test timeout")
    }
}
