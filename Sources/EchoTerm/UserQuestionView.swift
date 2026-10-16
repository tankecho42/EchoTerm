import SwiftUI

/// The same request is shown in the transcript and in Echo's conversation bubble.
/// Drafts belong to this request; presenting a question never requests keyboard focus.
struct UserQuestionView: View {
    let question: UserQuestion
    @ObservedObject var session: TerminalSession
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    var expandTerminalInput = false
    var draftBinding: Binding<String>? = nil
    @State private var draft = ""
    @State private var submissionError: String?
    @State private var terminalInputExpanded = false
    @FocusState private var inputFocused: Bool

    private var theme: TerminalTheme { preferences.theme }
    private var terminalBound: Bool { question.spec.commandID != nil }
    private var answerDraft: Binding<String> { draftBinding ?? $draft }
    private var text: String { answerDraft.wrappedValue }
    private var showsInputControls: Bool { !terminalBound || expandTerminalInput || terminalInputExpanded || question.state != .pending }
    private var destination: String { terminalBound ? "发送到当前命令" : "回复 Echo" }
    private var answerable: Bool { question.state == .pending && assistant.canAnswerQuestion(question.id) }
    private var controlsEnabled: Bool {
        answerable && !workspace.showSettings && !workspace.pendingQuit && workspace.pendingClose == nil
    }
    private var validation: String? {
        if terminalBound && text.utf8.count > 4_096 { return "命令输入最多 4096 字节（UTF-8）。" }
        if !terminalBound && text.count > 16_000 { return "最多输入 16000 个字符。" }
        if text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) { return "请只输入一行内容。" }
        if terminalBound && text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "命令输入不能包含控制字符。"
        }
        return nil
    }
    private var hasInput: Bool {
        terminalBound ? !text.isEmpty : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var command: CommandBlock? {
        guard let id = question.spec.commandID else { return nil }
        return session.blocks.first { $0.id == id }
    }
    private var status: String {
        switch question.state {
        case .pending: return answerable ? "等待你的回答" : "此问题已失效"
        case .answered: return terminalBound ? "已发送到命令" : "已回复 Echo"
        case .cancelled: return "已取消"
        case .expired: return "此问题已失效"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(destination, systemImage: terminalBound ? "terminal" : "text.bubble")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.accent)
                Spacer(minLength: 0)
            }
            Text(question.spec.question).font(.system(size: max(11, preferences.fontSize - 1)))
                .foregroundStyle(theme.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if terminalBound {
                VStack(alignment: .leading, spacing: 5) {
                    Text("目标命令").font(.system(size: 9)).foregroundStyle(theme.muted)
                    if let command {
                        if TextLayoutPolicy.needsViewport(command.command) {
                            LongTextView(text: command.command, font: preferences.terminalFont,
                                         color: NSColor(theme.text), label: "接收回答的原命令")
                                .frame(height: 100)
                        } else {
                            Text(command.command).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.text).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("原命令已不在当前记录中").font(.system(size: 10)).foregroundStyle(theme.muted)
                    }
                }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
            }
            if terminalBound && question.state == .pending && !expandTerminalInput {
                Button(terminalInputExpanded ? "返回键盘" : "选项 / 文本输入") {
                    terminalInputExpanded.toggle()
                    if !terminalInputExpanded {
                        inputFocused = false; workspace.assistantWantsFocus = false
                        workspace.selectSession(session.id); session.interactiveView = true; session.focus()
                    }
                }.buttonStyle(EchoButtonStyle())
                    .accessibilityLabel(terminalInputExpanded ? "收起辅助输入并返回原生键盘" : "展开此问题的选项与文本输入")
            }
            if showsInputControls && !question.spec.options.isEmpty {
                VStack(spacing: 6) {
                    ForEach(question.spec.options, id: \.id) { option in
                        Button { answer(optionID: option.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.label).font(.system(size: 11, weight: .medium))
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                if terminalBound && option.value.isEmpty {
                                    Text("Return（空行）").font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(theme.muted)
                                }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 11).padding(.vertical, 9)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(theme.accent)
                            .background(theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.accent.opacity(0.18)).allowsHitTesting(false))
                            .opacity(controlsEnabled ? 1 : 0.5).disabled(!controlsEnabled)
                            .accessibilityHint(destination)
                    }
                }
            }
            if showsInputControls && question.spec.allowCustom && question.state == .pending {
                VStack(alignment: .leading, spacing: 7) {
                    TextField(terminalBound ? "输入给当前命令的内容" : "其他回答", text: answerDraft)
                        .textFieldStyle(EchoTextFieldStyle()).font(.system(size: 11))
                        .autocorrectionDisabled(true).onSubmit(submitDraft)
                        .focused($inputFocused)
                        .disabled(!controlsEnabled)
                        .accessibilityLabel(terminalBound ? "发送给当前命令的单行内容" : "回复 Echo 的内容")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { submitButtons; Spacer(minLength: 0) }
                        VStack(alignment: .leading, spacing: 8) { submitButtons }
                    }.buttonStyle(EchoButtonStyle())
                    if let error = validation {
                        Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            if let error = submissionError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
            if question.state == .answered, let response = question.response {
                VStack(alignment: .leading, spacing: 4) {
                    Text("你的回答").font(.system(size: 9)).foregroundStyle(theme.muted)
                    if response.isEmpty && terminalBound {
                        Text("Return（空行）").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text)
                    } else if TextLayoutPolicy.needsViewport(response) {
                        LongTextView(text: response, font: preferences.terminalFont, color: NSColor(theme.text), label: "已提交的回答")
                            .frame(height: 140)
                    } else {
                        Text(response).font(.system(size: 11)).foregroundStyle(theme.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(status).font(.system(size: 9)).foregroundStyle(theme.muted)
                .accessibilityLabel("问题状态：\(status)")
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accent.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.accent.opacity(0.2)).allowsHitTesting(false))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Echo 提问，\(destination)")
            .onChange(of: inputFocused) { _, focused in
                if focused { workspace.selectSession(session.id); workspace.assistantWantsFocus = true }
                else if workspace.activeSession?.id == session.id { workspace.assistantWantsFocus = false }
            }
            .onDisappear { if inputFocused && workspace.activeSession?.id == session.id { workspace.assistantWantsFocus = false } }
    }

    @ViewBuilder private var submitButtons: some View {
        Button(destination, action: submitDraft).disabled(!controlsEnabled || !hasInput || validation != nil)
        if terminalBound {
            Button("仅发送 Return") { answer(text: "") }.disabled(!controlsEnabled)
                .help("向这条命令发送一个空行")
                .accessibilityLabel("向当前命令仅发送 Return 空行")
        }
    }
    private func submitDraft() {
        guard controlsEnabled, hasInput, validation == nil else { return }
        answer(text: text)
    }
    private func answer(optionID: String? = nil, text: String? = nil) {
        guard controlsEnabled else { return }
        if assistant.answerQuestion(question.id, optionID: optionID, text: text) {
            answerDraft.wrappedValue = ""; submissionError = nil
        } else { submissionError = "此问题暂时无法提交，请查看当前状态。" }
    }
}
