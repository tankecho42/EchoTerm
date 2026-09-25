import SwiftUI
import Combine

struct AIRequestContext {
    var config: ProviderConfiguration
    var messages: [[String: Any]]
    var context: String
    var mode: AssistantMode
    var streaming: Bool
    var purpose: AIRequestPurpose = .conversation
    var round: AIRoundMeter?
    var usageCategory: String?
    var allowsBlockTools = false
}
typealias AITransport = @MainActor (AIRequestContext, @escaping @MainActor (AIStreamUpdate) -> Void) async throws -> AIReply

@MainActor final class AssistantStore: ObservableObject {
    @Published var conversations: [UUID: [ChatMessage]] = [:]
    @Published var thinking: Set<UUID> = []
    @Published var phases: [UUID: String] = [:]
    @Published var draft = ""
    @Published var inputDrafts: [UUID: String] = [:]
    @Published var activities: [UUID: CompanionActivity] = [:]
    @Published var intentPreviews: [UUID: IntentPreview] = [:] {
        didSet { for preview in intentPreviews.values { blockIntents[preview.id] = preview } }
    }
    @Published var blockIntents: [UUID: IntentPreview] = [:]
    @Published var presentation: AssistantPresentation?
    private var intentTasks: [UUID: Task<Void, Never>] = [:]
    private var intentDeadlines: [UUID: Task<Void, Never>] = [:]
    private var intentTokens: [UUID: UUID] = [:]
    private var lastIntentBlock: [UUID: UUID] = [:]
    private let intentTimeout: UInt64
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var runs: [UUID: UUID] = [:]
    private var runMeters: [UUID: (meter: AIRoundMeter, model: String)] = [:]
    private var activeReplies: [UUID: UUID] = [:]
    private var sessions: [UUID: TerminalSession] = [:]
    private var staged: [UUID: UUID] = [:]
    private var observers: Set<AnyCancellable> = []
    private let transport: AITransport
    weak var workspace: Workspace?
    let providers: ProviderStore
    let preferences: Preferences
    let usage: AIUsageStore
    init(providers: ProviderStore, preferences: Preferences, transport: AITransport? = nil, usage: AIUsageStore? = nil, intentTimeout: UInt64 = 8_000_000_000) {
        self.intentTimeout = intentTimeout
        self.providers = providers; self.preferences = preferences; self.usage = usage ?? AIUsageStore()
        let base: AITransport = transport ?? { request, update in
            try await AIClient.send(config: request.config, key: Keychain.read(request.config.id), messages: request.messages,
                                    context: request.context, mode: request.mode, streaming: request.streaming, purpose: request.purpose, allowsBlockTools: request.allowsBlockTools, onUpdate: update)
        }
        self.transport = AIUsageRecorder.wrap(base, store: self.usage)
        preferences.$assistantMode.dropFirst().sink { [weak self] mode in
            guard let self, mode == .answer else { return }
            for session in Array(self.sessions.values) where session.agentOwner != nil && session.defaultAssistantMode == nil && session.assistantModeOverride == nil { self.cancel(session: session) }
        }.store(in: &observers)
        preferences.$shareContext.dropFirst().sink { [weak self] enabled in
            guard let self, !enabled else { return }
            for session in Array(self.sessions.values) { self.cancel(session: session) }
            for id in Array(self.intentTokens.keys) { self.cancelIntent(id) }
        }.store(in: &observers)
        preferences.$quickIntents.dropFirst().sink { [weak self] enabled in
            guard let self, !enabled else { return }
            for id in Array(self.intentTokens.keys) { self.cancelIntent(id) }
        }.store(in: &observers)
    }
    func activity(for session: TerminalSession) -> CompanionActivity {
        if thinking.contains(session.id) { return activities[session.id] ?? .thinking }
        if intentPreviews[session.id]?.loading == true { return .thinking }
        return activities[session.id] ?? .idle
    }
    func close(session: TerminalSession) {
        cancel(session: session)
        for block in session.blocks { blockIntents[block.id] = nil }
        intentPreviews[session.id] = nil; inputDrafts[session.id] = nil; lastIntentBlock[session.id] = nil
    }
    func messages(for session: TerminalSession) -> [ChatMessage] { conversations[session.id] ?? [] }
    func canStartBlock(in session: TerminalSession) -> Bool {
        !session.running && session.agentOwner == nil && !thinking.contains(session.id)
    }
    func mode(for session: TerminalSession) -> AssistantMode { session.assistantModeOverride ?? session.defaultAssistantMode ?? preferences.assistantMode }
    func setMode(_ mode: AssistantMode, session: TerminalSession) {
        session.assistantModeOverride = mode
        if mode == .answer && session.agentOwner != nil { cancel(session: session) }
    }
    @discardableResult func submitInput(session: TerminalSession, forced: InputRoute? = nil) -> Bool {
        let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard canStartBlock(in: session) else {
            session.insertionError = "当前区块尚未结束，输入已保留。"; return false
        }
        let requested = forced ?? session.inputRoute
        if requested == .automatic && !session.catalogReady {
            session.insertionError = "正在读取 Shell 命令列表，请稍后再提交。"; return false
        }
        let route = requested == .automatic ? (session.commandCatalog.assess(text, directory: session.directory).isCommand ? InputRoute.shell : .assistant) : requested
        session.insertionError = nil
        if route == .shell {
            let accepted = session.execute() != nil
            if accepted { session.resetInputModes() }
            return accepted
        }
        session.draft = ""; ask(text, session: session)
        session.resetInputModes()
        return true
    }
    @discardableResult func ask(_ question: String, session: TerminalSession, displayQuestion: String? = nil) -> Bool {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        guard canStartBlock(in: session) else { session.insertionError = "当前区块尚未结束，请等待完成或先停止。"; return false }
        session.insertionError = nil
        let id = session.id, run = UUID(), replyID = UUID(), mode = mode(for: session)
        cancelIntent(id)
        activities[id] = .thinking
        conversations[id, default: []].append(.init(role: "user", text: question))
        session.resumeInput()
        session.appendAIBlock(question: displayQuestion ?? question, replyID: replyID, mode: mode)
        if mode == .autonomous {
            let error: String? = !preferences.shareContext ? "自主操控需要读取命令结果。请开启「附带终端上下文」，或切换问答模式。"
                : !session.ready || session.exited ? "当前 Shell 尚未就绪或已经结束，请使用可用的终端会话。"
                : session.running ? "当前命令仍在运行。等它结束后再发起自主排查。"
                : !session.draft.isEmpty ? "输入区还有未执行的命令，已为你保留。请先执行或清空草稿，再发起自主排查。" : nil
            if let error {
                activities[id] = .attention
                let reply = ChatMessage(id: replyID, role: "assistant", text: error, activity: .attention)
                conversations[id, default: []].append(reply); session.updateAIBlock(reply)
                return true
            }
            session.agentOwner = run
        }
        let config = providers.selected, streaming = preferences.streamReplies
        let meter = AIRoundMeter(); runMeters[run] = (meter, config.model)
        // Prior turns are retrieved through the block catalog instead of replaying their entire output.
        var history: [[String: Any]] = [["role": "user", "content": ContextRedactor.redact(question)]]
        let limit = max(1, min(24, preferences.agentStepLimit)), timeout = max(1, preferences.commandTimeout)
        conversations[id, default: []].append(.init(id: replyID, role: "assistant", text: "", isStreaming: true, runID: run))
        activeReplies[id] = replyID
        thinking.insert(id); phases[id] = "思考中…"; runs[id] = run; sessions[id] = session
        tasks[id] = Task { [self] in
            defer { finishRun(session: session, run: run, replyID: activeReplies[id] ?? replyID) }
            var count = 0, lookups = 0, seenCalls: Set<String> = []
            let lookupLimit = 24
            do {
                // One final summary request remains after the command budget is exhausted.
                for round in 0...(limit + lookupLimit) {
                    try ensureActive(session: session, run: run, mode: mode)
                    let lastRequest = round == limit + lookupLimit
                    let requestMode: AssistantMode = count >= limit || lastRequest ? .answer : mode
                    let allowsBlocks = preferences.shareContext && lookups < lookupLimit && !lastRequest
                    let catalog = BlockCatalog(sessions: indexedSessions(fallback: session), current: id)
                    let context = preferences.shareContext ? catalog.overview : ""
                    activities[id] = .thinking
                    phases[id] = count > 0 ? "读取结果，继续分析…" : "思考中…"
                    let segmentID = activeReplies[id] ?? replyID
                    let reply = try await transport(.init(config: config, messages: history, context: context, mode: requestMode, streaming: streaming, round: meter, allowsBlockTools: allowsBlocks)) { [weak self] update in
                        guard let self, self.runs[id] == run, self.activeReplies[id] == segmentID, !Task.isCancelled else { return }
                        self.phases[id] = update.phase
                        self.activities[id] = update.activity
                        self.changeMessage(id, segmentID) { $0.text = update.text }
                    }
                    try ensureActive(session: session, run: run, mode: mode)
                    changeMessage(id, segmentID) { $0.text = reply.text; $0.suggestions += reply.suggestions }
                    guard !reply.calls.isEmpty else {
                        if count >= limit { changeMessage(id, segmentID) { $0.status = "已达到本轮 \(limit) 条命令上限" } }
                        break
                    }
                    // Validate the whole batch before performing any side effects.
                    var commands: [String: CommandSuggestion] = [:]
                    for call in reply.calls {
                        guard !call.id.isEmpty, seenCalls.insert(call.id).inserted else { throw AIError.message("模型返回重复或缺失 ID 的工具调用，已停止。") }
                        if call.name == AIClient.executeTool {
                            guard mode == .autonomous, requestMode == .autonomous else { throw AIError.message("当前模式不允许执行模型返回的命令，未操作终端。") }
                            commands[call.id] = try call.command()
                        } else {
                            guard BlockTools.names.contains(call.name), allowsBlocks, preferences.shareContext else { throw AIError.message("当前不允许这个区块工具调用，已停止。") }
                        }
                    }
                    guard commands.count <= limit - count, reply.calls.count - commands.count <= lookupLimit - lookups, !lastRequest else { throw AIError.message("本轮工具调用额度已用完。") }
                    history += reply.continuation
                    changeMessage(id, segmentID) { $0.isStreaming = false; $0.activity = .success }
                    var results: [(AIToolCall, String)] = []
                    for call in reply.calls {
                        try ensureActive(session: session, run: run, mode: mode)
                        activities[id] = .working
                        guard let command = commands[call.id] else {
                            lookups += 1
                            phases[id] = call.name == BlockTools.jump ? "定位区块…" : "查看区块…"
                            let result = BlockTools.perform(call, catalog: catalog, sessions: indexedSessions(fallback: session), workspace: workspace, conversations: conversations)
                            let kind: AgentStepKind = call.name == BlockTools.jump ? .jump : call.name == BlockTools.read ? .read : .list
                            changeMessage(id, segmentID) { $0.steps.append(.init(command: result.title, explanation: "", status: result.status, blockID: result.blockID, kind: kind, sessionID: result.sessionID)) }
                            results.append((call, result.json))
                            continue
                        }
                        count += 1
                        phases[id] = "执行命令 \(count) / \(limit)"
                        let stepID = UUID()
                        changeMessage(id, segmentID) { $0.activity = .working; $0.steps.append(.init(id: stepID, command: command.command, explanation: command.explanation)) }
                        let result = try await execute(command.command, session: session, run: run, timeout: timeout) { blockID in
                            self.changeMessage(id, segmentID) { message in if let index = message.steps.firstIndex(where: { $0.id == stepID }) { message.steps[index].blockID = blockID } }
                        }
                        changeMessage(id, segmentID) { message in
                            if let index = message.steps.firstIndex(where: { $0.id == stepID }) { message.steps[index].status = result.timedOut ? "已超时中断" : "exit \(result.block.exitCode ?? -1) · \(result.block.duration)" }
                        }
                        let output: [String: Any] = ["session_index": workspace?.sessionIndex(session.id) ?? 1, "block_index": session.blocks.firstIndex(where: { $0.id == result.block.id }).map { $0 + 1 } as Any? ?? NSNull(), "output_truncated": result.block.output.count > 24000, "command": ContextRedactor.redact(result.block.command), "output": ContextRedactor.redact(String(result.block.output.suffix(24000))), "exit_code": result.block.exitCode ?? -1, "cwd": ContextRedactor.redact(session.directory), "timed_out": result.timedOut]
                        let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
                        results.append((call, String(decoding: json, as: UTF8.self)))
                    }
                    changeMessage(id, segmentID) { $0.activity = .success }
                    // Append the next answer only after the tool commands have ended.
                    let next = UUID(); activeReplies[id] = next
                    conversations[id, default: []].append(.init(id: next, role: "assistant", text: "", isStreaming: true, runID: run))
                    session.appendAIBlock(question: "继续分析", replyID: next, continuation: true, mode: mode)
                    history += AIClient.toolResults(results, apiProtocol: config.apiProtocol)
                    if lookups >= lookupLimit { history.append(["role": "user", "content": "本轮区块查询额度已用完，请依据已有内容完成回答。"] ) }
                    if count >= limit { history.append(["role": "user", "content": "本轮执行额度已用完。请依据已有结果总结，说明未完成的部分，不再执行命令。"] ) }
                }
                activities[id] = .success
            } catch {
                if runs[id] == run {
                    activities[id] = Task.isCancelled || error is CancellationError ? .stopped : .attention
                    changeMessage(id, activeReplies[id] ?? replyID) { message in
                        message.status = Task.isCancelled || error is CancellationError ? "已停止" : error.localizedDescription
                        for i in message.steps.indices where message.steps[i].status == "执行中" { message.steps[i].status = "已停止" }
                    }
                    stopUnfinishedSteps(sessionID: id, run: run)
                }
            }
        }
        return true
    }
    private func ensureActive(session: TerminalSession, run: UUID, mode: AssistantMode) throws {
        try Task.checkCancellation()
        guard runs[session.id] == run else { throw CancellationError() }
        if mode == .autonomous {
            guard preferences.shareContext, session.agentOwner == run else { throw CancellationError() }
            guard !session.exited else { throw AIError.message("终端会话已结束。") }
        }
    }
    private func execute(_ command: String, session: TerminalSession, run: UUID, timeout: Double, started: (UUID) -> Void) async throws -> (block: CommandBlock, timedOut: Bool) {
        try ensureActive(session: session, run: run, mode: .autonomous)
        guard !session.running, session.ready, session.draft.isEmpty else { throw AIError.message("终端状态发生变化，已停止自动操作并保留你的输入。") }
        session.draft = command
        guard let blockID = session.execute(owner: run) else { session.draft = ""; throw AIError.message(session.insertionError ?? "命令未能送入终端。") }
        started(blockID)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, interruptDeadline = Date.distantFuture
        while true {
            try ensureActive(session: session, run: run, mode: .autonomous)
            if let block = session.lastCompleted, block.id == blockID {
                session.agentBlockID = nil
                return (block, timedOut)
            }
            if !timedOut && Date() >= deadline {
                timedOut = true; interruptDeadline = Date().addingTimeInterval(4)
                session.interrupt(); phases[session.id] = "命令超时，正在中断…"
            }
            if timedOut && Date() >= interruptDeadline { throw AIError.message("命令超时，已发送 Ctrl-C，但进程尚未退出。自动操作已停止，可在终端手动接管。") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    private func finishRun(session: TerminalSession, run: UUID, replyID: UUID) {
        guard runs[session.id] == run else { return }
        let summary = runMeters.removeValue(forKey: run).map { $0.meter.summary(model: $0.model) }
        changeMessage(session.id, replyID) { $0.isStreaming = false; $0.activity = activities[session.id] ?? .success; $0.roundSummary = summary }
        if session.agentOwner == run { session.agentOwner = nil; session.agentBlockID = nil }
        runs[session.id] = nil; activeReplies[session.id] = nil; thinking.remove(session.id); phases[session.id] = nil; sessions[session.id] = nil; tasks[session.id] = nil
    }
    private func changeMessage(_ sessionID: UUID, _ messageID: UUID, _ update: (inout ChatMessage) -> Void) {
        guard let index = conversations[sessionID]?.firstIndex(where: { $0.id == messageID }) else { return }
        update(&conversations[sessionID]![index])
        if let message = conversations[sessionID]?[index] { sessions[sessionID]?.updateAIBlock(message) }
    }
    func send(session: TerminalSession) { if ask(draft, session: session) { draft = "" } }
    func cancel(session: TerminalSession) {
        cancelIntent(session.id)
        activities[session.id] = .stopped
        guard let run = runs[session.id] else { return }
        tasks[session.id]?.cancel()
        if session.agentOwner == run, session.running, session.runningBlockID == session.agentBlockID { session.interrupt() }
        if let replyID = activeReplies[session.id] {
            changeMessage(session.id, replyID) { message in
                message.status = "已停止"; message.isStreaming = false
                for i in message.steps.indices where message.steps[i].status == "执行中" { message.steps[i].status = "已发送中断" }
            }
            stopUnfinishedSteps(sessionID: session.id, run: run)
            finishRun(session: session, run: run, replyID: replyID)
        }
    }
    private func stopUnfinishedSteps(sessionID: UUID, run: UUID) {
        for message in conversations[sessionID] ?? [] where message.runID == run {
            changeMessage(sessionID, message.id) { value in
                for index in value.steps.indices where value.steps[index].status == "执行中" { value.steps[index].status = "已停止" }
            }
        }
    }
    func use(_ suggestion: CommandSuggestion, session: TerminalSession) {
        guard session.insert(suggestion.command) else { return }
        update(suggestion.id, sessionID: session.id, state: "已填入，等待执行")
        if let previous = staged[session.id], previous != suggestion.id { update(previous, sessionID: session.id, state: "已替换") }
        staged[session.id] = suggestion.id
    }
    func dismiss(_ suggestion: CommandSuggestion, session: TerminalSession) { update(suggestion.id, sessionID: session.id, state: "已忽略") }
    func didExecute(_ command: String, session: TerminalSession) {
        inferIntent(command, session: session)
        guard let id = staged.removeValue(forKey: session.id) else { return }
        let original = conversations[session.id, default: []].flatMap(\.suggestions).first { $0.id == id }?.command
        update(id, sessionID: session.id, state: original == command ? "已执行" : "已修改后执行：\(command)")
    }
    func didComplete(_ block: CommandBlock, session: TerminalSession) {
        // Full assistant runs require a user message. Quick intent requests happen once at manual submission, never again on completion.
    }
    private func inferIntent(_ command: String, session: TerminalSession) {
        let id = session.id
        guard preferences.quickIntents, preferences.shareContext, !session.exited,
              let block = session.blocks.last, !block.isDemo, !block.isAI, block.assistantRunID == nil,
              session.agentOwner == nil, lastIntentBlock[id] != block.id else { return }
        let provider = preferences.quickProviderID.isEmpty ? providers.selected : providers.configurations.first { $0.id == preferences.quickProviderID }
        guard let provider, !provider.fastConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastIntentBlock[id] = block.id
        cancelIntent(id)
        let token = UUID(), config = provider.fastConfiguration
        intentTokens[id] = token
        intentPreviews[id] = .init(id: block.id, command: command)
        let recent = session.blocks.dropLast().filter { !$0.isAI }.suffix(2).map { "$ \($0.command)\nexit: \($0.exitCode ?? -1)\n\(String($0.output.suffix(1000)))" }.joined(separator: "\n")
        let context = ContextRedactor.redact("Shell: \(session.shellName)\ncwd: \(session.directory)\n最近结果：\n\(recent)\n用户刚刚提交的命令（可能仍在运行）：\n\(String(command.prefix(4000)))")
        intentDeadlines[id] = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: self.intentTimeout) } catch { return }
            guard self.intentTokens[id] == token else { return }
            self.cancelIntent(id, error: "快速判断超时，可继续使用终端。")
        }
        intentTasks[id] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                if self.intentTokens[id] == token {
                    self.intentTokens[id] = nil; self.intentTasks[id] = nil
                    self.intentDeadlines.removeValue(forKey: id)?.cancel()
                    self.intentPreviews[id]?.loading = false
                }
            }
            do {
                try Task.checkCancellation()
                guard self.intentTokens[id] == token, !session.exited, self.preferences.quickIntents, self.preferences.shareContext else { return }
                let reply = try await self.transport(.init(config: config, messages: [["role": "user", "content": "给出这次命令可能对应的后续意图选项。"]], context: context, mode: .answer, streaming: false, purpose: .intent)) { _ in }
                try Task.checkCancellation()
                guard self.intentTokens[id] == token, !session.exited, self.preferences.quickIntents, self.preferences.shareContext else { return }
                let options = try QuickIntent.parse(reply)
                self.intentPreviews[id]?.options = options
                if !self.thinking.contains(id) { self.activities[id] = .success }
            } catch {
                if self.intentTokens[id] == token && !Task.isCancelled {
                    self.intentPreviews[id]?.error = "快速判断暂不可用：" + error.localizedDescription
                    if !self.thinking.contains(id) { self.activities[id] = .attention }
                }
            }
        }
    }
    private func cancelIntent(_ id: UUID, error: String? = nil) {
        intentTokens[id] = nil
        intentTasks.removeValue(forKey: id)?.cancel()
        intentDeadlines.removeValue(forKey: id)?.cancel()
        if intentPreviews[id]?.loading == true {
            if !thinking.contains(id) { activities[id] = error == nil ? .stopped : .attention }
            intentPreviews[id]?.loading = false
            intentPreviews[id]?.error = error ?? "快速判断已停止"
        }
    }
    func chooseIntent(_ option: IntentOption, session: TerminalSession, blockID: UUID? = nil) {
        guard canStartBlock(in: session), var preview = blockID.flatMap({ blockIntents[$0] }) ?? intentPreviews[session.id],
              !preview.loading, preview.chosenID == nil, preview.options.contains(option) else { return }
        guard mode(for: session) != .autonomous || !session.running else { return }
        preview.chosenID = option.id; blockIntents[preview.id] = preview
        if intentPreviews[session.id]?.id == preview.id { intentPreviews[session.id] = preview }
        let block = session.blocks.first { $0.id == preview.id }
        var question = option.question
        if preferences.shareContext {
            question += "\n用户选择的意图：\(option.title)\n对应命令：\(String(preview.command.prefix(100)))"
            if let block, let index = session.blocks.firstIndex(where: { $0.id == block.id }) { question += "\n对应 Session \(workspace?.sessionIndex(session.id) ?? 1) · Block \(index + 1)，请按需读取详情。" }
        }
        ask(question, session: session, displayQuestion: option.question)
    }
    func useLatest(session: TerminalSession) {
        if let suggestion = messages(for: session).reversed().flatMap(\.suggestions).first(where: { $0.state == "pending" }) { use(suggestion, session: session) }
    }
    private func update(_ suggestionID: UUID, sessionID: UUID, state: String) {
        guard var messages = conversations[sessionID] else { return }
        for i in messages.indices { for j in messages[i].suggestions.indices where messages[i].suggestions[j].id == suggestionID { messages[i].suggestions[j].state = state } }
        conversations[sessionID] = messages
    }
    func explain(_ block: CommandBlock, session: TerminalSession) {
        guard let index = session.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let question = preferences.shareContext ? "请读取并解释 Session \(workspace?.sessionIndex(session.id) ?? 1) 的 Block \(index + 1)，包括输入与输出。" : "请解释这条命令：\n" + block.command
        ask(question, session: session, displayQuestion: "解释 Block \(index + 1)：" + String(block.command.prefix(120)))
    }
    func indexedSessions(fallback session: TerminalSession) -> [TerminalSession] {
        workspace?.indexedSessions ?? [session]
    }
    func context(for session: TerminalSession) -> String {
        BlockCatalog(sessions: indexedSessions(fallback: session), current: session.id).overview
    }
}
