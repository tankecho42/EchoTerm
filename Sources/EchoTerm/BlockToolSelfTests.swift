#if DEBUG
import Foundation

@MainActor enum BlockToolSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.BlockTools.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        preferences.quickIntents = false; preferences.assistantMode = .answer; preferences.shareContext = true
        providers.configurations = [.init(id: "block-tools-local", name: "fixture", endpoint: "http://localhost/v1", model: "ui-block-tools", apiProtocol: .chatCompletions)]
        providers.selectedID = "block-tools-local"
        let workspace = Workspace(); workspace.addTab(directory: "/tmp"); workspace.addTab(directory: "/")
        defer { workspace.closeAll() }
        let first = workspace.indexedSessions[0], second = workspace.indexedSessions[1]
        first.blocks = (1...30).map { .init(command: "echo block-\($0)", directory: "/tmp", output: "OUTPUT_ONLY_\($0)", finishedAt: Date(), exitCode: 0) }
        second.blocks = [.init(command: "echo second-session", directory: "/", output: "password=hiddenvalue\n" + String(repeating: "中文🙂分页", count: 5000), finishedAt: Date(), exitCode: 0)]
        first.blocks[0].command = "echo token=confidential"
        let catalog = BlockCatalog(sessions: workspace.indexedSessions, current: first.id)
        check(catalog.overview.contains("Session 2") && catalog.overview.contains("B30") && !catalog.overview.contains("OUTPUT_ONLY") && !catalog.overview.contains("confidential"), "Global overview contains every block beginning and session, redacts secrets, omits outputs")
        check(TimelineLayout.milestone(8) == nil && TimelineLayout.milestone(9) == "10" && TimelineLayout.milestone(19) == "20" && TimelineLayout.milestone(299) == "300", "Persistent timeline milestones use one-based block numbering")
        func perform(_ name: String, _ args: [String: Any], snapshot: BlockCatalog? = nil) -> BlockTools.Result {
            BlockTools.perform(.init(id: UUID().uuidString, name: name, arguments: BlockTools.json(args)), catalog: snapshot ?? BlockCatalog(sessions: workspace.indexedSessions, current: first.id), sessions: workspace.indexedSessions, workspace: workspace)
        }
        let page = perform(BlockTools.read, ["session_index": 2, "block_index": 1, "offset": 0, "limit": 99])
        let pageJSON = try JSONSerialization.jsonObject(with: Data(page.json.utf8)) as! [String: Any]
        let page2 = perform(BlockTools.read, ["session_index": 2, "block_index": 1, "offset": pageJSON["next_offset"]!, "limit": 16000])
        check((pageJSON["content"] as? String)?.count == 99 && !page.json.contains("hiddenvalue") && page2.json.contains("中文🙂"), "Block reads page Unicode content by character and redact before slicing")
        let listing = perform(BlockTools.list, ["session_index": 1, "start_index": 20, "limit": 3])
        check(listing.json.contains("B20") && listing.json.contains("B22") && !listing.json.contains("B23") && listing.json.contains("next_index"), "Paged index refresh returns bounded ranges without output")
        for invalid: [String: Any] in [
            ["session_index": true, "block_index": 1], ["session_index": 1.5, "block_index": 1], ["session_index": -1, "block_index": 1],
            ["session_index": 99, "block_index": 1], ["session_index": 1, "block_index": 999], ["session_index": 1, "block_index": 1, "command": "whoami"]
        ] { check(perform(BlockTools.jump, invalid).json.contains("error"), "Invalid block navigation parameters never resolve a different target") }
        first.draft = "keep draft"; second.draft = "keep second draft"
        let target = first.blocks[9].id
        let jump = perform(BlockTools.jump, ["session_index": 1, "block_index": 10])
        let reveal = first.blockReveal?.id
        _ = perform(BlockTools.jump, ["session_index": 1, "block_index": 10])
        check(jump.json.contains("true") && workspace.activeSession?.id == first.id && first.readingAnchorID == target && first.blockReveal?.id != reveal && first.draft == "keep draft" && second.draft == "keep second draft", "Cross-tab and repeated jumps target the same UUID, renew animation, and preserve drafts")
        first.appendAIBlock(question: "continuation", replyID: UUID(), continuation: true)
        check(first.selectedBlockID == target && first.readingAnchorID == target, "Appending streamed AI continuation preserves the navigated reading position")
        let replyID = first.blocks.last!.assistantReplyID!
        let readAI = BlockTools.perform(.init(id: "read-ai", name: BlockTools.read, arguments: BlockTools.json(["session_index": 1, "block_index": first.blocks.count, "offset": 0, "limit": 16000])), catalog: BlockCatalog(sessions: workspace.indexedSessions, current: first.id), sessions: workspace.indexedSessions, workspace: workspace, conversations: [first.id: [.init(id: replyID, role: "assistant", text: "", steps: [.init(command: "查看 S2 · B1", explanation: "", status: "已读取", kind: .read)])]])
        check(readAI.json.contains("查看 S2 · B1") && readAI.json.contains("已读取"), "Reading an AI block includes its visible tool history as well as response text")
        first.blocks.removeFirst()
        check(perform(BlockTools.jump, ["session_index": 1, "block_index": 10], snapshot: catalog).json.contains("error"), "A pruned/reindexed block is rejected instead of jumping to its old numeric position")
        first.draft = ""; first.resumeInput()
        for api in APIProtocol.allCases {
            var config = providers.selected; config.apiProtocol = api
            let request = try AIClient.request(config: config, key: "", messages: [], context: "overview", mode: .answer, allowsBlockTools: true)
            let data = request.httpBody!, wire = String(decoding: data, as: UTF8.self)
            check(wire.contains(BlockTools.read) && wire.contains(BlockTools.jump) && wire.contains(BlockTools.list) && !wire.contains("\"name\":\"execute_command\""), "\(api.rawValue) Q&A exposes read/navigation tools without Shell execution")
            let fast = try AIClient.request(config: config, key: "", messages: [], context: "", mode: .autonomous, purpose: .intent, allowsBlockTools: true)
            check((try JSONSerialization.jsonObject(with: fast.httpBody!) as? [String: Any])?["tools"] == nil, "\(api.rawValue) fast intent model has no block or command tools")
        }
        var requests: [AIRequestContext] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            switch requests.count {
            case 1: return reply(BlockTools.read, ["session_index": 2, "block_index": 1, "offset": 0, "limit": 100])
            case 2: return reply(BlockTools.jump, ["session_index": 2, "block_index": 1])
            default: return .init(text: "已找到并定位。", usage: .init(input: 10, output: 3))
            }
        }
        assistant.workspace = workspace
        assistant.ask("查找另一个会话中的记录并跳转", session: first)
        try await wait { !assistant.thinking.contains(first.id) }
        let wire = BlockTools.json(["messages": requests.last!.messages])
        check(requests.count == 3 && requests.allSatisfy { $0.mode == .answer && $0.allowsBlockTools } && wire.contains("INPUT") && wire.contains("jumped"), "Q&A completes read → result → jump → result → answer through its actual tool loop")
        check(workspace.activeSession?.id == second.id && second.readingAnchorID == second.blocks.first?.id && !first.running && !second.running && assistant.messages(for: first).last?.roundSummary != nil, "Read/navigation tools switch sessions without running commands and keep round usage on the final reply")
        check(assistant.messages(for: first).flatMap(\.steps).map(\.kind) == [.read, .jump], "Inline tool provenance distinguishes reads and jumps from executed commands")
        requests.removeAll()
        assistant.ask("继续", session: first); try await wait { !assistant.thinking.contains(first.id) }
        check(requests.first?.messages.count == 1 && !requests.first!.context.contains("hiddenvalue"), "New AI turns send only the question and redacted block overview, not entire conversation history")
        preferences.shareContext = false
        var optedOut = false
        let denied = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            optedOut = request.context.isEmpty && !request.allowsBlockTools
            return reply(BlockTools.jump, ["session_index": 1, "block_index": 1])
        }
        let before = first.blockReveal?.id
        denied.ask("navigate", session: first); try await wait { !denied.thinking.contains(first.id) }
        check(optedOut, "Context opt-out removes catalog and block tools from requests")
        check(first.blockReveal?.id == before && denied.messages(for: first).last?.status.contains("不允许") == true, "Unsolicited navigation is locally refused when context sharing is off")
        preferences.shareContext = true
        var budgetCalls = 0
        let bounded = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            budgetCalls += 1
            return request.allowsBlockTools ? reply(BlockTools.list, ["session_index": 1, "start_index": 1, "limit": 1]) : .init(text: "查询完成")
        }
        bounded.ask("budget", session: first); try await wait { !bounded.thinking.contains(first.id) }
        check(budgetCalls == 25 && bounded.messages(for: first).last?.text == "查询完成", "Repeated history lookups stop at their own budget and allow a final answer")
        // Stale focus from another tab cannot invalidate the current tab's active pane.
        workspace.revealSession(second.id); workspace.selectSession(first.id)
        check(workspace.activeSession?.id == second.id, "A stale focus callback cannot select a session outside its active tab")
        if let endpoint = ProcessInfo.processInfo.environment["ECHOTERM_TEST_API"] {
            for api in APIProtocol.allCases {
                var config = providers.selected; config.endpoint = endpoint; config.apiProtocol = api
                providers.configurations = [config]
                let live = AssistantStore(providers: providers, preferences: preferences); live.workspace = workspace
                live.ask("请读取并跳转 Session 2 Block 1", session: first)
                try await wait { !live.thinking.contains(first.id) }
                check(live.messages(for: first).flatMap(\.steps).map(\.kind) == [.read, .jump] && live.messages(for: first).last?.text.contains("已定位") == true && live.messages(for: first).last?.roundSummary?.usage.requests == 3, "\(api.rawValue) HTTP streaming read/jump calls and native tool results complete end to end")
            }
        }
        workspace.revealSession(first.id); workspace.split(vertical: true)
        let split = workspace.activeSession!
        split.blocks = [.init(command: "split target", directory: "/tmp", output: "split result", exitCode: 0)]
        let splitCatalog = BlockCatalog(sessions: workspace.indexedSessions, current: first.id)
        let splitJump = perform(BlockTools.jump, ["session_index": 2, "block_index": 1], snapshot: splitCatalog)
        check(workspace.sessionIndex(split.id) == 2 && workspace.sessionIndex(second.id) == 3 && splitJump.blockID == split.blocks[0].id && workspace.activeSession?.id == split.id, "Session indices include split panes and navigation selects the exact split")
        workspace.closeSession(split.id, force: true)
        check(perform(BlockTools.jump, ["session_index": 2, "block_index": 1], snapshot: splitCatalog).json.contains("error"), "Closing a session during a model request cannot redirect its jump into a surviving tab")

    }
    private static func reply(_ name: String, _ args: [String: Any]) -> AIReply {
        .init(text: "查看历史区块。", calls: [.init(id: UUID().uuidString, name: name, arguments: BlockTools.json(args))], usage: .init(input: 10, output: 3))
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw AIError.message("Block tool fixture timeout")
    }
}
#endif
