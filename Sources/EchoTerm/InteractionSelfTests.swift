#if DEBUG
import Foundation

@MainActor enum InteractionSelfTests {
    static let fixture = #"{"intents":[{"title":"解释结果","question":"帮我解释这条命令的输出。"},{"title":"检查环境","question":"帮我检查相关环境。"}]}"#
    static func run(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.Interaction.test.\(UUID().uuidString)", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        providers.configurations = [.init(id: "test", name: "fixture", endpoint: "http://localhost/v1", model: "glm-4.7", apiProtocol: .chatCompletions, quickModel: "glm-4.7-flash")]
        providers.selectedID = "test"
        let options = try QuickIntent.parse(.init(text: fixture))
        check(options.count == 2 && options[0].title == "解释结果", "Intent JSON creates bounded clickable question options")
        let bad = AIReply(text: fixture, calls: [.init(id: "bad", name: "execute_command", arguments: "{}")])
        check((try? QuickIntent.parse(bad)) == nil, "Intent classification rejects tool calls instead of executing them")
        let tooMany = #"{"intents":[{"title":"a","question":"b"},{"title":"a","question":"b"}]}"#
        check((try? QuickIntent.parse(.init(text: tooMany))) == nil, "Repeated or malformed intent choices are rejected")
        for api in APIProtocol.allCases {
            var config = providers.selected; config.apiProtocol = api; config.effort = .high
            let request = try AIClient.request(config: config, key: "", messages: [], context: "", mode: .autonomous, streaming: true, purpose: .intent)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            check(body["tools"] == nil && body["stream"] as? Bool == false && body["model"] as? String == "glm-4.7-flash" && request.timeoutInterval == 8, "\(api.rawValue) quick requests isolate model, tool permissions, streaming and timeout")
        }
        let quick = providers.selected.fastConfiguration
        check(quick.effort == .off && (quick.reasoningParameters["thinking"] as? [String: String])?["type"] == "disabled" && providers.selected.effort == .automatic, "Quick mode disables reasoning without mutating the primary model settings")
        let a = TerminalSession(directory: "/tmp", loadShellConfig: false), b = TerminalSession(directory: "/", loadShellConfig: false)
        a.usesBlockEditor = true; a.start(); defer { a.close(); b.close() }
        try await wait { a.ready }
        let workspace = Workspace()
        workspace.tabs = [.init(title: "A", root: .leaf(a), activeSessionID: a.id), .init(title: "B", root: .leaf(b), activeSessionID: b.id)]
        workspace.selectedTabID = workspace.tabs[0].id
        workspace.presentAssistant(for: a.id)
        workspace.selectedTabID = workspace.tabs[1].id
        check(workspace.assistantVisible && workspace.assistantSession?.id == a.id, "Conversation stays pinned and visible when switching terminal tabs")
        workspace.presentAssistant(for: b.id, automatic: true)
        check(workspace.assistantSession?.id == a.id, "Another pane's automatic suggestion cannot replace the conversation being read")
        workspace.minimizeAssistant(); workspace.presentAssistant(for: a.id, automatic: true)
        check(!workspace.assistantVisible, "Manual minimization suppresses subsequent automatic presentation")
        workspace.presentAssistant(for: b.id, automatic: true)
        check(!workspace.assistantVisible, "Manual minimization also suppresses automatic bubbles from other tabs")
        workspace.toggleAssistant(session: a)
        check(workspace.assistantVisible && workspace.assistantSession?.id == a.id, "Clicking the companion explicitly restores the minimized conversation")

        var requests: [AIRequestContext] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, update in
            requests.append(request)
            if request.purpose == .intent { try await Task.sleep(nanoseconds: 120_000_000); return .init(text: fixture) }
            try await Task.sleep(nanoseconds: 80_000_000)
            update(.init(text: "正在输出", phase: "正在回答…", activity: .working))
            try await Task.sleep(nanoseconds: 180_000_000)
            return .init(text: "已完成解释")
        }
        a.onExecute = { [weak a, weak assistant] command in if let a { assistant?.didExecute(command, session: a) } }
        a.draft = "printf 'intent-test\\n'"; a.execute()
        check(assistant.activity(for: a) == .thinking && assistant.intentPreviews[a.id]?.loading == true, "Manual command submission immediately starts a thinking expression and one quick judgment")
        try await wait { assistant.intentPreviews[a.id]?.loading == false && !a.running }
        assistant.didExecute("same event", session: a); assistant.didComplete(a.blocks.last!, session: a)
        check(requests.count == 1 && requests[0].purpose == .intent && requests[0].config.model == "glm-4.7-flash" && assistant.messages(for: a).isEmpty, "One user command causes exactly one isolated quick-model request and no chat turn")
        check(assistant.activity(for: a) == .success && a.blocks.count == 1 && assistant.intentPreviews[a.id]?.options.count == 2, "Quick suggestions show completion without adding or executing any command")
        assistant.inputDrafts[a.id] = "unsent text"
        workspace.minimizeAssistant(); workspace.toggleAssistant(session: a)
        check(assistant.inputDrafts[a.id] == "unsent text", "Unsent conversation draft survives minimizing and restoring the panel")
        let option = assistant.intentPreviews[a.id]!.options[0]
        assistant.chooseIntent(option, session: a)
        check(assistant.activity(for: a) == .thinking, "User request starts with the thinking expression")
        try await wait { assistant.activity(for: a) == .working }
        check(assistant.thinking.contains(a.id), "Streaming output changes the expression to working before the request completes")
        try await wait { !assistant.thinking.contains(a.id) }
        check(assistant.activity(for: a) == .success && requests.count == 2 && requests.last?.purpose == .conversation && requests.last?.config.model == "glm-4.7", "Clicking an intent invokes the main model, then transitions to smile and completion check")
        check(assistant.intentPreviews[a.id]?.chosenID == option.id && assistant.messages(for: a).first?.text.contains("对应命令") == true, "Chosen intent records adoption and carries its original source command")
        let count = requests.count
        assistant.chooseIntent(option, session: a)
        check(requests.count == count, "An already-consumed intent does not issue duplicate requests")
        a.blocks.append(.init(command: "ai command", directory: "/tmp", assistantRunID: UUID()))
        assistant.didExecute("ai command", session: a)
        check(requests.count == count, "AI tool commands never recursively trigger the quick classifier")
        preferences.shareContext = false
        a.blocks.append(.init(command: "private", directory: "/tmp")); assistant.didExecute("private", session: a)
        check(requests.count == count, "Context opt-out prevents automatic intent requests")
        preferences.shareContext = true; preferences.quickIntents = false
        a.blocks.append(.init(command: "off", directory: "/tmp")); assistant.didExecute("off", session: a)
        check(requests.count == count, "Quick-intent toggle disables automatic classification independently of chat mode")
        preferences.quickIntents = true
        var slowCount = 0
        let slow = AssistantStore(providers: providers, preferences: preferences, transport: { request, _ in
            slowCount += 1
            if request.purpose == .conversation { throw AIError.message("fixture failure") }
            let command = request.context.hasSuffix("old-command")
            try? await Task.sleep(nanoseconds: command ? 240_000_000 : 60_000_000)
            return .init(text: command ? #"{"intents":[{"title":"old","question":"old question"}]}"# : fixture)
        })
        a.blocks.append(.init(command: "old-command", directory: "/tmp")); slow.didExecute("old-command", session: a)
        try await Task.sleep(nanoseconds: 30_000_000)
        a.blocks.append(.init(command: "new-command", directory: "/tmp")); slow.didExecute("new-command", session: a)
        try await Task.sleep(nanoseconds: 300_000_000)
        check(slowCount == 2 && slow.intentPreviews[a.id]?.command == "new-command" && slow.intentPreviews[a.id]?.options.first?.title == "解释结果", "Late response from a superseded command cannot replace the latest intent")
        slow.ask("failing question", session: a)
        try await wait { !slow.thinking.contains(a.id) }
        check(slow.activity(for: a) == .attention, "A failed model call shows attention instead of a false completion check")
        let timeout = AssistantStore(providers: providers, preferences: preferences, transport: { _, _ in
            try? await Task.sleep(nanoseconds: 350_000_000); return .init(text: fixture)
        }, intentTimeout: 60_000_000)
        a.blocks.append(.init(command: "timeout", directory: "/tmp")); timeout.didExecute("timeout", session: a)
        try await wait { timeout.intentPreviews[a.id]?.loading == false }
        check(timeout.activity(for: a) == .attention && timeout.intentPreviews[a.id]?.error?.contains("超时") == true && timeout.intentPreviews[a.id]?.loading == false, "Quick judgment has an independent deadline and releases its loading state")
        try await Task.sleep(nanoseconds: 300_000_000)
        check(timeout.intentPreviews[a.id]?.options.isEmpty == true, "A timed-out quick response cannot reappear later")
        a.blocks.append(.init(command: "cancel quick", directory: "/tmp")); timeout.didExecute("cancel quick", session: a)
        timeout.cancel(session: a)
        check(timeout.activity(for: a) == .stopped && timeout.intentPreviews[a.id]?.loading == false, "Stopping a quick judgment retains the bubble and shows stopped expression")
        a.blocks.append(.init(command: "close quick", directory: "/tmp")); timeout.didExecute("close quick", session: a)
        timeout.close(session: a)
        check(timeout.intentPreviews[a.id] == nil, "Closing a session cancels and removes its intent preview")
        if let endpoint = ProcessInfo.processInfo.environment["ECHOTERM_TEST_API"] {
            for api in APIProtocol.allCases {
                var config = providers.selected; config.endpoint = endpoint; config.apiProtocol = api
                let reply = try await AIClient.send(config: config, key: "", messages: [["role": "user", "content": "intent fixture"]], context: "pwd", purpose: .intent)
                check(try QuickIntent.parse(reply).count == 2, "\(api.rawValue) actual HTTP quick inference returns clickable intents")
            }
        }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw AIError.message("Interaction fixture timeout")
    }
}
#endif
