import SwiftUI

struct AssistantBubble: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var providers: ProviderStore
    @ObservedObject var preferences: Preferences
    @ObservedObject var workspace: Workspace
    @State private var showHistory = false
    private var draft: Binding<String> {
        Binding(get: { assistant.inputDrafts[session.id] ?? "" }, set: { assistant.inputDrafts[session.id] = $0 })
    }
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: TerminalTheme { preferences.theme }
    private var messages: [ChatMessage] { assistant.messages(for: session) }
    private var replies: [ChatMessage] { messages.filter { $0.role == "assistant" } }
    private var thinking: Bool { assistant.thinking.contains(session.id) }
    private var activity: CompanionActivity { assistant.activity(for: session) }
    var width: CGFloat = 340
    var maxBodyHeight: CGFloat = 310
    var move: (CGSize, Bool) -> Void = { _, _ in }
    private var contentHeight: CGFloat {
        if messages.isEmpty { return 85 }
        if !showHistory, let reply = replies.last, reply.text.isEmpty && reply.steps.isEmpty && assistant.questions(for: reply.id).isEmpty { return min(maxBodyHeight, 70) }
        return maxBodyHeight
    }
    var body: some View { bubble }
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    EchoPaw().fill(theme.accent).frame(width: 12, height: 12).accessibilityHidden(true)
                    Text("Echo").font(.system(size: 11, weight: .semibold))
                    if activity == .success { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent).font(.system(size: 10)) }
                    Text(activity.label).font(.system(size: 10)).foregroundStyle(theme.muted)
                }.contentShape(Rectangle()).help("拖动移动气泡")
                    .gesture(DragGesture().onChanged { move($0.translation, false) }.onEnded { move($0.translation, true) })
                Spacer()
                if !messages.isEmpty { IconButton("clock", help: "对话记录", active: showHistory) { showHistory.toggle() } }
                IconButton("gearshape", help: "配置模型") { workspace.showSettings = true }
                IconButton("minus", help: "最小化助手") { workspace.minimizeAssistant() }
            }
            HStack(spacing: 5) {
                Text(session.displayDirectory).lineLimit(1).truncationMode(.middle)
                if workspace.activeSession?.id != session.id {
                    Button("回到会话") { workspace.revealSession(session.id) }.buttonStyle(.plain).foregroundStyle(theme.accent)
                }
            }.font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.muted)
            AssistantModeControl(preferences: preferences, mode: Binding(get: { assistant.mode(for: session) }, set: { assistant.setMode($0, session: session) }))
            Text(assistant.mode(for: session) == .answer ? "问答 / 查阅 · 不执行命令" : "可执行命令 · 随时停止")
                .font(.system(size: 9)).foregroundStyle(theme.muted)
            if thinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(assistant.phases[session.id] ?? "思考中…").font(.system(size: 11))
                    Spacer()
                    Button("停止 ⌘.") { assistant.cancel(session: session) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(theme.accent)
                }
            }
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if showHistory {
                            ForEach(messages) { message in
                                if message.role == "assistant" { replyView(message) }
                                else { Text(message.text).font(.system(size: 11)).foregroundStyle(theme.muted).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                        } else if let reply = replies.last { replyView(reply) }
                        else {
                            Text(session.selectedBlock == nil ? "输入问题" : "查看所选区块").font(.system(size: 13))
                            HStack(spacing: 6) {
                                quickAction("解释输出", question: "解释最近一条命令的输出。")
                                quickAction("排查问题", question: "根据当前终端上下文帮我排查问题。")
                                quickAction("下一步", question: "根据最近的命令，建议下一步。")
                            }
                        }
                        Color.clear.frame(height: 1).id("reply-end")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: contentHeight)
                    .onChange(of: replies.last?.text) { _, _ in if thinking && !showHistory { reader.scrollTo("reply-end", anchor: .bottom) } }
                    .onChange(of: replies.last?.steps.count) { _, _ in if !showHistory { reader.scrollTo("reply-end", anchor: .bottom) } }
                    .onChange(of: assistant.userQuestions.count) { _, _ in if !showHistory { reader.scrollTo("reply-end", anchor: .bottom) } }
            }
            if let error = session.insertionError { Text(error).font(.system(size: 10)).foregroundStyle(theme.muted) }
            Divider().opacity(0.35)
            HStack(alignment: .bottom, spacing: 9) {
                TextField("问一句…", text: draft, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...4).focused($inputFocused).onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 11, weight: .medium)).frame(width: 24, height: 24).background(theme.accent.opacity(0.12)).clipShape(Circle()) }.buttonStyle(.plain).foregroundStyle(theme.accent).disabled(!assistant.canStartBlock(in: session) || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 5) {
                Button { preferences.shareContext.toggle() } label: { Label(preferences.shareContext ? "附带区块概览" : "不附带终端内容", systemImage: preferences.shareContext ? "link" : "lock") }.buttonStyle(.plain)
                Spacer()
                Text(providers.selected.model.isEmpty ? "未连接模型" : providers.selected.effort.title).help(providers.selected.name)
            }.font(.system(size: 9)).foregroundStyle(theme.muted)
        }.padding(15).frame(width: width).background(theme.base.opacity(0.98)).clipShape(RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme.text.opacity(0.12)))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 7)
            .onChange(of: workspace.assistantFocusRequest) { _, _ in inputFocused = true }
            .onChange(of: inputFocused) { _, focused in workspace.assistantWantsFocus = focused }
            .task {
                if workspace.assistantWantsFocus {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    if !Task.isCancelled { inputFocused = true }
                }
            }
            .onExitCommand { inputFocused = false; workspace.assistantWantsFocus = false; workspace.activeSession?.focus() }
    }
    private func quickAction(_ title: String, question: String) -> some View {
        Button { assistant.ask(contextualQuestion(question), session: session) } label: { Text(title).font(.system(size: 10)).padding(.horizontal, 9).padding(.vertical, 6).background(theme.text.opacity(0.045)).clipShape(Capsule()) }.buttonStyle(.plain).foregroundStyle(theme.muted)
    }
    private func replyView(_ reply: ChatMessage) -> some View {
        AssistantReplyContent(reply: reply, session: session, assistant: assistant, workspace: workspace, preferences: preferences)
    }
    private func contextualQuestion(_ question: String) -> String {
        guard preferences.shareContext, let block = session.selectedBlock else { return question }
        guard let index = session.blocks.firstIndex(where: { $0.id == block.id }) else { return question }
        return question + "\n当前选中 Session \(workspace.sessionIndex(session.id) ?? 1) · Block \(index + 1)，请按需读取详情。"
    }
    private func send() {
        guard !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if assistant.ask(contextualQuestion(draft.wrappedValue), session: session) { draft.wrappedValue = "" }
    }
}
