#if DEBUG
import Foundation

@MainActor enum UserInteractionSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        for api in APIProtocol.allCases { try await genericQuestions(api: api, check: check) }
        try await cancellation(check: check)
        try await invalidRequests(check: check)
        for shell in ["/bin/zsh", "/bin/bash"] { try await terminalQuestions(shell: shell, check: check) }
        try await completedCommandInvalidatesQuestion(check: check)
        try await manualInputRetiresQuestion(check: check)
        try await timeoutDuringStalledTransport(check: check)
    }

    private static func genericQuestions(api: APIProtocol, check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.UserQuestions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults, api: api)
        preferences.quickIntents = false; preferences.shareContext = false; preferences.assistantMode = .answer
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        var requests: [AIRequestContext] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            switch requests.count {
            case 1:
                return try toolReply(api: api, calls: [("ask_user", question("Choose the next step", options: [("Button label", "fixture-button"), ("Other button", "fixture-other")], custom: false))])
            case 2:
                return try toolReply(api: api, calls: [("ask_user", question("Enter a custom answer", options: [], custom: true))])
            default: return .init(text: "Question flow completed")
            }
        }
        defer { assistant.cancel(session: session) }
        check(assistant.ask("Ask me for a button, then text", session: session), "\(api.rawValue) a Q&A run accepts an interactive question without terminal context")
        try await wait { assistant.userQuestions.values.contains { $0.state == .pending } }
        let first = assistant.userQuestions.values.first { $0.state == .pending }!
        let replyID = assistant.messages(for: session).last!.id
        check(first.spec.question == "Choose the next step" && assistant.questions(for: replyID).contains { $0.id == first.id }, "\(api.rawValue) the question belongs to its actual assistant reply")
        check(assistant.canAnswerQuestion(first.id) && !assistant.answerQuestion(first.id, optionID: "missing-option") && !assistant.answerQuestion(first.id, text: "not-allowed"), "\(api.rawValue) unknown choices and disallowed custom text cannot resolve a question")
        check(assistant.answerQuestion(first.id, optionID: "option-1"), "\(api.rawValue) a button resolves the question using its stable option ID")
        check(!assistant.answerQuestion(first.id, optionID: "option-1") && !assistant.canAnswerQuestion(first.id), "\(api.rawValue) a duplicate button click cannot resume the same tool twice")
        try await wait { assistant.userQuestions.values.contains { $0.id != first.id && $0.state == .pending } }
        let second = assistant.userQuestions.values.first { $0.id != first.id && $0.state == .pending }!
        check(assistant.userQuestions[first.id]?.state == .answered && assistant.userQuestions[first.id]?.response == "fixture-button", "\(api.rawValue) button results preserve the option value rather than its display label")
        check(assistant.answerQuestion(second.id, text: "custom-answer"), "\(api.rawValue) a text-only question accepts the user's custom answer")
        try await wait { !assistant.thinking.contains(session.id) }
        check(requests.count == 3 && history(requests[1]).contains("fixture-button") && history(requests[2]).contains("custom-answer"), "\(api.rawValue) both answers reach the next model request through native tool results")
        check(requests.allSatisfy { $0.allowsUserInteraction && !$0.allowsCommandControl } && session.blocks.allSatisfy(\.isAI) && session.agentOwner == nil, "\(api.rawValue) generic questions remain available with context disabled and never gain terminal control")
        check(!assistant.answerQuestion(second.id, text: "stale") && !assistant.answerQuestion(UUID(), text: "unknown"), "\(api.rawValue) resolved and nonexistent question IDs reject stale submissions")
    }

    private static func cancellation(check: (Bool, String) -> Void) async throws {
        for action in ["cancel", "close", "context-off"] {
            let suite = "EchoTerm.UserQuestionCancellation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
            preferences.quickIntents = false; preferences.assistantMode = .answer
            let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
            defer { session.close() }
            var requests = 0
            let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in
                requests += 1
                return try toolReply(calls: [("ask_user", question("Waiting for a reply", options: [], custom: true))])
            }
            defer { assistant.cancel(session: session) }
            assistant.ask("Cancellation fixture", session: session)
            try await wait { assistant.userQuestions.values.contains { $0.state == .pending } }
            let id = assistant.userQuestions.values.first { $0.state == .pending }!.id
            if action == "cancel" { assistant.cancel(session: session) }
            else if action == "close" { assistant.close(session: session); session.close() }
            else { preferences.shareContext = false }
            try await wait { !assistant.thinking.contains(session.id) && !assistant.canAnswerQuestion(id) }
            check(assistant.userQuestions[id].map { $0.state != .pending } ?? true, "\(action) retires a pending user question")
            check(requests == 1 && !assistant.answerQuestion(id, text: "too late") && session.agentOwner == nil, "\(action) cancels the suspended tool without starting a continuation or accepting a late answer")
        }
    }

    private static func invalidRequests(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.InvalidUserQuestions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        let malformed: [(String, [String: Any])] = [
            ("an empty question", question("", options: [], custom: true)),
            ("a non-array options field", ["question": "Invalid", "options": "wrong", "allow_custom_input": true, "command_id": ""]),
            ("an unknown field", ["question": "Invalid", "options": [], "allow_custom_input": true, "command_id": "", "unexpected": "field"]),
            ("a nonexistent command target", question("Missing command", options: [], custom: true, commandID: UUID().uuidString))
        ]
        for (label, args) in malformed {
            let before = session.blocks.filter { !$0.isAI }.count
            var requests = 0
            let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in
                requests += 1
                return try toolReply(calls: [("ask_user", args)])
            }
            defer { assistant.cancel(session: session) }
            assistant.ask("Invalid request fixture", session: session)
            try await wait { !assistant.thinking.contains(session.id) }
            check(requests == 1 && assistant.userQuestions.values.allSatisfy { $0.state != .pending } && assistant.activity(for: session) == .attention, "ask_user rejects \(label) before suspending for input")
            check(session.blocks.filter { !$0.isAI }.count == before && !session.running, "Rejecting \(label) leaves the real terminal untouched")
        }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-question-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let marker = scratch.appendingPathComponent("must-not-be-created")
        let before = session.blocks.filter { !$0.isAI }.count
        let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in
            try toolReply(calls: [
                ("execute_command", ["command": "touch \(ShellWords.quote(marker.path))", "explanation": "Mixed-batch rejection fixture", "risk": "write"]),
                ("ask_user", question("Choose before executing", options: [("Continue", "yes")], custom: false))
            ])
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Mixed batch fixture", session: session)
        try await wait { !assistant.thinking.contains(session.id) }
        check(!FileManager.default.fileExists(atPath: marker.path) && session.blocks.filter { !$0.isAI }.count == before && assistant.userQuestions.values.allSatisfy { $0.state != .pending }, "A mixed new-command/question batch is rejected before its first command has side effects")
    }

    private static func terminalQuestions(shell: String, check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.TerminalQuestions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous
        preferences.agentStepLimit = 1; preferences.commandTimeout = 1
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: shell)
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        let command = "printf 'first-choice: '; IFS= read -r echo_fixture_first; printf '\\nsecond-choice: '; IFS= read -r echo_fixture_second; printf '\\nINPUTS:%s|%s\\n' \"$echo_fixture_first\" \"$echo_fixture_second\""
        let custom = "custom 中文 $(printf should-stay-literal)"
        var requests: [AIRequestContext] = [], commandID: UUID?
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            switch requests.count {
            case 1:
                return try toolReply(calls: [("execute_command", ["command": command, "explanation": "Real PTY question fixture", "risk": "read", "interactive": true])])
            case 2:
                guard let running = session.runningBlockID else { throw AIError.message("Interactive fixture did not return a running command") }
                commandID = running
                return try toolReply(calls: [("ask_user", question("Choose the first terminal input", options: [("First", "alpha"), ("Second", "beta")], custom: false, commandID: running.uuidString))])
            case 3:
                try await wait { session.liveOutput.contains("second-choice:") || !session.running }
                return try toolReply(calls: [("ask_user", question("Enter the second terminal input", options: [], custom: true, commandID: commandID!.uuidString))])
            case 4:
                return try toolReply(calls: [("wait_command", ["command_id": commandID!.uuidString])])
            default: return .init(text: "Both terminal inputs completed")
            }
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Complete the two interactive prompts", session: session)
        try await wait { assistant.userQuestions.values.contains { $0.state == .pending } }
        let first = assistant.userQuestions.values.first { $0.state == .pending }!
        // This is a deliberately simulated human delay, longer than the execution
        // timeout; assertions below observe state rather than a timer firing order.
        try await Task.sleep(nanoseconds: 1_250_000_000)
        check(session.running && assistant.canAnswerQuestion(first.id), "\(shell) time waiting for a human answer is excluded from the command execution timeout")
        check(assistant.answerQuestion(first.id, optionID: "option-2"), "\(shell) a button sends its value to the original interactive command")
        try await wait { assistant.userQuestions.values.contains { $0.id != first.id && $0.state == .pending } }
        let second = assistant.userQuestions.values.first { $0.id != first.id && $0.state == .pending }!
        check(!assistant.answerQuestion(first.id, optionID: "option-1") && assistant.answerQuestion(second.id, text: custom), "\(shell) a successive prompt accepts custom Unicode text while rejecting the previous prompt's button")
        try await wait { !assistant.thinking.contains(session.id) && !session.running }
        let blocks = session.blocks.filter { !$0.isAI }
        check(blocks.count == 1 && blocks[0].id == commandID && blocks[0].exitCode == 0 && blocks[0].output.contains("INPUTS:beta|\(custom)"), "\(shell) both inputs complete the same real command without evaluating input as shell syntax")
        check(requests.count == 5 && requests[1].allowsCommandControl && requests[2].allowsCommandControl && requests[1].allowsUserInteraction && requests[2].allowsUserInteraction, "\(shell) the last allowed command retains input and wait tools after the start-command budget is exhausted")
        check(session.agentOwner == nil && assistant.userQuestions.values.allSatisfy { $0.state == .answered } && assistant.canStartBlock(in: session), "\(shell) command completion releases ownership and leaves no unresolved question")
    }

    private static func completedCommandInvalidatesQuestion(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.CompletedQuestionTarget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-question-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gate = scratch.appendingPathComponent("finish-command")
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        let command = "printf 'question-target-running'; while [ ! -f \(ShellWords.quote(gate.path)) ]; do sleep 0.05; done; printf '\\ncompleted-without-input\\n'"
        var requests = 0
        let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in
            requests += 1
            if requests == 1 { return try toolReply(calls: [("execute_command", ["command": command, "explanation": "Command completion race fixture", "risk": "read", "interactive": true])]) }
            if requests == 2 {
                guard let id = session.runningBlockID else { throw AIError.message("Completion fixture has no active command") }
                return try toolReply(calls: [("ask_user", question("Input for the command", options: [], custom: true, commandID: id.uuidString))])
            }
            return .init(text: "The command finished without an answer")
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Question target completion fixture", session: session)
        try await wait { assistant.userQuestions.values.contains { $0.state == .pending } }
        let id = assistant.userQuestions.values.first { $0.state == .pending }!.id
        try "finish".write(to: gate, atomically: true, encoding: .utf8)
        try await wait { !session.running && !assistant.thinking.contains(session.id) && !assistant.canAnswerQuestion(id) }
        check(assistant.userQuestions[id].map { $0.state != .pending && $0.state != .answered } ?? true, "A command finishing before its answer invalidates the attached question and releases its waiter")
        session.draft = "printf 'manual-command-ok\\n'"; session.execute()
        check(!assistant.answerQuestion(id, text: "printf ERRANT_INPUT"), "An expired command question cannot send input into a later manual command")
        try await wait { !session.running }
        check(session.blocks.last?.output.contains("manual-command-ok") == true && session.blocks.last?.output.contains("ERRANT_INPUT") == false && session.blocks.last?.exitCode == 0, "A stale answer leaves the replacement shell command and output intact")
    }

    private static func manualInputRetiresQuestion(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.ManualQuestionInput.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        let command = "printf 'manual-first: '; IFS= read -r echo_manual_first; printf '\\nmanual-second: '; IFS= read -r echo_manual_second; printf '\\nMANUAL:%s|%s\\n' \"$echo_manual_first\" \"$echo_manual_second\""
        let manualValue = "manual-value-not-replayed"
        var requests: [AIRequestContext] = [], commandID: UUID?
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            switch requests.count {
            case 1:
                return try toolReply(calls: [("execute_command", ["command": command, "explanation": "Manual input retires a pending card", "risk": "read", "interactive": true])])
            case 2:
                guard let id = session.runningBlockID else { throw AIError.message("Manual-input fixture has no running command") }
                commandID = id
                return try toolReply(calls: [("ask_user", question("Answer the first prompt", options: [("Old answer", "stale-first-answer")], custom: true, commandID: id.uuidString))])
            case 3:
                try await wait { session.liveOutput.contains("manual-second:") || !session.running }
                return try toolReply(calls: [("ask_user", question("Answer the second prompt", options: [], custom: true, commandID: commandID!.uuidString))])
            case 4:
                return try toolReply(calls: [("wait_command", ["command_id": commandID!.uuidString])])
            default: return .init(text: "Manual input and card input completed")
            }
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Use the manual form for the first prompt", session: session)
        try await wait { assistant.userQuestions.values.contains { $0.state == .pending } }
        let first = assistant.userQuestions.values.first { $0.state == .pending }!
        check(!assistant.sendCommandInput("wrong-target", session: session, expectedBlockID: UUID()), "The manual input route rejects a different command UUID before sending bytes")
        check(assistant.sendCommandInput(manualValue, session: session, expectedBlockID: commandID!), "The manual input route can answer the original command while its AI card is pending")
        check(!assistant.canAnswerQuestion(first.id) && assistant.userQuestions[first.id]?.state == .answered, "Manual input immediately retires the original pending question")
        try await wait { assistant.userQuestions.values.contains { $0.id != first.id && $0.state == .pending } }
        let second = assistant.userQuestions.values.first { $0.id != first.id && $0.state == .pending }!
        let content = requests[2].messages.last(where: { $0["role"] as? String == "tool" })?["content"] as? String ?? ""
        let result = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any]
        check(result?["status"] as? String == "manual_input" && result?["answer_omitted"] as? Bool == true && result?["sent_to_terminal"] as? Bool == true && result?["answer"] == nil && !history(requests[2]).contains(manualValue), "Manual input resumes the model once with its status while omitting the submitted value")
        check(assistant.userQuestions[first.id]?.response != manualValue && !assistant.answerQuestion(first.id, optionID: "option-1"), "The old card neither records raw manual input nor sends its stale answer into the second prompt")
        check(assistant.answerQuestion(second.id, text: "second-answer"), "A new question can answer the next prompt on the same command")
        try await wait { !assistant.thinking.contains(session.id) && !session.running }
        let block = session.blocks.first { $0.id == commandID }
        check(requests.count == 5 && block?.exitCode == 0 && block?.output.contains("MANUAL:\(manualValue)|second-answer") == true && block?.output.contains("stale-first-answer") == false, "Manual and card submissions advance two real prompts exactly once without stale input")
    }

    private static func timeoutDuringStalledTransport(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.StalledTransportTimeout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous
        preferences.commandTimeout = 2
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        // The child and its sleeps inherit an ignored SIGINT. Closing this test's
        // own PTY later sends SIGHUP; no unrelated process is signalled.
        let child = "trap '' INT; printf 'watchdog-ignore-int-ready\\n'; while :; do sleep 1; done"
        let command = "/bin/sh -c " + ShellWords.quote(child)
        var requests = 0, stalled = false, cancelled = false
        let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in
            requests += 1
            if requests == 1 {
                return try toolReply(calls: [("execute_command", ["command": command, "explanation": "Independent timeout watchdog fixture", "risk": "read", "interactive": true])])
            }
            stalled = true
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { cancelled = true; throw error }
            return .init(text: "Unexpected stalled transport completion")
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Verify a timeout while the model is stalled", session: session)
        try await wait { stalled && session.liveOutput.contains("watchdog-ignore-int-ready") }
        check(session.running && session.agentOwner != nil, "The timeout fixture has an owned INT-ignoring command while the next model request is suspended")
        try await wait(attempts: 600) { cancelled && !assistant.thinking.contains(session.id) }
        check(requests == 2 && session.running && session.agentOwner == nil && assistant.activity(for: session) == .attention, "The independent timeout watchdog cancels a stalled model request and releases the still-running command after its interrupt grace")
        check(assistant.messages(for: session).last?.status.contains("手动接管") == true && assistant.messages(for: session).last?.isStreaming == false && assistant.messages(for: session).flatMap(\.steps).contains { $0.status == "需手动接管" }, "Timeout handover preserves an attention status and retires the command step without false success")
        session.close()
        try await wait { !session.terminal.process.running && session.terminal.process.childfd == -1 }
        check(!session.terminal.process.running && session.terminal.process.childfd == -1, "Closing the watchdog fixture reaps its own shell and closes its PTY after handover")
    }

    private static func providerStore(_ defaults: UserDefaults, api: APIProtocol = .chatCompletions) -> ProviderStore {
        let providers = ProviderStore(defaults: defaults)
        providers.configurations = [.init(id: "user-interaction-fixture", name: "fixture", endpoint: "http://localhost/v1", model: "fixture", apiProtocol: api)]
        providers.selectedID = "user-interaction-fixture"
        return providers
    }

    private static func question(_ title: String, options: [(String, String)], custom: Bool, commandID: String = "") -> [String: Any] {
        ["question": title, "options": options.map { ["label": $0.0, "value": $0.1] }, "allow_custom_input": custom, "command_id": commandID]
    }

    private static func toolReply(api: APIProtocol = .chatCompletions, calls: [(String, [String: Any])]) throws -> AIReply {
        let tools = try calls.map { name, arguments -> (String, String, String, [String: Any]) in
            let json = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            return (UUID().uuidString, name, String(decoding: json, as: UTF8.self), arguments)
        }
        let root: [String: Any]
        switch api {
        case .responses:
            root = ["status": "completed", "output": tools.map { ["type": "function_call", "call_id": $0.0, "name": $0.1, "arguments": $0.2] }]
        case .chatCompletions:
            root = ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "", "tool_calls": tools.map { ["id": $0.0, "type": "function", "function": ["name": $0.1, "arguments": $0.2]] }]]]]
        case .anthropic:
            root = ["stop_reason": "tool_use", "content": tools.map { ["type": "tool_use", "id": $0.0, "name": $0.1, "input": $0.3] }]
        }
        return try AIClient.parse(JSONSerialization.data(withJSONObject: root), apiProtocol: api)
    }

    private static func history(_ request: AIRequestContext) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: request.messages, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    private static func wait(attempts: Int = 400, _ predicate: () -> Bool) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw AIError.message("User interaction fixture timeout")
    }
}
#endif
