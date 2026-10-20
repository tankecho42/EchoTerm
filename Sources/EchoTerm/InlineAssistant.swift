import SwiftUI

struct AssistantModeControl: View {
    @ObservedObject var preferences: Preferences
    var mode: Binding<AssistantMode>? = nil
    var compact = false
    @Namespace private var selection
    private var theme: TerminalTheme { preferences.theme }
    private var current: AssistantMode { mode?.wrappedValue ?? preferences.assistantMode }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(AssistantMode.allCases) { mode in
                Button { withAnimation(.easeInOut(duration: 0.18)) { if let binding = self.mode { binding.wrappedValue = mode } else { preferences.assistantMode = mode } } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .answer ? "text.bubble" : "terminal")
                        Text(mode == .answer ? "问答" : "自主操控")
                    }.font(.system(size: 10, weight: current == mode ? .medium : .regular))
                        .padding(.horizontal, compact ? 9 : 13).padding(.vertical, 7)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .foregroundStyle(current == mode ? theme.text : theme.muted)
                        .background {
                            if current == mode { RoundedRectangle(cornerRadius: 7).fill(theme.text.opacity(0.085)).matchedGeometryEffect(id: "mode", in: selection) }
                        }.contentShape(.interaction, Rectangle())
                }.buttonStyle(.plain).help(mode.detail).accessibilityLabel("\(mode.title)模式").accessibilityAddTraits(current == mode ? .isSelected : [])
            }
        }.padding(3).background(theme.text.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line))
    }
}

struct AssistantReplyContent: View {
    let reply: ChatMessage
    @ObservedObject var session: TerminalSession
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    var showSteps = true
    var onClick: (() -> Void)? = nil
    private var theme: TerminalTheme { preferences.theme }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !reply.text.isEmpty { MarkdownContent(text: reply.text, theme: theme, insertCommand: { _ = session.insert($0) }, copyOnSelection: preferences.copyOnSelection, onClick: onClick, isStreaming: reply.isStreaming) }
            ForEach(reply.steps.filter { showSteps || $0.kind != .command }) { step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: step.kind.icon).foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        SelectableText(text: step.command, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: NSColor(theme.text), copyOnSelection: preferences.copyOnSelection, onClick: onClick)
                        if !step.explanation.isEmpty { SelectableText(text: step.explanation, font: .systemFont(ofSize: 10), color: NSColor(theme.muted), copyOnSelection: preferences.copyOnSelection, onClick: onClick) }
                        SelectableText(text: step.status, font: .systemFont(ofSize: 9), color: NSColor(theme.muted), copyOnSelection: preferences.copyOnSelection, onClick: onClick)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let id = step.blockID { Button { workspace.revealBlock(sessionID: step.sessionID ?? session.id, blockID: id) } label: { Image(systemName: "arrow.down.right") }.buttonStyle(.plain).help("跳转到这个区块") }
                }.padding(11).background(theme.text.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            ForEach(assistant.questions(for: reply.id)) { question in
                UserQuestionView(question: question, session: session, assistant: assistant,
                                 workspace: workspace, preferences: preferences)
            }
            if !reply.status.isEmpty { SelectableText(text: reply.status, font: .systemFont(ofSize: 11), color: .systemOrange, copyOnSelection: preferences.copyOnSelection, onClick: onClick) }
            ForEach(reply.suggestions) { suggestion in
                VStack(alignment: .leading, spacing: 8) {
                    SelectableText(text: suggestion.command, font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: NSColor(theme.text), copyOnSelection: preferences.copyOnSelection, onClick: onClick)
                    SelectableText(text: suggestion.explanation, font: .systemFont(ofSize: 11), color: NSColor(theme.muted), copyOnSelection: preferences.copyOnSelection, onClick: onClick)
                    HStack {
                        if suggestion.state == "pending" {
                            Button("填入终端") { assistant.use(suggestion, session: session) }.disabled(session.running || session.agentOwner != nil)
                            Button("忽略") { assistant.dismiss(suggestion, session: session) }.foregroundStyle(theme.muted)
                        } else { Text(suggestion.state).foregroundStyle(theme.muted) }
                        Spacer()
                        if suggestion.risk != "read" { Text(suggestion.risk == "destructive" ? "删除 / 覆盖" : "修改工作区").foregroundStyle(.orange) }
                    }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(theme.accent)
                }.padding(12).background(theme.accent.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let summary = reply.roundSummary { AIRoundUsageView(summary: summary, theme: theme) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InlineAIBlock: View {
    let block: CommandBlock
    let index: Int
    let showsAvatar: Bool
    @ObservedObject var session: TerminalSession
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsed = false
    @State private var hovered = false
    private var theme: TerminalTheme { preferences.theme }
    private var reply: ChatMessage? { assistant.messages(for: session).first { $0.id == block.assistantReplyID } }
    private var activeReply: Bool { reply.map { assistant.isActiveReply($0, session: session) } ?? false }
    private var activity: CompanionActivity {
        if activeReply { return assistant.activity(for: session) }
        if let reply, reply.activity != .idle { return reply.activity }
        if reply?.status == "已停止" { return .stopped }
        return reply?.status.isEmpty == false ? .attention : .success
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Rectangle().fill(theme.accent.opacity(0.28)).frame(height: 1)
            header
            if block.assistantContinuation != true { HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(theme.accent).frame(width: 13).padding(.top, 3)
                if TextLayoutPolicy.needsViewport(block.command) {
                    LongTextView(text: block.command, font: .systemFont(ofSize: preferences.fontSize), color: NSColor(theme.text), label: "完整提问", copyOnSelection: preferences.copyOnSelection, onClick: focusCurrentInput).frame(height: 120)
                } else {
                    SelectableText(text: block.command, font: .systemFont(ofSize: preferences.fontSize), color: NSColor(theme.text), copyOnSelection: preferences.copyOnSelection, label: "提问", onClick: focusCurrentInput).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 16) }
            if !collapsed {
                HStack(alignment: .top, spacing: 9) {
                    EchoAvatar(action: showsAvatar ? EchoAction(activity: activity, executing: session.running && session.agentOwner != nil && reply?.runID == session.agentOwner) : .history,
                               light: theme.isLight, completedAt: block.finishedAt, arrivalAt: block.assistantContinuation == true ? nil : block.startedAt)
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 12) {
                        if let reply {
                            if activeReply { Text(assistant.phases[session.id] ?? "思考中…").font(.system(size: 10)).foregroundStyle(theme.muted) }
                            AssistantReplyContent(reply: reply, session: session, assistant: assistant, workspace: workspace, preferences: preferences, showSteps: false, onClick: focusCurrentInput)
                        }
                    }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.leading, 10).padding(.trailing, 20)
            }
        }.padding(.bottom, 24).frame(maxWidth: .infinity, alignment: .leading)
            .background(session.selectedBlockID == block.id ? Color.black.opacity(theme.isLight ? 0.035 : 0.16) : theme.accent.opacity(hovered ? 0.035 : 0.015))
            .contentShape(Rectangle()).onTapGesture(perform: focusCurrentInput).onHover { hovered = $0 }
            .accessibilityElement(children: .contain).accessibilityLabel("AI 区块 \(index + 1)，\(String(block.command.prefix(180)))")
    }
    private func focusCurrentInput() { _ = workspace.focusCurrentInput(sessionID: session.id) }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                headerIdentity
                Text("·")
                Text(activity.label).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                stopButton
                headerActions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    headerIdentity
                    Spacer(minLength: 4)
                    headerActions
                }
                HStack(spacing: 8) {
                    Text(activity.label).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    stopButton
                }
            }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.muted)
            .lineLimit(1).buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 5)
    }
    @ViewBuilder private var headerIdentity: some View {
        Text(String(format: "%02d", index + 1)).foregroundStyle(theme.accent)
            .fixedSize(horizontal: true, vertical: false)
        Text("ECHO").tracking(1.5).fixedSize(horizontal: true, vertical: false)
        if let mode = block.assistantMode { Text(mode.title).fixedSize(horizontal: true, vertical: false) }
    }
    @ViewBuilder private var stopButton: some View {
        if activeReply {
            Button("停止 ⌘.") { assistant.cancel(session: session) }
                .foregroundStyle(theme.accent).fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("停止 Echo 当前任务")
        }
    }
    @ViewBuilder private var headerActions: some View {
        Button { collapsed.toggle() } label: {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
        }.help(collapsed ? "展开回答" : "折叠回答")
            .accessibilityLabel(collapsed ? "展开回答" : "折叠回答")
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(block.command + "\n\n" + block.output, forType: .string)
        } label: { Image(systemName: "doc.on.doc") }
            .help("复制对话区块").accessibilityLabel("复制对话区块")
    }
}

struct InlineIntentOptions: View {
    let preview: IntentPreview
    @ObservedObject var session: TerminalSession
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var preferences: Preferences
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                EchoPaw().fill(preferences.theme.muted).frame(width: 12, height: 12).accessibilityHidden(true)
                if preview.loading { Text("正在寻找下一步…").foregroundStyle(preferences.theme.muted) }
                ForEach(preview.options) { option in
                    Button { assistant.chooseIntent(option, session: session, blockID: preview.id) } label: {
                        HStack(spacing: 5) {
                            Text(option.title)
                            Image(systemName: preview.chosenID == option.id ? "checkmark" : "arrow.down.right").font(.system(size: 8))
                        }.padding(.horizontal, 10).padding(.vertical, 7)
                            .background(preferences.theme.accent.opacity(preview.chosenID == option.id ? 0.12 : 0.04)).clipShape(Capsule()).overlay(Capsule().stroke(preferences.theme.accent.opacity(0.14)))
                    }.buttonStyle(.plain).foregroundStyle(preferences.theme.accent)
                        .disabled(preview.chosenID != nil || !assistant.canStartBlock(in: session)).help(option.question)
                }
                if let error = preview.error { Text("建议暂不可用").foregroundStyle(preferences.theme.muted).help(error) }
            }.font(.system(size: 10)).padding(.vertical, 3)
        }.padding(.leading, 39).padding(.trailing, 12).padding(.top, 10).padding(.bottom, 14)
    }
}
