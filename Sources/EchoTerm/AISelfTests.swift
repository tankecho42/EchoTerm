#if DEBUG
import Foundation

@MainActor enum AISelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        let legacy = #"{"id":"old","name":"old","endpoint":"http://localhost/v1","model":"test","apiProtocol":"OpenAI Compatible"}"#
        var config = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(legacy.utf8))
        check(config.effort == .automatic && config.reasoningStyle == .automatic, "Existing provider configurations migrate without losing model or endpoint")
        config.apiProtocol = .responses; config.effort = .high
        var request = try AIClient.request(config: config, key: "", messages: [], context: "", mode: .autonomous)
        var body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check((body["reasoning"] as? [String: String])?["effort"] == "high" && body["stream"] as? Bool == true && (body["tools"] as? [[String: Any]])?.first?["name"] as? String == "execute_command", "Responses sends reasoning effort, streaming and explicit execution tool")
        request = try AIClient.request(config: config, key: "", messages: [], context: "", mode: .answer, streaming: false)
        body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(body["tools"] == nil && body["stream"] as? Bool == false, "Q&A exposes no tools and supports non-streaming fallback")
        config.apiProtocol = .chatCompletions; config.model = "glm-4.7"
        check(config.reasoningParameters["reasoning_effort"] == nil && (config.reasoningParameters["thinking"] as? [String: String])?["type"] == "enabled", "Older GLM uses thinking toggle without unsupported effort")
        config.model = "glm-5.3"; config.effort = .medium
        check(config.reasoningParameters["reasoning_effort"] as? String == "high", "GLM 5.3 maps balanced effort to its supported high level")
        config.model = "deepseek-chat"; config.effort = .off
        check((config.reasoningParameters["thinking"] as? [String: String])?["type"] == "disabled", "DeepSeek can disable thinking")
        config.apiProtocol = .anthropic; config.model = "claude-sonnet-4-5"; config.effort = .medium
        check((config.reasoningParameters["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 4096 && config.reasoningParameters["max_tokens"] as? Int == 8192, "Legacy Claude budget leaves room for visible output")
        config.model = "claude-sonnet-4-6"
        check((config.reasoningParameters["output_config"] as? [String: String])?["effort"] == "medium", "Adaptive Claude uses output_config.effort")
        config.effort = .automatic
        check(config.reasoningParameters.isEmpty, "Default effort does not override provider defaults")

        let args = #"{"command":"printf '你好\\n'","explanation":"检查中文","risk":"read"}"#
        var chat = AIStreamAccumulator(apiProtocol: .chatCompletions)
        try feed(["choices": [["delta": ["reasoning_content": "opaque fixture"]]]], to: &chat)
        try feed(["choices": [["delta": ["content": "你好"]]]], to: &chat)
        check(chat.text == "你好" && (try? chat.finish()) == nil, "Text renders before completion while unfinished streams cannot execute")
        try feed(["choices": [["delta": ["tool_calls": [["index": 0, "id": "c1", "function": ["name": "execute_command", "arguments": String(args.prefix(22))]]]]]]], to: &chat)
        try feed(["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": String(args.dropFirst(22))]]]], "finish_reason": "tool_calls"]]], to: &chat)
        try chat.consume("[DONE]")
        let chatReply = try chat.finish()
        check(try chatReply.calls.first!.command().command == "printf '你好\\n'" && chatReply.continuation.first?["reasoning_content"] as? String == "opaque fixture", "Chat tool arguments reassemble and reasoning_content survives continuation")
        var sse = SSEDecoder(), decoded: [String] = []
        for byte in ": comment\r\nevent: test\r\ndata: {\r\ndata: \"text\":\"你好👋\"}\r\n\r\n".utf8 { if let data = try sse.feed(byte) { decoded.append(data) } }
        check(decoded == ["{\n\"text\":\"你好👋\"}"], "SSE handles byte-split UTF-8, CRLF, comments and multiline data")
        var responses = AIStreamAccumulator(apiProtocol: .responses)
        try feed(["type": "response.output_text.delta", "delta": "看一下"], to: &responses)
        let responseOutput: [[String: Any]] = [["type": "reasoning", "id": "r", "encrypted_content": "opaque"], ["type": "message", "role": "assistant", "phase": "commentary", "content": [["type": "output_text", "text": "看一下"]]], ["type": "function_call", "call_id": "c2", "name": "execute_command", "arguments": args]]
        try feed(["type": "response.completed", "response": ["status": "completed", "output": responseOutput]], to: &responses)
        let responseReply = try responses.finish()
        check(responseReply.calls.count == 1 && responseReply.continuation.first?["encrypted_content"] as? String == "opaque" && responseReply.continuation[1]["phase"] as? String == "commentary", "Responses replays encrypted reasoning and message phases unchanged")
        var claude = AIStreamAccumulator(apiProtocol: .anthropic)
        let claudeEvents: [[String: Any]] = [
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "", "signature": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "fixture"]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "signed"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "c3", "name": "execute_command", "input": [:]]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": args]],
            ["type": "content_block_stop", "index": 1], ["type": "message_delta", "delta": ["stop_reason": "tool_use"]], ["type": "message_stop"]
        ]
        for event in claudeEvents { try feed(event, to: &claude) }
        let claudeReply = try claude.finish()
        check(claudeReply.calls.count == 1 && (claudeReply.continuation.first?["content"] as? [[String: Any]])?.first?["signature"] as? String == "signed", "Claude keeps signed thinking blocks alongside streamed tool input")
        for api in APIProtocol.allCases {
            let results = AIClient.toolResults([(AIToolCall(id: "c", name: "execute_command", arguments: args), "result")], apiProtocol: api)
            check(!results.isEmpty && JSONSerialization.isValidJSONObject(results), "\(api.rawValue) tool results have valid provider-native envelopes")
        }
        var broken = AIStreamAccumulator(apiProtocol: .chatCompletions)
        var refused = false
        do { try feed(["choices": [["delta": ["content": "partial"], "finish_reason": "length"]]], to: &broken) } catch { refused = true }
        check(refused, "Token-truncated tools cannot execute")
        var failure = AIStreamAccumulator(apiProtocol: .responses)
        refused = false
        do { try feed(["type": "response.failed", "response": [:]], to: &failure) } catch { refused = true }
        check(refused, "Provider stream errors fail closed")

        let suite = "EchoTerm.AI.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        check(preferences.assistantMode == .answer && preferences.streamReplies, "New installs default to Q&A with streaming enabled")
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        var requested: [AIRequestContext] = []
        let agent = AssistantStore(providers: providers, preferences: preferences) { request, update in
            requested.append(request)
            if requested.count == 1 {
                update(.init(text: "先检查目录。", phase: "正在回答…"))
                try await Task.sleep(nanoseconds: 100_000_000)
                return try toolReply(command: "cd /; printf 'agent-one\\n'", id: "first")
            } else if requested.count == 2 {
                return try toolReply(command: "pwd; printf 'agent-two\\n'; false", id: "second")
            }
            return .init(text: "排查完成。")
        }
        preferences.assistantMode = .autonomous
        agent.ask("检查目录", session: session)
        try await wait { agent.messages(for: session).last?.text == "先检查目录。" }
        check(agent.thinking.contains(session.id) && session.blocks.filter { !$0.isAI }.isEmpty, "Assistant shows streaming text before its first execution")
        try await wait { !agent.thinking.contains(session.id) }
        let wire = String(decoding: try JSONSerialization.data(withJSONObject: requested.last!.messages), as: UTF8.self)
        check(session.blocks.filter { !$0.isAI }.count == 2 && session.directory == "/" && session.blocks.last(where: { !$0.isAI })?.exitCode == 1 && wire.contains("agent-two") && wire.contains("exit_code"), "Autonomous loop executes in the same real PTY and feeds output, cwd and exit status back")
        check(session.blocks.filter { !$0.isAI }.allSatisfy { $0.assistantRunID != nil } && agent.messages(for: session).flatMap(\.steps).count == 2 && session.agentOwner == nil, "Agent blocks retain provenance and release session ownership after completion")
        let before = requested.count
        preferences.proactive = true
        agent.didComplete(session.blocks.last(where: { !$0.isAI })!, session: session)
        check(requested.count == before, "Legacy proactive preference cannot start background AI requests")
        session.draft = "kept draft"
        agent.ask("检查", session: session)
        check(session.draft == "kept draft" && !agent.thinking.contains(session.id) && requested.count == before, "Autonomous mode preserves an existing user draft")
        session.draft = ""
        preferences.assistantMode = .answer
        let malicious = AssistantStore(providers: providers, preferences: preferences) { _, _ in try toolReply(command: "printf forbidden", id: "bad") }
        let previous = session.blocks.filter { !$0.isAI }.count
        malicious.ask("只回答", session: session)
        try await wait { !malicious.thinking.contains(session.id) }
        check(session.blocks.filter { !$0.isAI }.count == previous && malicious.messages(for: session).last?.status.contains("不允许") == true, "Q&A rejects unsolicited execute tools locally")

        preferences.assistantMode = .autonomous
        let sleeping = AssistantStore(providers: providers, preferences: preferences) { _, _ in try toolReply(command: "sleep 30", id: UUID().uuidString) }
        sleeping.ask("test cancel", session: session)
        try await wait { session.running }
        check(sleeping.activity(for: session) == .working, "Executing an actual PTY tool call shows the working expression")
        // Let the shell enter the foreground command before issuing Ctrl-C.
        try await Task.sleep(nanoseconds: 150_000_000)
        sleeping.cancel(session: session)
        try await wait { !session.running }
        check(session.blocks.last(where: { !$0.isAI })?.exitCode == 130 && !sleeping.thinking.contains(session.id) && session.agentOwner == nil, "Stop interrupts only the command owned by this agent and releases its run")
        sleeping.ask("test mode change", session: session)
        try await wait { session.running }
        try await Task.sleep(nanoseconds: 150_000_000)
        preferences.assistantMode = .answer
        try await wait { !session.running }
        check(!sleeping.thinking.contains(session.id) && session.blocks.last(where: { !$0.isAI })?.exitCode == 130, "Switching to Q&A stops an active autonomous command")
        let late = AssistantStore(providers: providers, preferences: preferences) { _, update in
            try? await Task.sleep(nanoseconds: 200_000_000)
            update(.init(text: "late", phase: "回答中"))
            return try toolReply(command: "printf late", id: "late")
        }
        preferences.assistantMode = .autonomous
        let countBeforeLate = session.blocks.filter { !$0.isAI }.count
        late.ask("cancel during network", session: session)
        late.cancel(session: session)
        try await Task.sleep(nanoseconds: 250_000_000)
        check(session.blocks.filter { !$0.isAI }.count == countBeforeLate && late.messages(for: session).last?.text != "late", "Late network callbacks cannot resurrect a cancelled run or execute commands")
        preferences.assistantMode = .answer
        session.draft = "sleep 30"; session.execute()
        let deferredQuestion = !late.ask("问答", session: session); late.cancel(session: session)
        try await Task.sleep(nanoseconds: 250_000_000)
        check(deferredQuestion && session.running, "Rejecting a question during a command leaves the user's foreground process running")
        session.interrupt(); try await wait { !session.running }
        preferences.assistantMode = .autonomous; preferences.agentStepLimit = 1
        var rounds = 0, finalMode: AssistantMode?
        let limited = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            rounds += 1; finalMode = request.mode
            return rounds == 1 ? try toolReply(command: "printf limited", id: "limit") : .init(text: "已总结")
        }
        limited.ask("limit", session: session)
        try await wait { !limited.thinking.contains(session.id) }
        check(rounds == 2 && finalMode == .answer && limited.messages(for: session).flatMap(\.steps).count == 1, "Command limit allows a final summary but exposes no further execution tool")
        preferences.commandTimeout = 1
        var timeoutRound = 0, timedOutWire = ""
        let timeout = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            timeoutRound += 1
            if timeoutRound == 1 { return try toolReply(command: "sleep 30", id: "timeout") }
            timedOutWire = String(decoding: try JSONSerialization.data(withJSONObject: request.messages), as: UTF8.self)
            return .init(text: "超时已停止")
        }
        timeout.ask("timeout", session: session)
        try await wait { !timeout.thinking.contains(session.id) }
        check(!session.running && session.blocks.last(where: { !$0.isAI })?.exitCode == 130 && timedOutWire.contains("timed_out") && timeout.messages(for: session).flatMap(\.steps).first?.status == "已超时中断", "Command timeout interrupts and reports its outcome to the model")
        preferences.shareContext = false
        limited.ask("disabled context", session: session)
        check(!limited.thinking.contains(session.id) && limited.messages(for: session).last?.text.contains("需要读取") == true, "Autonomous execution requires permission to read terminal results")
        preferences.shareContext = true
        sleeping.ask("close session", session: session)
        try await wait { session.running }
        session.onClose = { [weak sleeping, weak session] in if let session { sleeping?.cancel(session: session) } }
        session.close()
        check(!sleeping.thinking.contains(session.id) && session.exited, "Closing a pane cancels its autonomous task")
    }
    static func network(check: (Bool, String) -> Void) async throws {
        guard let endpoint = ProcessInfo.processInfo.environment["ECHOTERM_TEST_API"] else { return }
        for api in APIProtocol.allCases {
            let config = ProviderConfiguration(id: "test", name: "local test", endpoint: endpoint, model: "fixture", apiProtocol: api)
            var partial = false
            let reply = try await AIClient.send(config: config, key: "", messages: [["role": "user", "content": "hello"]], context: "") { update in
                if !update.text.isEmpty && !update.text.contains("完成") { partial = true }
            }
            check(partial && reply.text.contains("你好") && reply.text.contains("完成"), "\(api.rawValue) live HTTP stream renders before completion")
            check(reply.usage?.total == 150 && reply.usage?.input == 120, "\(api.rawValue) live SSE retains cumulative usage through completion")
            let fast = try await AIClient.send(config: config, key: "", messages: [["role": "user", "content": "hello"]], context: "", purpose: .intent)
            check(fast.usage?.total == 52, "\(api.rawValue) non-streaming fast responses retain usage")
        }
        let suite = "EchoTerm.Network.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        preferences.assistantMode = .autonomous
        providers.configurations = [.init(id: "local-test", name: "local", endpoint: endpoint, model: "fixture", apiProtocol: .chatCompletions)]
        providers.selectedID = "local-test"
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        let agent = AssistantStore(providers: providers, preferences: preferences) { request, update in
            try await AIClient.send(config: request.config, key: "", messages: request.messages, context: request.context, mode: request.mode, streaming: request.streaming, purpose: request.purpose, onUpdate: update)
        }
        agent.ask("local full loop", session: session)
        try await wait { !agent.thinking.contains(session.id) }
        check(session.blocks.filter { !$0.isAI }.count == 2 && session.blocks.allSatisfy { $0.exitCode == 0 } && agent.messages(for: session).last?.text.contains("本地测试完成") == true, "Live SSE to real PTY to tool-result to final response works end to end")
        check(agent.messages(for: session).last?.roundSummary?.usage.total == 450 && agent.usage.records.count == 3, "Live autonomous SSE reports three requests and a single full-turn total")
        var config = providers.selected; config.model = "truncated"
        var partial = "", errorText = ""
        do { _ = try await AIClient.send(config: config, key: "", messages: [["role": "user", "content": "hello"]], context: "") { partial = $0.text } }
        catch { errorText = error.localizedDescription }
        check(!partial.isEmpty && errorText.contains("断开"), "Network EOF preserves streamed text but fails an incomplete response")
        config.model = "http-error"
        do { _ = try await AIClient.send(config: config, key: "", messages: [], context: "") } catch { errorText = error.localizedDescription }
        check(errorText.contains("HTTP 400") && !errorText.contains("DO-NOT-ECHO"), "HTTP failures do not expose private gateway response bodies")
    }
    private static func feed(_ object: [String: Any], to parser: inout AIStreamAccumulator) throws {
        try parser.consume(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    private static func toolReply(command: String, id: String) throws -> AIReply {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["command": command, "explanation": "test", "risk": "read"]), as: UTF8.self)
        return .init(text: "", calls: [.init(id: id, name: AIClient.executeTool, arguments: args)], continuation: [["role": "assistant", "content": "", "tool_calls": [["id": id, "type": "function", "function": ["name": AIClient.executeTool, "arguments": args]]]]])
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw AIError.message("Timed out waiting for AI test")
    }
}
#endif
