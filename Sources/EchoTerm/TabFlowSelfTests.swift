#if DEBUG
import Foundation

@MainActor enum TabFlowSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.TabFlow.\(UUID().uuidString)", defaults: UserDefaults
        defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        providers.configurations = [.init(id: "tab-fixture", name: "fixture", endpoint: "http://localhost/v1", model: "primary", apiProtocol: .chatCompletions, quickModel: "fast")]; providers.selectedID = "tab-fixture"
        preferences.quickIntents = false
        preferences.defaultInputRoute = .shell; preferences.tabNamingPolicy = .command
        let saved = Preferences(defaults: defaults)
        check(saved.defaultInputRoute == .shell && saved.tabNamingPolicy == .command, "New-tab input defaults and naming policy persist independently")
        let workspace = Workspace()
        workspace.preferredInputRoute = { preferences.defaultInputRoute }; workspace.preferredAssistantMode = { preferences.assistantMode }
        workspace.namingPolicy = { preferences.tabNamingPolicy }
        workspace.addTab(directory: "/tmp"); workspace.addTab(directory: "/")
        defer { workspace.closeAll() }
        let firstTab = workspace.tabs[0].id, secondTab = workspace.tabs[1].id
        let first = workspace.tabs[0].root.sessions[0], second = workspace.tabs[1].root.sessions[0]
        workspace.configureTab(firstTab, customTitle: "", input: .assistant, assistant: .autonomous)
        check(first.inputRoute == .assistant && second.inputRoute == .shell && first.defaultAssistantMode == .autonomous && second.defaultAssistantMode == .answer, "Each tab retains independent input and AI defaults")
        first.inputRoute = .shell; first.assistantModeOverride = .answer
        check(first.defaultInputRoute == .assistant && first.defaultAssistantMode == .autonomous && second.inputRoute == .shell, "A block override does not mutate its tab or another tab")
        first.resetInputModes()
        check(first.inputRoute == .assistant && first.assistantModeOverride == nil, "Next block inherits its tab defaults after overrides reset")
        workspace.selectedTabID = firstTab; workspace.split(vertical: true)
        let split = workspace.activeSession!
        check(split.defaultInputRoute == .assistant && split.defaultAssistantMode == .autonomous, "A new split inherits both defaults from its own tab")
        first.blocks = [.init(command: "older-command", directory: "/tmp", startedAt: Date(timeIntervalSince1970: 1), exitCode: 0)]
        split.blocks = [.init(command: "newest-command", directory: "/var", startedAt: Date(timeIntervalSince1970: 2), exitCode: 0)]; split.directory = "/var"
        workspace.refreshTitle(firstTab)
        check(workspace.tabs[0].title == "newest-command", "Command naming follows the newest command across all splits")
        preferences.tabNamingPolicy = .directory; workspace.refreshTitle(firstTab)
        check(workspace.tabs[0].title == "/var", "Path naming follows the session of the latest block, independent of focused pane")
        workspace.configureTab(firstTab, customTitle: "  调试 API  ", input: .assistant, assistant: .answer)
        split.directory = "/usr"; workspace.refreshTitle(firstTab)
        check(workspace.tabs[0].title == "调试 API" && first.defaultAssistantMode == .answer && split.defaultAssistantMode == .answer, "Manual names override automatic updates and default changes reach every split")
        workspace.configureTab(firstTab, customTitle: "", input: .automatic, assistant: .answer)
        check(workspace.tabs[0].title == "/usr", "Clearing a manual name restores the configured automatic rule")

        for api in APIProtocol.allCases {
            var config = providers.selected; config.apiProtocol = api; config.effort = .high
            let request = try AIClient.request(config: config, key: "", messages: [], context: "pwd", mode: .autonomous, streaming: true, purpose: .tabTitle)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            check(body["tools"] == nil && body["stream"] as? Bool == false && body["model"] as? String == "fast" && request.timeoutInterval == 8 && (body["max_tokens"] as? Int ?? body["max_output_tokens"] as? Int) == 96, "\(api.rawValue) titles use a fast bounded request without execution tools")
        }
        check(try QuickTabTitle.parse(.init(text: #"{"title":"排查构建失败"}"#)) == "排查构建失败", "AI session title JSON is parsed as a short label")
        for text in [#"{"title":""}"#, #"{"title":"a\nb"}"#, #"{"title":"abcdefghijklmnopqrstuvwxyz0123456789"}"#, "not-json"] {
            check((try? QuickTabTitle.parse(.init(text: text))) == nil, "Malformed, multiline or oversized AI names are rejected")
        }
        check((try? QuickTabTitle.parse(.init(text: #"{"title":"label"}"#, calls: [.init(id: "bad", name: "execute_command", arguments: "{}")]))) == nil, "AI naming never accepts a tool call")
        preferences.tabNamingPolicy = .intelligence
        var titleRequests = 0, titleContexts: [String] = []
        let coordinator = TabTitleCoordinator(workspace: workspace, preferences: preferences, providers: providers, debounce: 10_000_000, timeout: 120_000_000) { request, _ in
            titleRequests += 1; titleContexts.append(request.context)
            // Only the deadline/cancellation cases need a delayed response.
            // Avoid racing the normal success check against a 120ms deadline
            // after the preceding AppKit event-dispatch tests.
            if request.context.contains("slow-marker") { try? await Task.sleep(nanoseconds: 250_000_000) }
            return .init(text: #"{"title":"检查项目环境"}"#)
        }
        coordinator.refresh(firstTab)
        do { try await wait { workspace.tabs[0].generatedTitle != nil } }
        catch {
            print("TITLE-FIXTURE-DIAGNOSTIC requests=\(titleRequests) error=\(workspace.tabs[0].namingError ?? "none") eligible=\(first.blocks.count)/\(AgentContextBuilder.selectedBlocks(in: first).count),\(split.blocks.count)/\(AgentContextBuilder.selectedBlocks(in: split).count) sharing=\(preferences.shareContext)")
            throw error
        }
        check(workspace.tabs[0].title == "检查项目环境" && titleRequests == 1, "AI naming updates the actual tab label")
        coordinator.refresh(firstTab); try await Task.sleep(nanoseconds: 45_000_000)
        check(titleRequests == 1, "Repeated callbacks with unchanged context do not request another title")
        split.blocks.append(.init(command: "slow-marker", directory: "/", exitCode: 0)); coordinator.refresh(firstTab)
        try await Task.sleep(nanoseconds: 25_000_000)
        workspace.configureTab(firstTab, customTitle: "固定名称", input: .automatic, assistant: .answer)
        try await Task.sleep(nanoseconds: 270_000_000)
        check(workspace.tabs[0].title == "固定名称", "A late naming response cannot overwrite a manual rename")
        workspace.configureTab(firstTab, customTitle: "", input: .automatic, assistant: .answer)
        try await wait { workspace.tabs[0].namingError != nil }
        check(workspace.tabs[0].namingError?.contains("超时") == true && workspace.tabs[0].title == "检查项目环境", "Title requests have a deadline and preserve the last useful name on failure")
        preferences.shareContext = false
        try await Task.sleep(nanoseconds: 10_000_000)
        let before = titleRequests
        split.blocks.append(.init(command: "private-command", directory: "/")); coordinator.refresh(firstTab)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(titleRequests == before, "Context opt-out prevents automatic session naming")
        preferences.shareContext = true; preferences.tabNamingPolicy = .directory
        try await Task.sleep(nanoseconds: 10_000_000)
        let after = titleRequests; coordinator.refresh(firstTab)
        try await Task.sleep(nanoseconds: 30_000_000)
        check(titleRequests == after && workspace.tabs[0].title == "/usr", "Non-AI title policies work locally without model requests")
        check(titleContexts.allSatisfy { $0.count < 5000 }, "Naming context stays bounded and excludes conversation transcripts")
        coordinator.cancel(firstTab); coordinator.cancel(secondTab)
        workspace.closeSession(split.id, force: true)
        check(workspace.tabs[0].title == "/tmp", "Closing the newest split refreshes the tab name from its remaining blocks")

        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready && session.catalogReady }
        session.defaultInputRoute = .assistant; session.defaultAssistantMode = .autonomous
        var round = 0, modes: [AssistantMode] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, update in
            modes.append(request.mode); round += 1
            if round == 1 {
                update(.init(text: "先查看目录。", phase: "正在回答…"))
                return try toolReply(text: "先查看目录。", command: "sleep 0.15; printf 'first-result\\n'", id: "first")
            }
            if round == 2 { return try toolReply(text: "收到结果，再检查一步。", command: "printf 'second-result\\n'", id: "second") }
            return .init(text: "最终结论。")
        }
        session.draft = "检查环境"; assistant.submitInput(session: session)
        try await wait { session.running }
        check(session.blocks.last?.isAI == false && session.blocks.last?.finishedAt == nil && session.blocks.count == 2 && !assistant.canStartBlock(in: session), "A tool command stays last until it completes, without a premature reply or input block")
        session.defaultAssistantMode = .answer
        try await wait { !assistant.thinking.contains(session.id) }
        check(modes.allSatisfy { $0 == .autonomous }, "Changing a tab default does not rewrite the mode of an in-flight task")
        check(session.blocks.map(\.isAI) == [true, false, true, false, true], "Tool-driven conversation is ordered AI → command/result → AI → command/result → AI")
        check(session.blocks[0].output == "先查看目录。" && session.blocks[2].output == "收到结果，再检查一步。" && session.blocks.last?.output == "最终结论。", "Each AI segment retains only its own text instead of accumulating at the top")
        check(session.blocks[1].output.contains("first-result") && session.blocks[3].output.contains("second-result") && session.blocks.last?.exitCode == 0, "Command results and final AI completion stay on their correct blocks")
        check(assistant.messages(for: session).flatMap(\.steps).count == 2 && assistant.messages(for: session).allSatisfy { !$0.isStreaming }, "Segmenting replies retains tool provenance and finishes all streaming segments")
        session.inputRoute = .shell; session.assistantModeOverride = .autonomous; session.draft = "pwd"
        assistant.submitInput(session: session); try await wait { !session.running }
        check(session.inputRoute == .assistant && session.assistantModeOverride == nil, "Successful command submission restores both defaults for the next block")
        var receivedMode: AssistantMode?
        let answering = AssistantStore(providers: providers, preferences: preferences) { request, _ in receivedMode = request.mode; return .init(text: "只回答") }
        session.assistantModeOverride = .answer; session.defaultAssistantMode = .autonomous; session.draft = "只解释"
        answering.submitInput(session: session); try await wait { !answering.thinking.contains(session.id) }
        check(receivedMode == .answer && session.blocks.last?.assistantMode == .answer && answering.mode(for: session) == .autonomous, "A one-block Q&A override is recorded on the reply, then the next block returns to its tab default")
        var batchRound = 0
        let batch = AssistantStore(providers: providers, preferences: preferences) { _, _ in
            batchRound += 1
            if batchRound == 1 {
                var reply = try toolReply(text: "依次执行两条。", command: "printf 'batch-one\\n'", id: "batch-one")
                reply.calls += try toolReply(text: "", command: "printf 'batch-two\\n'", id: "batch-two").calls
                return reply
            }
            return .init(text: "批量调用完成。")
        }
        let beforeBatch = session.blocks.count
        batch.ask("批量工具", session: session); try await wait { !batch.thinking.contains(session.id) }
        check(session.blocks.dropFirst(beforeBatch).map(\.isAI) == [true, false, false, true] && session.blocks.last?.output == "批量调用完成。", "Multiple tools in one reply keep one active assistant segment below all results")
        let stopping = AssistantStore(providers: providers, preferences: preferences) { _, _ in try toolReply(text: "开始等待。", command: "sleep 30", id: "stop-segment") }
        stopping.ask("停止验证", session: session)
        try await wait { session.running }; try await Task.sleep(nanoseconds: 130_000_000)
        stopping.setMode(.answer, session: session)
        try await wait { !session.running }
        check(!stopping.thinking.contains(session.id) && session.blocks.last?.isAI == false && session.blocks.last?.exitCode == 130 && stopping.messages(for: session).last?.status == "已停止" && stopping.canStartBlock(in: session), "Stopping a tool finishes its command before reopening input and marks its originating reply stopped")
        check(stopping.messages(for: session).allSatisfy { !$0.isStreaming && $0.steps.allSatisfy { $0.status != "执行中" } }, "Cancellation retires every open segment and tool status in the run")
        if let endpoint = ProcessInfo.processInfo.environment["ECHOTERM_TEST_API"] {
            for api in APIProtocol.allCases {
                var config = providers.selected; config.endpoint = endpoint; config.apiProtocol = api
                let reply = try await AIClient.send(config: config, key: "", messages: [], context: "pwd", purpose: .tabTitle)
                check(try QuickTabTitle.parse(reply) == "检查终端环境", "\(api.rawValue) actual HTTP session naming returns a validated label")
            }
        }
    }
    private static func toolReply(text: String, command: String, id: String) throws -> AIReply {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["command": command, "explanation": "fixture", "risk": "read"]), as: UTF8.self)
        return .init(text: text, calls: [.init(id: id, name: AIClient.executeTool, arguments: arguments)])
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<350 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw AIError.message("Tab flow fixture timeout")
    }
}
#endif
