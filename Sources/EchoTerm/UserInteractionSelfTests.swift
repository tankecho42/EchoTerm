#if DEBUG
import AppKit
import Foundation

@MainActor enum UserInteractionSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        for api in APIProtocol.allCases { try await genericQuestions(api: api, check: check) }
        try await cancellation(check: check)
        try await invalidRequests(check: check)
        for shell in ["/bin/zsh", "/bin/bash"] { try await terminalQuestions(shell: shell, check: check) }
        try await completedCommandInvalidatesQuestion(check: check)
        try await manualInputRetiresQuestion(check: check)
        for shell in ["/bin/zsh", "/bin/bash"] { try await nativeKeyboardRetiresQuestion(shell: shell, check: check) }
        try await lateQuestionAfterNativeInput(check: check)
        try await nativeAndPresetByteBoundaries(check: check)
        try await tuiEntryPausesDeadline(check: check)
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
        // Initial interactive polling already consumes ~0.8 s. Keep ordinary
        // execution margin for PTY scheduling while still waiting longer than
        // the entire timeout to prove the human-answer pause below.
        preferences.agentStepLimit = 1; preferences.commandTimeout = 2
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
        try await Task.sleep(nanoseconds: 2_250_000_000)
        check(session.running && assistant.canAnswerQuestion(first.id), "\(shell) time waiting for a human answer is excluded from the command execution timeout")
        check(assistant.answerQuestion(first.id, optionID: "option-2"), "\(shell) a button sends its value to the original interactive command")
        try await wait { assistant.userQuestions.values.contains { $0.id != first.id && $0.state == .pending } }
        let second = assistant.userQuestions.values.first { $0.id != first.id && $0.state == .pending }!
        check(!assistant.answerQuestion(first.id, optionID: "option-1") && assistant.answerQuestion(second.id, text: custom), "\(shell) a successive prompt accepts custom Unicode text while rejecting the previous prompt's button")
        try await wait { !assistant.thinking.contains(session.id) && !session.running }
        let blocks = session.blocks.filter { !$0.isAI }
        let completedAsExpected = blocks.count == 1 && blocks[0].id == commandID && blocks[0].exitCode == 0 && blocks[0].output.contains("INPUTS:beta|\(custom)")
        if !completedAsExpected {
            // Every byte below belongs to this disposable, credential-free
            // fixture. Record failures only; never log production session data.
            let toolStatuses: [[String: Any]] = requests.flatMap { request in
                request.messages.compactMap { message -> [String: Any]? in
                    guard message["role"] as? String == "tool", let text = message["content"] as? String,
                          let result = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
                    var status: [String: Any] = [:]
                    for field in ["status", "running", "timed_out", "exit_code", "command_id"] { if let value = result[field] { status[field] = value } }
                    return status
                }
            }
            let details: [String: Any] = ["shell": shell, "expected_command_id": commandID?.uuidString ?? "missing",
                "running": session.running, "request_count": requests.count,
                "blocks": blocks.map { ["id": $0.id.uuidString, "exit_code": $0.exitCode as Any? ?? NSNull(), "finished": $0.finishedAt != nil,
                                        "output_tail": String($0.output.suffix(2000))] as [String: Any] },
                "assistant_statuses": assistant.messages(for: session).map(\.status), "tool_statuses": toolStatuses]
            print("TERMINAL-QUESTIONS-FIXTURE-FAIL " + BlockTools.json(details))
        }
        check(completedAsExpected, "\(shell) both inputs complete the same real command without evaluating input as shell syntax")
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

    private static func nativeKeyboardRetiresQuestion(shell: String, check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.NativeOwnedQuestion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous; preferences.commandTimeout = 1
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: shell)
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        let host = NativeTerminalTestHost(session: session, preferences: preferences); defer { host.close() }
        try await wait { session.ready }
        let command = "stty -echo; printf 'native-first: '; IFS= read -r native_first; printf '\\nnative-second: '; IFS= read -r native_second; stty echo; printf '\\nNATIVE-DONE\\n'"
        let firstValue = "private-first-$(must-remain-literal)", secondValue = "私有输入 second"
        var requests: [AIRequestContext] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            if requests.count == 1 { return try toolReply(calls: [("execute_command", ["command": command, "explanation": "Native AppKit stdin fixture", "risk": "read", "interactive": true])]) }
            if requests.count == 2 {
                guard let id = session.runningBlockID else { throw AIError.message("Native fixture has no running command") }
                return try toolReply(calls: [("ask_user", question("Optional first answer", options: [("Old answer", "stale-native-answer")], custom: true, commandID: id.uuidString))])
            }
            return .init(text: "Native keyboard completed the command")
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Use native keyboard for this command", session: session)
        try await wait { assistant.userQuestions.values.contains { $0.state == .pending } && session.terminal.keyboardFocusAllowed }
        let pending = assistant.userQuestions.values.first { $0.state == .pending }!
        let id = pending.spec.commandID!
        check(session.nativeInputRevision == 0 && !session.nativeControlActive,
              "\(shell) command payload and startup replies do not activate the native-input lease")
        check(host.window.makeFirstResponder(session.terminal), "\(shell) an AI-owned y/n-style command accepts a native first responder")
        NativeTerminalTestDriver.insert(firstValue, into: session.terminal)
        try await wait { !assistant.canAnswerQuestion(pending.id) }
        check(session.nativeInputRevision > 0 && session.nativeControlActive && assistant.userQuestions[pending.id]?.state == .answered,
              "\(shell) real AppKit insertText activates native control and retires the pending card on its first bytes")
        check(!assistant.answerQuestion(pending.id, optionID: "option-1") && assistant.userQuestions[pending.id]?.response != firstValue,
              "\(shell) retired cards cannot duplicate native input or retain its private text")
        try await Task.sleep(nanoseconds: 1_250_000_000)
        check(session.running && requests.count == 2, "\(shell) first native input pauses execution deadlines and AI transport while the person is still typing")
        NativeTerminalTestDriver.enter(session.terminal)
        try await wait { session.liveOutput.contains("native-second:") }
        NativeTerminalTestDriver.insert(secondValue, into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
        try await wait { !session.running && !assistant.thinking.contains(session.id) }
        check(session.blocks.first { $0.id == id }?.exitCode == 0 && requests.count == 3,
              "\(shell) native keyboard answers both prompts in the original AI-owned command and resumes AI once after exit")
        check(assistant.userQuestions.count == 1 && requests.allSatisfy { !history($0).contains(firstValue) && !history($0).contains(secondValue) },
              "\(shell) native input creates no replacement card and its private bytes are absent from model history")
    }

    private static func lateQuestionAfterNativeInput(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.LateNativeQuestion.\(UUID().uuidString)", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous; preferences.commandTimeout = 1
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        let host = NativeTerminalTestHost(session: session, preferences: preferences); defer { host.close() }
        try await wait { session.ready }
        var requests: [AIRequestContext] = [], captured = false, releaseReply = false, returned = false
        let command = "stty -echo; printf 'late-first: '; IFS= read -r late_first; printf '\\nlate-second: '; IFS= read -r late_second; stty echo; printf '\\nLATE-DONE\\n'"
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            if requests.count == 1 { return try toolReply(calls: [("execute_command", ["command": command, "explanation": "Stale in-flight question fixture", "risk": "read", "interactive": true])]) }
            if requests.count == 2 {
                let id = session.runningBlockID!; captured = true
                while !releaseReply { try await Task.sleep(nanoseconds: 20_000_000) }
                returned = true
                return try toolReply(calls: [("ask_user", question("An outdated question for the same command", options: [("Outdated", "wrong-answer")], custom: false, commandID: id.uuidString))])
            }
            return .init(text: "Late question suppressed")
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Native input races a slow model", session: session)
        try await wait { captured && session.terminal.keyboardFocusAllowed }
        NativeTerminalTestDriver.insert("late-private-first", into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
        try await wait { session.liveOutput.contains("late-second:") }
        releaseReply = true; try await wait { returned }
        try await Task.sleep(nanoseconds: 1_250_000_000)
        check(session.running && session.nativeControlActive && requests.count == 2 && assistant.userQuestions.values.allSatisfy { $0.state != .pending },
              "A late ask_user for the same command cannot resurrect a card, resume AI polling or time out native interaction")
        NativeTerminalTestDriver.insert("late-private-second", into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
        try await wait { !session.running && !assistant.thinking.contains(session.id) }
        check(requests.count == 3 && requests.allSatisfy { !history($0).contains("late-private-first") && !history($0).contains("late-private-second") },
              "A stale model question resumes only after original command completion without replaying native answer bytes")
    }

    private static func nativeAndPresetByteBoundaries(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.NativeByteBoundaries.\(UUID().uuidString)", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous; preferences.commandTimeout = 1
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-native-bytes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let captured = root.appendingPathComponent("keys.bin"), response = root.appendingPathComponent("device-response.bin")
        let expected = Array("\u{1b}[A\u{1b}[B\u{1b}[D\u{1b}[C\t\u{1b}\r\u{3}\u{3}".utf8)
        let script = """
        import os,select,sys,termios,tty
        old=termios.tcgetattr(0)
        try:
            tty.setraw(0)
            os.write(1,b'\\x1b[?1l\\x1b[5n')
            reply=b''
            while len(reply)<4: reply+=os.read(0,4-len(reply))
            open(\(String(reflecting: response.path)),'wb').write(reply)
            os.write(1,b'RAW-READY')
            data=b''
            while len(data)<\(expected.count): data+=os.read(0,\(expected.count)-len(data))
            if select.select([0],[],[],0.15)[0]: data+=os.read(0,4096)
            open(\(String(reflecting: captured.path)),'wb').write(data)
        finally:
            termios.tcsetattr(0,termios.TCSANOW,old)
        print('RAW-DONE',flush=True)
        """
        let session = TerminalSession(directory: root.path, loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        let host = NativeTerminalTestHost(session: session, preferences: preferences); defer { host.close() }
        try await wait { session.ready }
        var requests: [AIRequestContext] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            if requests.count == 1 { return try toolReply(calls: [("execute_command", ["command": "/usr/bin/python3 -u -c " + ShellWords.quote(script), "explanation": "Capture exact native and preset bytes", "risk": "read", "interactive": true])]) }
            return .init(text: "Exact key bytes completed")
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Capture native keys and optional presets", session: session)
        try await wait { session.liveOutput.contains("RAW-READY") && FileManager.default.fileExists(atPath: response.path) }
        let blockID = session.runningBlockID!
        check((try? Data(contentsOf: response)) == Data("\u{1b}[0n".utf8) && session.nativeInputRevision == 0 && !session.nativeControlActive,
              "Automatic terminal device replies are not mistaken for native keyboard input or deadline interaction")
        check(host.window.makeFirstResponder(session.terminal) && host.window.isKeyWindow,
              "The AppKit component dispatcher has a terminal first responder under explicit simulated key-window eligibility")
        let revisionBeforeIneligibleWindow = session.nativeInputRevision
        host.window.simulatedKeyEligibility = false
        NativeTerminalTestDriver.insert("must-not-reach-raw-reader", into: session.terminal)
        let blockedWindowKey = NativeTerminalTestDriver.key("\u{f701}", code: 125, modifiers: [.function, .numericPad], into: session.terminal)
        check(blockedWindowKey && session.nativeInputRevision == revisionBeforeIneligibleWindow,
              "A non-key component window suppresses text and arrow bytes without weakening the production eligibility guard")
        host.window.simulatedKeyEligibility = true
        let revisionBeforeShortcuts = session.nativeInputRevision
        let menu = NativeTerminalTestMenu(); defer { menu.restore() }
        let commandPeriod = NativeTerminalTestDriver.key(".", code: 47, modifiers: .command, into: session.terminal)
        let commandComma = NativeTerminalTestDriver.key(",", code: 43, modifiers: .command, into: session.terminal)
        check(commandPeriod && commandComma && menu.periodInvocations == 1 && menu.commaInvocations == 1
              && session.nativeInputRevision == revisionBeforeShortcuts,
              "Recognized Command-period and Command-comma invoke isolated menu actions exactly once without native stdin")
        session.terminal.nativeInputAllowed = false
        let blockedCommandControlC = NativeTerminalTestDriver.key("\u{3}", code: 8, modifiers: [.command, .control], unmodified: "c", into: session.terminal)
        check(blockedCommandControlC && session.nativeInputRevision == revisionBeforeShortcuts,
              "An unknown Command-Control-C cannot bypass a disabled native-input gate through inherited SwiftTerm fallback")
        session.terminal.nativeInputAllowed = true
        host.window.makeFirstResponder(host.field)
        let wrongResponder = NativeTerminalTestDriver.key("\u{f701}", code: 125, modifiers: [.function, .numericPad], into: session.terminal)
        check(!wrongResponder && session.nativeInputRevision == revisionBeforeShortcuts,
              "A window-scoped terminal dispatcher cannot capture keys intended for another input's field editor")
        host.window.makeFirstResponder(session.terminal)
        check(!assistant.sendCommandKey(.enter, session: session, expectedBlockID: UUID()), "Optional raw presets reject a different command UUID before writing bytes")
        check(assistant.sendCommandKey(.up, session: session, expectedBlockID: blockID), "An explicitly clicked Up preset targets the original command")
        NativeTerminalTestDriver.down(session.terminal)
        check(assistant.sendCommandKey(.left, session: session, expectedBlockID: blockID)
              && assistant.sendCommandKey(.right, session: session, expectedBlockID: blockID)
              && assistant.sendCommandKey(.tab, session: session, expectedBlockID: blockID)
              && assistant.sendCommandKey(.escape, session: session, expectedBlockID: blockID)
              && assistant.sendCommandKey(.enter, session: session, expectedBlockID: blockID), "Explicit raw presets send arrows, Tab, Escape and Return through the bound original command")
        NativeTerminalTestDriver.controlC(session.terminal)
        let revisionBeforeUnknownShortcut = session.nativeInputRevision
        let unknownCommandControlC = NativeTerminalTestDriver.key("\u{3}", code: 8, modifiers: [.command, .control], unmodified: "c", into: session.terminal)
        check(unknownCommandControlC && session.nativeInputRevision > revisionBeforeUnknownShortcut,
              "An eligible unknown Command-Control-C fallback retains native-input provenance")
        try await wait { !session.running && !assistant.thinking.contains(session.id) && FileManager.default.fileExists(atPath: captured.path) }
        check((try? Data(contentsOf: captured)) == Data(expected), "AppKit arrows, native Ctrl-C and unknown Command-Control-C preserve exactly one payload each with no extra Return")
        check(session.blocks.first { $0.id == blockID }?.exitCode == 0 && requests.count == 2,
              "Native Ctrl-C is forwarded once to a raw-mode program without separately cancelling its AI task")
        check(!assistant.sendCommandKey(.enter, session: session, expectedBlockID: blockID), "Raw presets reject a command after it has exited")
    }

    private static func tuiEntryPausesDeadline(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.NativeTUIDeadline.\(UUID().uuidString)", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = providerStore(defaults)
        preferences.quickIntents = false; preferences.assistantMode = .autonomous; preferences.commandTimeout = 1
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/zsh")
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        let host = NativeTerminalTestHost(session: session, preferences: preferences); defer { host.close() }
        try await wait { session.ready }
        let script = """
        import os,termios,tty
        old=termios.tcgetattr(0)
        try:
            tty.setraw(0)
            os.write(1,b'\\x1b[?1049hTUI-LEASE-READY')
            os.read(0,1)
        finally:
            os.write(1,b'\\x1b[?1049l')
            termios.tcsetattr(0,termios.TCSANOW,old)
        print('TUI-LEASE-DONE',flush=True)
        """
        var requests = 0
        let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in
            requests += 1
            if requests == 1 { return try toolReply(calls: [("execute_command", ["command": "/usr/bin/python3 -u -c " + ShellWords.quote(script), "explanation": "Alternate-screen pause before any typing", "risk": "read", "interactive": true])]) }
            return .init(text: "TUI completed")
        }
        defer { assistant.cancel(session: session) }
        assistant.ask("Use the TUI without racing its command deadline", session: session)
        try await wait { session.alternateScreen && session.terminal.keyboardFocusAllowed }
        try await Task.sleep(nanoseconds: 1_250_000_000)
        check(session.running && session.nativeInputRevision == 0 && requests == 1,
              "Entering an alternate-screen TUI pauses the execution deadline and AI polling before the first native keystroke")
        NativeTerminalTestDriver.insert("x", into: session.terminal)
        try await wait { !session.running && !assistant.thinking.contains(session.id) }
        check(requests == 2 && session.blocks.last(where: { !$0.isAI })?.exitCode == 0,
              "The TUI accepts native raw input without requiring Return and AI resumes only after its actual exit")
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
