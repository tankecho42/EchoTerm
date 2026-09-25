import XCTest
@testable import EchoTerm

final class CoreTests: XCTestCase {
    func testPTYFramesAcrossEveryByteBoundary() {
        let command = "echo 中文; printf 'hello'"
        let cwd = "/tmp/带 空格;目录"
        let encoded = Data(command.utf8).base64EncodedString()
        let path = Data(cwd.utf8).base64EncodedString()
        let bytes = Array("before\u{1b}]777;EchoTerm;token;B;\(encoded)\u{7}你好\r\n\u{1b}]777;EchoTerm;token;D;42;\(path)\u{7}after".utf8)
        for split in 0...bytes.count {
            var parser = ShellStreamParser(token: "token")
            let events = parser.feed(Array(bytes.prefix(split))) + parser.feed(Array(bytes.dropFirst(split)))
            XCTAssertTrue(events.contains(.began(command)))
            XCTAssertTrue(events.contains(.prompt(42, cwd)))
            let output = events.flatMap { event -> [UInt8] in if case .output(let bytes) = event { return bytes }; return [] }
            XCTAssertEqual(String(decoding: output, as: UTF8.self), "before你好\r\nafter")
        }
    }
    func testUnrelatedOSCPreserved() {
        var parser = ShellStreamParser(token: "private")
        let bytes = Array("\u{1b}]777;EchoTerm;wrong;D;0;Lw==\u{7}\u{1b}[31mred\u{1b}[0m".utf8)
        let result = parser.feed(bytes).flatMap { event -> [UInt8] in if case .output(let bytes) = event { return bytes }; return [] }
        XCTAssertEqual(result, bytes)
    }
    func testAPIProtocolsAndToolResponses() throws {
        for api in APIProtocol.allCases {
            let config = ProviderConfiguration(id: "test", name: "test", endpoint: "https://example.com/v1/", model: "test-model", apiProtocol: api)
            let request = try AIClient.request(config: config, key: "test-key", messages: [["role": "user", "content": "help"]], context: "context")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/" + api.path)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertNotNil(body["tools"])
            XCTAssertEqual(body["model"] as? String, "test-model")
            XCTAssertEqual(request.value(forHTTPHeaderField: api == .anthropic ? "x-api-key" : "Authorization"), api == .anthropic ? "test-key" : "Bearer test-key")
        }
        let args = #"{"command":"git status","explanation":"检查状态","risk":"read"}"#
        let fixtures: [(APIProtocol, [String: Any])] = [
            (.responses, ["output": [["type": "function_call", "name": "recommend_command", "arguments": args]]]),
            (.chatCompletions, ["choices": [["message": ["content": "看看状态", "tool_calls": [["function": ["name": "recommend_command", "arguments": args]]]]]]]),
            (.anthropic, ["content": [["type": "tool_use", "name": "recommend_command", "input": ["command": "git status", "explanation": "检查状态", "risk": "read"]]]])
        ]
        for (api, body) in fixtures {
            let reply = try AIClient.parse(JSONSerialization.data(withJSONObject: body), apiProtocol: api)
            XCTAssertEqual(reply.suggestions.first?.command, "git status")
        }
    }
    func testSecretsAndEndpointValidation() throws {
        XCTAssertFalse(ContextRedactor.redact("API_KEY=supersecret Bearer abc.def.123 password=hunter2").contains("supersecret"))
        XCTAssertFalse(ContextRedactor.redact("Bearer abc.def.123").contains("abc.def.123"))
        var config = ProviderConfiguration.presets[0]; config.model = "model"; config.endpoint = "http://example.com/v1"
        XCTAssertThrowsError(try AIClient.request(config: config, key: "secret", messages: [], context: ""))
        config.endpoint = "http://localhost:11434/v1"
        XCTAssertNoThrow(try AIClient.request(config: config, key: "", messages: [], context: ""))
    }
    @MainActor func testNestedSplitAndRemoval() {
        let a = TerminalSession(), b = TerminalSession(), c = TerminalSession()
        let root = PaneNode.leaf(a).splitting(a.id, vertical: true, newSession: b).splitting(b.id, vertical: false, newSession: c)
        XCTAssertEqual(root.sessions.count, 3)
        let removed = root.removing(b.id)
        XCTAssertEqual(removed?.sessions.map(\.id), [a.id, c.id])
    }
}
