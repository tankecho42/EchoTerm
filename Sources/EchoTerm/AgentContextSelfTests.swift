#if DEBUG
import Foundation

@MainActor enum AgentContextSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        try await continuity(check: check)
        try restoredContinuations(check: check)
        try await scopedTools(check: check)
        try boundariesAndDisplay(check: check)
        try budgetsAndRedaction(check: check)
        try await pruningAndFrozenEstimate(check: check)
        try await sharingOff(check: check)
        try await quickIntentScope(check: check)
        try await TabContextSelfTests.run(check: check)
        previewBenchmark()
    }
    private static func fixture(_ name: String) -> (String, UserDefaults, Preferences, ProviderStore) {
        let suite = "EchoTerm.AgentContext.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!, preferences = Preferences(defaults: UserDefaults(suiteName: suite)!)
        preferences.shareContext = true; preferences.quickIntents = false; preferences.assistantMode = .answer
        let providers = ProviderStore(defaults: defaults)
        providers.configurations = [.init(id: "context-local", name: "fixture", endpoint: "http://localhost/v1", model: "context-fixture", apiProtocol: .chatCompletions)]
        providers.selectedID = "context-local"
        return (suite, defaults, preferences, providers)
    }
    private static func shell(_ command: String, output: String = "") -> CommandBlock {
        .init(command: command, directory: "/tmp", output: output, finishedAt: Date(), exitCode: 0)
    }
    private static func ai(_ question: String, answer: String, continuation: Bool = false) -> CommandBlock {
        .init(command: question, directory: "/tmp", output: answer, finishedAt: Date(), exitCode: 0,
              assistantReplyID: UUID(), assistantContinuation: continuation)
    }
    private static func wire(_ messages: [[String: Any]], _ context: String = "") -> String { BlockTools.json(["messages": messages, "context": context]) }
    private static func tool(_ name: String, _ args: [String: Any]) -> AIReply {
        .init(text: "Inspect selected context", calls: [.init(id: UUID().uuidString, name: name, arguments: BlockTools.json(args))])
    }
    private static func continuity(check: (Bool, String) -> Void) async throws {
        let (suite, defaults, preferences, providers) = fixture("continuity")
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        var requests: [AIRequestContext] = []
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            return requests.count == 1
                ? .init(text: "已分析；需要我继续整理下一步方案吗？", suggestions: [.init(command: "printf 'proposal-only'", explanation: "先检查再操作", risk: "read")])
                : .init(text: "收到，继续之前的方案。")
        }
        assistant.ask("完整的原始问题 actual-question-marker", session: session, displayQuestion: "短标题")
        try await wait { !assistant.thinking.contains(session.id) }
        assistant.ask("好的", session: session)
        try await wait { !assistant.thinking.contains(session.id) }
        let second = requests[1], history = wire(second.messages, second.context)
        check(second.messages.count >= 3 && history.contains("需要我继续整理下一步方案吗") && history.contains("proposal-only") && history.contains("先检查再操作"),
              "A real second transport request for 好的 includes the previous assistant offer and visible suggestions")
        check(wire(second.messages).contains("actual-question-marker") && !wire(second.messages).contains("短标题"), "Replay uses the stored actual user question rather than its shortened display title")
        check(second.messages.filter { $0["role"] as? String == "user" && $0["content"] as? String == "好的" }.count == 1 && !second.context.contains("好的"),
              "The new question appears exactly once and is excluded from its own historical catalog")
        for api in APIProtocol.allCases {
            var config = providers.selected; config.apiProtocol = api
            let request = try AIClient.request(config: config, key: "", messages: second.messages, context: second.context, allowsBlockTools: true)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let messages = (body[api == .responses ? "input" : "messages"] as? [[String: Any]]) ?? []
            check(messages.contains { $0["role"] as? String == "assistant" && ($0["content"] as? String)?.contains("需要我继续") == true }
                  && !messages.contains { $0["tool_calls"] != nil || $0["type"] as? String == "function_call" },
                  "\(api.rawValue) accepts plain historical role messages without replaying orphan tool calls")
        }
    }
    private static func restoredContinuations(check: (Bool, String) -> Void) throws {
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.blocks = [ai("恢复的问题", answer: "恢复的初步回答"), shell("printf result", output: "真实命令结果"),
                          ai("继续分析", answer: "恢复的最终回答；要继续吗？", continuation: true)]
        let payload = AgentContextBuilder.build(session: session, sessions: [session], conversations: [], question: "继续", sharing: true)
        let history = wire(payload.messages)
        check(history.contains("恢复的初步回答") && history.contains("真实命令结果") && history.contains("恢复的最终回答") && !history.contains("继续分析"),
              "Restored Blocks replay answers and Shell results without inventing continuation user questions")
        session.contextStartBlockID = session.blocks.last!.id
        let suffix = AgentContextBuilder.build(session: session, sessions: [session], conversations: [], question: "好", sharing: true)
        check(suffix.messages.first?["role"] as? String == "user" && suffix.messages.contains { $0["role"] as? String == "assistant" },
              "A range starting at an assistant continuation receives a protocol-safe historical-data user marker")
        let orphan = ChatMessage(id: session.blocks.last!.assistantReplyID!, role: "assistant", text: "live restored answer")
        let fallback = AgentContextBuilder.build(session: session, sessions: [session], conversations: [orphan], question: "好", sharing: true)
        check(wire(fallback.messages).contains("live restored answer"), "An assistant record without a preceding live user still preserves its restored answer")
    }
    private static func scopedTools(check: (Bool, String) -> Void) async throws {
        let (suite, defaults, preferences, providers) = fixture("scope")
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(); workspace.addTab(directory: "/tmp"); workspace.addTab(directory: "/")
        defer { workspace.closeAll() }
        let session = workspace.indexedSessions[0], other = workspace.indexedSessions[1]
        session.blocks = [shell("EXCLUDED-COMMAND", output: "EXCLUDED-OUTPUT"), ai("允许的问题", answer: "允许的回答"), shell("allowed-command", output: "allowed-result")]
        other.blocks = [shell("OTHER-SESSION-PRIVATE-COMMAND", output: "OTHER-SESSION-PRIVATE-OUTPUT")]
        let excluded = session.blocks[0].id, selected = session.blocks[1].id
        var requests: [AIRequestContext] = [], locked = false, frozen: AgentContextSelection?
        var assistant: AssistantStore!
        assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requests.append(request)
            switch requests.count {
            case 1:
                frozen = assistant.contextSelection(for: session)
                locked = !assistant.setContextStart(blockID: excluded, for: session)
                // A direct state edit can only affect the next run, never this one.
                session.contextStartBlockID = excluded
                return tool(BlockTools.read, ["session_index": 1, "block_index": 1, "offset": 0, "limit": 100])
            case 2: return tool(BlockTools.list, ["session_index": 1, "start_index": 1, "limit": 100])
            case 3: return tool(BlockTools.jump, ["session_index": 1, "block_index": 1])
            default: return .init(text: "范围检查完成")
            }
        }
        assistant.workspace = workspace
        check(assistant.setContextStart(blockID: selected, for: session), "A context boundary can be set to an eligible stable Block UUID")
        assistant.ask("仅使用选定范围", session: session)
        try await wait { !assistant.thinking.contains(session.id) }
        let combined = requests.map { wire($0.messages, $0.context) }.joined()
        check(locked && frozen?.isFrozen == true && frozen?.firstBlockID == selected,
              "An active run displays its frozen initial boundary and rejects UI boundary mutations")
        check(!combined.contains("EXCLUDED-COMMAND") && !combined.contains("EXCLUDED-OUTPUT") && combined.contains("不在本轮选定上下文范围"),
              "Excluded current-session command/output never reenter through automatic replay, overview, reads or jumps")
        check(combined.contains("allowed-command") && !combined.contains("OTHER-SESSION-PRIVATE"),
              "Automatic context contains selected current-session content without other-session command or output text")
        check(session.readingAnchorID == nil && requests.count == 4, "A denied excluded jump cannot navigate and the tool loop can still finish")
        let catalog = BlockCatalog(sessions: workspace.indexedSessions, current: session.id, allowedCurrentBlockIDs: [selected], automaticCurrentBlockIDs: [selected])
        let explicitOther = BlockTools.perform(.init(id: "explicit-other", name: BlockTools.read, arguments: BlockTools.json(["session_index": 2, "block_index": 1, "offset": 0, "limit": 1000])), catalog: catalog, sessions: workspace.indexedSessions, workspace: workspace)
        check(explicitOther.json.contains("OTHER-SESSION-PRIVATE-OUTPUT"), "Explicit other-session tool reads remain available without automatic cross-session replay")
        check(assistant.contextSelection(for: session).firstBlockID == excluded, "A direct boundary edit made during a run applies only after that frozen run ends")
    }
    private static func boundariesAndDisplay(check: (Bool, String) -> Void) throws {
        let (suite, defaults, preferences, providers) = fixture("boundaries")
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        var demo = shell("demo"); demo.isDemo = true
        session.blocks = [shell("excluded"), demo, ai("anchor", answer: "answer"), shell("latest")]
        let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in .init(text: "unused") }
        assistant.setContextStart(index: 3, for: session)
        let anchor = session.blocks[2].id, survivor = session.blocks[3].id
        let initial = assistant.contextSelection(for: session, question: "preview")
        let display = AgentContextDisplay(selection: initial, blocks: session.blocks)
        check(initial.availableIndices == [1, 3, 4] && initial.startEligibleIndex1 == 2 && initial.startIndex1 == 3 && initial.endIndex1 == 4,
              "Eligible slider positions map to actual timeline indices across demo gaps")
        check(display.firstBlockNumber == 3 && display.lastBlockNumber == 4 && display.rangeLabel == "Block 3–4"
              && display.timelineIndex(forEligiblePosition: 2) == 3 && display.timelineIndex(forEligiblePosition: 0) == nil,
              "Context UI labels and position mapping use the same visible Block numbers as tools")
        assistant.shiftContextBoundary(by: -1, for: session)
        var edge = AgentContextDisplay(selection: assistant.contextSelection(for: session), blocks: session.blocks)
        check(!edge.canExpand && edge.canShrink, "The earliest context boundary disables only expansion")
        assistant.setContextStart(index: 4, for: session)
        edge = AgentContextDisplay(selection: assistant.contextSelection(for: session), blocks: session.blocks)
        check(edge.canExpand && !edge.canShrink, "The latest-only context boundary disables only shrinking")
        var frozen = initial; frozen.isFrozen = true
        check(!AgentContextDisplay(selection: frozen, blocks: session.blocks).canAdjust, "Frozen run context controls cannot be adjusted")
        preferences.shareContext = false
        check(!AgentContextDisplay(selection: assistant.contextSelection(for: session), blocks: session.blocks).canAdjust, "Context opt-out disables boundary controls")
        preferences.shareContext = true
        session.contextStartBlockID = anchor
        session.blocks.remove(at: 2)
        check(assistant.contextSelection(for: session).firstBlockID == survivor && !assistant.context(for: session).contains("excluded"),
              "Deleting the UUID anchor cannot move the boundary backward into still-retained excluded Blocks")
        session.blocks.removeFirst()
        check(assistant.contextSelection(for: session).firstBlockID == survivor && assistant.contextSelection(for: session).startIndex1 == 2,
              "Prefix pruning changes visible numbering while preserving the selected surviving UUID")
    }
    private static func budgetsAndRedaction(check: (Bool, String) -> Void) throws {
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.blocks = (0..<120).map { shell("command-\($0)", output: String(repeating: "历史输出中文🙂", count: 3000) + "\npassword=output-private-\($0)") }
        let answer = String(repeating: "连续中文没有空白", count: 8000) + "\npassword=" + String(repeating: "secretvalue", count: 5000) + "\n需要我继续生成下一步方案吗？"
        session.blocks.append(ai("previous long question", answer: answer))
        let question = String(repeating: "完整本次用户问题🙂", count: 3000) + "最后指令必须完整保留"
        let payload = AgentContextBuilder.build(session: session, sessions: [session], conversations: [], question: question, sharing: true)
        let historical = Array(payload.messages.dropLast())
        let text = wire(payload.messages, payload.context)
        check(payload.messages.last?["content"] as? String == question, "Large current user instructions are preserved fully instead of being silently shortened by the history budget")
        check(text.contains("需要我继续生成下一步方案吗") && !text.contains("secretvalue") && !text.contains("output-private"),
              "Bounded replay preserves an unbroken Chinese assistant ending offer and redacts credentials before head/tail clipping")
        check(payload.selection.wasClipped && AgentContextBuilder.serializedBytes(messages: historical, context: payload.context) <= AgentContextBuilder.maximumSerializedBytes,
              "Large historical replay stays within its serialized budget and exposes clipping explicitly")
        let actualBytes = AgentContextBuilder.serializedBytes(messages: payload.messages, context: payload.context)
        check(payload.selection.serializedUTF8Bytes == actualBytes && payload.selection.approximateTokens == Int(ceil(Double(actualBytes) / 4)),
              "Live approximate tokens derive from exactly the serialized redacted messages and context, including the full new question")
    }
    private static func pruningAndFrozenEstimate(check: (Bool, String) -> Void) async throws {
        let (suite, defaults, preferences, providers) = fixture("pruning")
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.blocks = (1...300).map { shell("retained-\($0)", output: "result-\($0)") }
        let expectedFirst = session.blocks[1].id
        var exact = false, firstID: UUID?, requested = 0
        var assistant: AssistantStore!
        assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            requested += 1
            if requested == 1 {
                let snapshot = assistant.contextSelection(for: session)
                firstID = snapshot.firstBlockID
                exact = snapshot.isFrozen && snapshot.serializedUTF8Bytes == AgentContextBuilder.serializedBytes(messages: request.messages, context: request.context)
                session.blocks.removeFirst()
                return tool(BlockTools.read, ["session_index": 1, "block_index": 1, "offset": 0, "limit": 100])
            }
            return .init(text: "snapshot checked")
        }
        assistant.ask("snapshot-input", session: session)
        try await wait { !assistant.thinking.contains(session.id) }
        check(exact && firstID == expectedFirst, "The frozen first-request estimate and UUID range are computed after append-time 300-Block pruning")
        check(assistant.messages(for: session).flatMap(\.steps).first?.status.contains("编号已变化") == true,
              "The frozen first request's tool catalog rejects reindexing instead of reading a different surviving Block")
    }
    private static func sharingOff(check: (Bool, String) -> Void) async throws {
        let (suite, defaults, preferences, providers) = fixture("optout")
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.shareContext = false
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.blocks = [ai("PRIVATE-QUESTION", answer: "PRIVATE-ANSWER"), shell("PRIVATE-COMMAND", output: "PRIVATE-OUTPUT")]
        var observed = false
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            observed = request.context.isEmpty && !request.allowsBlockTools && request.messages.count == 1 && !wire(request.messages).contains("PRIVATE-")
            return .init(text: "standalone")
        }
        assistant.ask("standalone request", session: session)
        try await wait { !assistant.thinking.contains(session.id) }
        check(observed, "Context opt-out sends only the new question and exposes neither historical content nor Block tools")
    }
    private static func quickIntentScope(check: (Bool, String) -> Void) async throws {
        let (suite, defaults, preferences, providers) = fixture("intent-scope")
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.quickIntents = true
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.blocks = [shell("INTENT-EXCLUDED-COMMAND", output: "INTENT-EXCLUDED-OUTPUT"), shell("intent-allowed-command", output: "intent-allowed-result"), shell("intent-new-command")]
        session.contextStartBlockID = session.blocks[1].id
        var request: AIRequestContext?
        let assistant = AssistantStore(providers: providers, preferences: preferences) { incoming, _ in
            request = incoming
            return .init(text: #"{"intents":[{"title":"解释结果","question":"解释当前结果"}]}"#)
        }
        defer { assistant.close(session: session) }
        assistant.didExecute("intent-new-command", session: session)
        try await wait { request != nil && assistant.intentPreviews[session.id]?.loading == false }
        check(request?.purpose == .intent && request?.context.contains("intent-allowed-result") == true
              && request?.context.contains("INTENT-EXCLUDED") == false,
              "Automatic quick-intent context respects the selected history boundary instead of reading excluded recent results")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw AIError.message("Agent context fixture timed out")
    }
    private static func previewBenchmark() {
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        defer { session.close() }
        session.blocks = (1...300).map { shell("printf 'realistic-\($0)'", output: "result \($0)\nexit successful") }
        _ = AgentContextBuilder.build(session: session, sessions: [session], conversations: [], question: "warmup", sharing: true)
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<10 { _ = AgentContextBuilder.build(session: session, sessions: [session], conversations: [], question: "draft-\(index)", sharing: true) }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print(String(format: "CONTEXT-PREVIEW-BENCHMARK 300 Blocks × 10 builds: %.3fs total, %.1fms/build (observation only)", elapsed, elapsed * 100))
    }
}
#endif
