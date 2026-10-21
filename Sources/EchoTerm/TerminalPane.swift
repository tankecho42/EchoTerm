import SwiftUI
import AppKit

private struct BlockFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    @ObservedObject var assistant: AssistantStore
    @State private var editorHeight: CGFloat = 24
    @State private var completions: [String] = []
    @State private var completionTask: Task<Void, Never>?
    @State private var visibleBlockID: UUID?
    @State private var followPolicy = TranscriptFollowPolicy()
    @State private var editorFocusRevision = 0
    @State private var explicitInputFocus = false
    @State private var auxiliaryInputVisible = false
    @State private var commandInputDrafts: [UUID: String] = [:]
    @State private var questionInputDrafts: [UUID: String] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: TerminalTheme { preferences.theme }
    private var active: Bool { workspace.activeSession?.id == session.id }
    private var isSplit: Bool { (workspace.activeTab?.root.sessions.count ?? 0) > 1 }
    @State private var assessment = CommandAssessment(isCommand: false)
    private var route: InputRoute { session.inputRoute == .automatic ? (assessment.isCommand ? .shell : .assistant) : session.inputRoute }
    private var completion: String? { completions.first }
    private var commandHistory: [String] { session.blocks.filter { !$0.isAI && !$0.isDemo }.map(\.command) }
    private var completionCandidates: [String] { ShellCommandCatalog.historyCompletions(for: session.draft, history: commandHistory) }
    private var followBottom: Bool {
        get { followPolicy.followsBottom }
        nonmutating set { if newValue { followPolicy.resume() } else { followPolicy.pauseForUserScroll() } }
    }
    private var showsAgentContext: Bool {
        assistant.thinking.contains(session.id) || session.inputRoute == .assistant ||
        (!session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && route == .assistant)
    }
    var body: some View {
        let latestAIBlockID = session.blocks.last(where: \.isAI)?.id
        let contextDisplay = showsAgentContext ? AgentContextDisplay(selection: assistant.contextSelection(for: session), blocks: session.blocks) : nil
        return VStack(spacing: 0) {
            if isSplit { paneHeader }
            GeometryReader { viewport in
                if session.presentsInteractiveTerminal {
                    interactiveTerminal(viewportHeight: viewport.size.height, contextDisplay: contextDisplay)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(session.blocks.enumerated()), id: \.element.id) { index, block in
                                        VStack(spacing: 0) {
                                            if let contextDisplay, contextDisplay.selection.isSharingEnabled,
                                               contextDisplay.selection.firstBlockID == block.id {
                                                AgentContextBoundary(display: contextDisplay, theme: theme,
                                                                     enabled: !workspace.inputBlockedByModal && !session.exited,
                                                                     shift: { shiftContextBoundary($0, reader: reader) })
                                            }
                                            if block.isAI {
                                                InlineAIBlock(block: block, index: index, showsAvatar: block.id == latestAIBlockID, session: session, assistant: assistant, workspace: workspace, preferences: preferences)
                                            } else {
                                                blockView(block, index: index)
                                                if let preview = assistant.blockIntents[block.id], preferences.quickIntents {
                                                    InlineIntentOptions(preview: preview, session: session, assistant: assistant, preferences: preferences)
                                                }
                                            }
                                        }.overlay(alignment: .leading) {
                                            if let marker = block.marker {
                                                Rectangle().fill(marker.color(light: theme.isLight)).frame(width: 2)
                                                    .padding(.top, 1).allowsHitTesting(false).accessibilityHidden(true)
                                            }
                                        }
                                        .modifier(BlockRevealHighlight(reveal: session.blockReveal?.blockID == block.id ? session.blockReveal : nil, theme: theme))
                                        .background(GeometryReader { geo in Color.clear.preference(key: BlockFrames.self, value: [block.id: geo.frame(in: .named(session.id))]) }).id(block.id)
                                    }
                                }
                                // Keep the current editor mounted when historical blocks are offscreen.
                                if assistant.canStartBlock(in: session) && !session.exited { inputBlock.id(session.inputBlockID) }
                                if let contextDisplay {
                                    contextControl(contextDisplay).padding(.leading, 39).padding(.trailing, 16)
                                        .padding(.top, 1).padding(.bottom, 18)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                if session.exited || session.shellError != nil {
                                    HStack { Text(session.shellError ?? "Shell 会话已结束"); Spacer(); Button("新建会话") { workspace.addTab(directory: session.directory) } }.font(.system(size: 11)).padding(20).foregroundStyle(theme.muted)
                                }
                                Color.clear.frame(height: 0).id("end")
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                                .background(TranscriptScrollObserver(userScrolledUp: { followPolicy.pauseForUserScroll() }) { metrics, movedUp in
                                    var policy = followPolicy
                                    if session.readingAnchorID != nil { policy.pauseForUserScroll() }
                                    else { policy.observe(metrics, movedUp: movedUp) }
                                    let correctBottom = session.readingAnchorID == nil && policy.takeGeometryCorrection(metrics)
                                    if policy != followPolicy { followPolicy = policy }
                                    if correctBottom {
                                        reader.scrollTo("end", anchor: .bottom)
                                    }
                                })
                        }
                        .contentMargins(.all, 0, for: .scrollContent)
                        .coordinateSpace(name: session.id)
                        .onAppear {
                            if let id = session.readingAnchorID { reader.scrollTo(id, anchor: .top) }
                            else if followBottom { scrollToCurrent(reader) }
                        }
                        .onPreferenceChange(BlockFrames.self) { frames in
                            let next = session.blocks.first { block in guard let frame = frames[block.id] else { return false }; return frame.maxY > 50 && frame.minY < viewport.size.height }?.id
                            if next != visibleBlockID { visibleBlockID = next }
                        }
                        .onChange(of: session.selectedBlockID) { _, id in
                            if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { reader.scrollTo(id, anchor: .top) } }
                        }
                        .onChange(of: session.blocks.count) { _, _ in
                            guard followBottom, session.readingAnchorID == nil else { return }
                            scrollToCurrent(reader)
                        }
                        .task(id: session.blockReveal?.id) {
                            guard let target = session.readingAnchorID else { return }
                            followBottom = false
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { reader.scrollTo(target, anchor: .top) }
                        }
                        .onChange(of: editorFocusRevision) { _, _ in
                            // Successful editor focus is the one-time completion / explicit-click
                            // return to the newest input, even when live output was paused.
                            followBottom = true
                            followPolicy.requestFollow()
                            reader.scrollTo("end", anchor: .bottom)
                        }
                        .onChange(of: workspace.currentInputFocusRequest) { _, _ in
                            guard workspace.currentInputFocusSessionID == session.id, !session.running else { return }
                            followBottom = true
                            scrollToCurrent(reader)
                        }
                        .onChange(of: session.liveOutput) { _, _ in if followPolicy.requestFollow() { reader.scrollTo("end", anchor: .bottom) } }
                        .onChange(of: assistant.messages(for: session).last?.text) { _, _ in if followPolicy.requestFollow() { reader.scrollTo("end", anchor: .bottom) } }
                        .overlay(alignment: .trailing) {
                            // The floating rail overlays the full-width transcript; it reserves no gutter.
                            if !session.blocks.isEmpty {
                                BlockTimeline(blocks: session.blocks, selectedID: session.selectedBlockID ?? visibleBlockID, theme: theme, previewWidth: min(255, max(120, viewport.size.width - 70))) { id in
                                    workspace.revealBlock(sessionID: session.id, blockID: id)
                                }
                            }
                        }
                        .overlay(alignment: .topTrailing) { if session.showSearch { BlockSearch(session: session, preferences: preferences, assistant: assistant, workspace: workspace).padding(12) } }
                    }
                }
            }
        }
        .overlay(alignment: .top) { if isSplit { Rectangle().fill(active ? theme.accent.opacity(0.28) : theme.line).frame(height: 1) } }
        .onAppear { session.usesBlockEditor = true; session.start(); if active { session.focus() } }
        .onDisappear { completionTask?.cancel() }
        .onChange(of: active) { _, value in
            if value { session.focus() } else { explicitInputFocus = false }
        }
        .onChange(of: workspace.currentInputFocusRequest) { _, _ in
            if workspace.currentInputFocusSessionID == session.id { explicitInputFocus = !session.running }
        }
        .onChange(of: assistant.canStartBlock(in: session)) { _, ready in
            if ready && inputMayAutomaticallyFocus { session.focus() }
        }
        .onChange(of: inputMayAutomaticallyFocus) { _, allowed in if !allowed { explicitInputFocus = false } }
        .onChange(of: session.ready) { _, value in if value && active { session.focus() } }
        .onChange(of: session.presentsInteractiveTerminal) { _, presented in
            // The transcript observers are detached while the native viewport
            // runs. Start that view following the live command, unless a block
            // was explicitly pinned; returning to history can opt out again.
            if presented && session.readingAnchorID == nil { followBottom = true }
        }
        .onChange(of: session.runningBlockID) { _, _ in auxiliaryInputVisible = false }
        .onChange(of: session.commandCatalog.names) { _, _ in updateCompletions() }
        .onChange(of: session.directory) { _, _ in updateCompletions() }
        .onChange(of: session.draft) { _, _ in
            if session.agentOwner == nil && !session.running && !session.draft.isEmpty { session.resumeInput(); session.selectedBlockID = nil }
            updateCompletions()
        }
    }
    private func interactiveTerminal(viewportHeight: CGFloat, contextDisplay: AgentContextDisplay?) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(theme.accent)
                    Text(session.blocks.first(where: { $0.id == session.runningBlockID })?.command ?? "终端")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(auxiliaryInputVisible ? "辅助输入" : "键盘输入").foregroundStyle(theme.muted)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let contextDisplay { contextControl(contextDisplay) }
                HStack(spacing: 12) {
                    Button(auxiliaryInputTitle) {
                        if auxiliaryInputVisible { returnToKeyboard() }
                        else { auxiliaryInputVisible = true }
                    }.foregroundStyle(theme.accent)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(auxiliaryInputVisible ? "收起辅助输入，直接向当前命令键入" : "显示选项、文本输入与按键按钮")
                    if !session.alternateScreen {
                        Button("返回区块") {
                            auxiliaryInputVisible = false; workspace.assistantWantsFocus = false
                            session.interactiveView = false
                        }.foregroundStyle(theme.muted).fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                    Button {
                        if session.agentOwner != nil { assistant.cancel(session: session) }
                        else { session.interrupt() }
                    } label: { Image(systemName: "stop.fill").frame(width: 20, height: 20) }
                        .foregroundStyle(theme.accent)
                        .help(session.agentOwner != nil ? "停止 Echo 当前任务  ⌘." : "中断当前命令  ⌃C")
                        .accessibilityLabel(session.agentOwner != nil ? "停止 Echo 当前任务" : "中断当前命令")
                }
                .buttonStyle(.plain).lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 10, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 8)
            Rectangle().fill(theme.line).frame(height: 1)
            TerminalHost(session: session, preferences: preferences,
                         active: active && !workspace.assistantWantsFocus && !auxiliaryInputVisible,
                         nativeInputAllowed: active && !workspace.assistantWantsFocus,
                         onNativeFocusRequested: {
                             guard !workspace.showSettings && !workspace.pendingQuit && workspace.pendingClose == nil else { return }
                             returnToKeyboard()
                         })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if auxiliaryInputVisible, let blockID = session.runningBlockID {
                Rectangle().fill(theme.line).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pendingQuestions) { question in
                            UserQuestionView(question: question, session: session, assistant: assistant,
                                             workspace: workspace, preferences: preferences, expandTerminalInput: true,
                                             draftBinding: questionDraft(question.id))
                        }
                        RunningCommandInput(blockID: blockID, draft: commandDraft(blockID), session: session,
                                            workspace: workspace, assistant: assistant, preferences: preferences)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(260, max(84, viewportHeight * 0.42)))
                    .accessibilityLabel("当前命令的辅助输入")
            }
        }
    }
    private var pendingQuestions: [UserQuestion] {
        assistant.userQuestions.values.filter { $0.sessionID == session.id && $0.state == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }
    private var auxiliaryInputTitle: String {
        if auxiliaryInputVisible { return "返回键盘" }
        return pendingQuestions.isEmpty ? "辅助输入" : "辅助输入 ·\(pendingQuestions.count)"
    }
    private func commandDraft(_ blockID: UUID) -> Binding<String> {
        Binding(get: { commandInputDrafts[blockID] ?? "" }, set: { commandInputDrafts[blockID] = $0 })
    }
    private func questionDraft(_ questionID: UUID) -> Binding<String> {
        Binding(get: { questionInputDrafts[questionID] ?? "" }, set: { questionInputDrafts[questionID] = $0 })
    }
    private func returnToKeyboard() {
        auxiliaryInputVisible = false; workspace.assistantWantsFocus = false
        workspace.selectSession(session.id); session.interactiveView = true; session.focus()
    }
    private var paneHeader: some View {
        HStack(spacing: 7) {
            Circle().fill(active ? theme.accent : theme.muted.opacity(0.25)).frame(width: 4, height: 4)
            Text("S\(workspace.sessionIndex(session.id) ?? 1)").foregroundStyle(theme.accent)
            Text(session.displayDirectory).lineLimit(1).truncationMode(.middle)
            Spacer(); Text(session.shellName)
            IconButton("xmark", help: "关闭面板") { workspace.closeSession(session.id) }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.muted).padding(.leading, 14).padding(.trailing, 5).frame(height: 28)
    }
    private func blockView(_ block: CommandBlock, index: Int) -> some View {
        let running = block.id == session.runningBlockID && session.running
        return TerminalBlockRow(block: block, index: index, selected: session.selectedBlockID == block.id,
                                running: running, liveOutput: session.liveOutput, preferences: preferences,
                                select: { workspace.focusCurrentInput(sessionID: session.id) },
                                reuse: { _ = session.insert(block.command) },
                                explain: { workspace.selectSession(session.id); assistant.explain(block, session: session) },
                                interrupt: { if session.agentOwner != nil { assistant.cancel(session: session) } else { session.interrupt() } },
                                interactive: { session.interactiveView.toggle(); if session.interactiveView { session.focus() } }) {
            if running {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { runningInputButtons; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { runningInputButtons }
                }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(theme.accent)
            }
        }
    }
    @ViewBuilder private var runningInputButtons: some View {
        Button("键盘输入") { returnToKeyboard() }
        Button("辅助输入") {
            workspace.selectSession(session.id); auxiliaryInputVisible = true; session.interactiveView = true
        }
    }
    private var inputBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(theme.accent.opacity(active ? 0.38 : 0.16)).frame(height: 1)
            HStack(spacing: 9) {
                Text(String(format: "%02d", session.blocks.count + 1)).foregroundStyle(theme.accent.opacity(0.75))
                Text(session.displayDirectory).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                EchoChoicePicker(selection: $session.inputRouteOverride,
                                   choices: [EchoChoice<InputRoute?>(value: nil, title: "默认 · " + session.defaultInputRoute.title)] + InputRoute.allCases.map { .init(value: Optional($0), title: $0.title) },
                                   label: "本 Block 输入方式").frame(width: 125, height: 22)
                Text(session.agentOwner != nil ? "Echo 操作中" : session.ready ? session.shellName : "连接中…")
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.muted).padding(.horizontal, 16).padding(.top, 5)
            HStack(alignment: .top, spacing: 10) {
                Text("❯").font(.system(size: preferences.fontSize, weight: .medium, design: .monospaced)).foregroundStyle(theme.accent).padding(.top, 1)
                InlineCommandEditor(text: $session.draft, height: $editorHeight, font: preferences.terminalFont, color: NSColor(theme.text), caret: NSColor(theme.accent), focusRequest: session.focusRequest,
                                    enabled: session.ready && active && session.agentOwner == nil && !workspace.inputBlockedByModal,
                                    automaticallyFocus: inputMayAutomaticallyFocus,
                                    explicitFocus: explicitInputFocus, focusOwnerID: session.id,
                                    completion: completion, completionCandidates: completionCandidates, commandAssessment: assessment,
                                    onForcedSubmit: { submit($0) },
                                    onSubmit: { submit() }, onHistory: { session.history($0) },
                                    onFocus: {
                                        explicitInputFocus = false
                                        session.resumeInput(); workspace.assistantWantsFocus = false
                                        session.selectedBlockID = nil; workspace.selectSession(session.id)
                                        editorFocusRevision += 1
                                    },
                                    onCancel: { session.draft = "" })
                    .frame(height: editorHeight)
            }.padding(.horizontal, 16)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { inputHint; Spacer(minLength: 5); AssistantModeControl(preferences: preferences, mode: assistantMode, compact: true) }
                VStack(alignment: .leading, spacing: 8) { inputHint; AssistantModeControl(preferences: preferences, mode: assistantMode, compact: true) }
            }.padding(.leading, 39).padding(.trailing, 16)
            if let error = session.insertionError { Text(error).font(.system(size: 10)).foregroundStyle(.orange).padding(.horizontal, 16) }
        }.padding(.bottom, 22).frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accent.opacity(session.selectedBlockID == nil && active ? 0.025 : 0))
            .contentShape(Rectangle())
            .onTapGesture { workspace.focusCurrentInput(sessionID: session.id) }
    }
    private var inputMayAutomaticallyFocus: Bool {
        active && session.ready && !session.exited && session.readingAnchorID == nil &&
        !workspace.assistantWantsFocus && !workspace.inputBlockedByModal && !session.showSearch
    }
    private func contextControl(_ display: AgentContextDisplay) -> some View {
        AgentContextControl(display: display, theme: theme, enabled: !workspace.inputBlockedByModal && !session.exited,
                            setStart: { _ = assistant.setContextStart(index: $0, for: session) },
                            shift: shiftContextBoundary,
                            openSettings: { workspace.showSettings = true })
    }
    private func shiftContextBoundary(_ delta: Int) { _ = assistant.shiftContextBoundary(by: delta, for: session) }
    private func shiftContextBoundary(_ delta: Int, reader: ScrollViewProxy) {
        guard assistant.shiftContextBoundary(by: delta, for: session), let firstID = session.contextStartBlockID else { return }
        followBottom = false
        Task { @MainActor in
            await Task.yield()
            guard session.contextStartBlockID == firstID, !assistant.thinking.contains(session.id) else { return }
            reader.scrollTo(firstID, anchor: .top)
        }
    }
    private var inputHint: some View {
        HStack(spacing: 7) {
            if session.draft.isEmpty {
                Text("命令，或直接问 Echo")
                if !completionCandidates.isEmpty { Text("· ↑↓ 历史 · Tab 候选") }
            }
            else {
                Image(systemName: route == .shell ? "return" : "sparkle")
                Text(route == .shell ? (assessment.dynamic ? "Return · 交给 Shell 解析" : "Return · 执行命令") : "Return · 发送给 Echo")
                if completion != nil { Text("· → 接受预览") }
                if !completionCandidates.isEmpty { Text("· Tab 历史候选") }
            }
        }.font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true).help("↑↓ 按已输入前缀查历史 · Tab 展示历史候选 · → 在行尾接受预览 · 菜单内 → 或 Return 只补全，不执行")
    }
    private var assistantMode: Binding<AssistantMode> { Binding(get: { assistant.mode(for: session) }, set: { assistant.setMode($0, session: session) }) }
    private func submit(_ forced: InputRoute? = nil) {
        if assistant.submitInput(session: session, forced: forced) { completions = [] }
    }
    private func updateCompletions() {
        completionTask?.cancel(); completions = []
        assessment = session.commandCatalog.assess(session.draft, directory: session.directory)
        let draft = session.draft, catalog = session.commandCatalog, directory = session.directory
        guard draft.utf8.count <= 4_000 else { return }
        let history = commandHistory
        completionTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 55_000_000) } catch { return }
            let next = await Task.detached(priority: .userInitiated) { catalog.completions(for: draft, directory: directory, history: history) }.value
            guard !Task.isCancelled, session.draft == draft else { return }; completions = next
        }
    }
    private func scrollToCurrent(_ reader: ScrollViewProxy) {
        guard followPolicy.requestFollow() else { return }
        DispatchQueue.main.async {
            guard followBottom, session.readingAnchorID == nil else { return }
            if reduceMotion { reader.scrollTo("end", anchor: .bottom) }
            else { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("end", anchor: .bottom) } }
        }
    }
}

/// Manual input is always an explicit affordance, independent of output heuristics.
private struct RunningCommandInput: View {
    let blockID: UUID
    @Binding var draft: String
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var preferences: Preferences
    @State private var error: String?
    @FocusState private var inputFocused: Bool
    private var theme: TerminalTheme { preferences.theme }
    private var enabled: Bool {
        session.running && session.runningBlockID == blockID && !session.exited &&
        !workspace.showSettings && !workspace.pendingQuit && workspace.pendingClose == nil
    }
    private var validation: String? {
        if draft.utf8.count > 4_096 { return "命令输入最多 4096 字节（UTF-8）。" }
        if draft.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "请只输入一行内容，不含控制字符。"
        }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("发送到当前命令").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.accent)
            Text(session.agentOwner != nil ? "Echo 正在执行这条命令。文本会附带 Return 一起发送。" : "文本会附带 Return 发送到这条命令。")
                .font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            TextField("单行输入", text: $draft).textFieldStyle(EchoTextFieldStyle())
                .font(Font(preferences.terminalFont)).autocorrectionDisabled(true).focused($inputFocused)
                .onSubmit(sendDraft).disabled(!enabled)
                .accessibilityLabel("发送给当前运行命令的单行内容")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { actions; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 7) { actions }
            }.buttonStyle(EchoButtonStyle())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 85), spacing: 6)], alignment: .leading, spacing: 6) {
                Button("y + Return") { send("y") }.accessibilityLabel("向当前命令发送 y 并按 Return")
                Button("n + Return") { send("n") }.accessibilityLabel("向当前命令发送 n 并按 Return")
                Button("Return") { send("") }.accessibilityLabel("向当前命令仅发送 Return 空行")
            }.buttonStyle(EchoButtonStyle()).disabled(!enabled)
            Text("单独按键").font(.system(size: 9)).foregroundStyle(theme.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], alignment: .leading, spacing: 6) {
                keyButton("↑", key: .up, label: "上方向键")
                keyButton("↓", key: .down, label: "下方向键")
                keyButton("←", key: .left, label: "左方向键")
                keyButton("→", key: .right, label: "右方向键")
                keyButton("Tab", key: .tab, label: "Tab 键")
                keyButton("Esc", key: .escape, label: "Escape 键")
            }.buttonStyle(EchoButtonStyle()).disabled(!enabled)
            if let message = validation ?? error {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: inputFocused) { _, focused in
                if focused { workspace.selectSession(session.id); workspace.assistantWantsFocus = true }
                else if workspace.activeSession?.id == session.id { workspace.assistantWantsFocus = false }
            }
            .onDisappear { if inputFocused && workspace.activeSession?.id == session.id { workspace.assistantWantsFocus = false } }
    }
    private func keyButton(_ title: String, key: TerminalInputKey, label: String) -> some View {
        Button(title) {
            guard enabled else { return }
            if assistant.sendCommandKey(key, session: session, expectedBlockID: blockID) { error = nil }
            else { error = "此命令已结束或按键不可用。" }
        }.accessibilityLabel("向当前命令发送\(label)")
    }
    @ViewBuilder private var actions: some View {
        Button("发送", action: sendDraft).disabled(!enabled || draft.isEmpty || validation != nil)
        Button("中断 ⌃C") {
            if session.agentOwner != nil { assistant.cancel(session: session) }
            else { session.interrupt() }
        }.disabled(!enabled).foregroundStyle(.orange)
            .accessibilityLabel("中断当前命令")
    }
    private func sendDraft() {
        guard !draft.isEmpty, validation == nil else { return }
        send(draft)
    }
    private func send(_ text: String) {
        guard enabled else { return }
        if assistant.sendCommandInput(text, session: session, expectedBlockID: blockID) { draft = ""; error = nil }
        else { error = "此命令已结束或输入不可用。" }
    }
}

private struct TerminalBlockRow<Interaction: View>: View {
    let block: CommandBlock
    let index: Int
    let selected: Bool
    let running: Bool
    let liveOutput: String
    @ObservedObject var preferences: Preferences
    let select: () -> Void
    let reuse: () -> Void
    let explain: () -> Void
    let interrupt: () -> Void
    let interactive: () -> Void
    @ViewBuilder var interaction: () -> Interaction
    @State private var hovered = false
    @State private var collapsed = false
    private var theme: TerminalTheme { preferences.theme }
    private var output: String { running ? liveOutput : block.output }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(theme.text.opacity(hovered ? 0.24 : 0.14)).frame(height: 1)
            HStack(spacing: 9) {
                Text(String(format: "%02d", index + 1)).foregroundStyle(selected ? theme.accent : theme.muted.opacity(0.6))
                Text(block.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 5)
                if hovered || selected {
                    if running {
                        Button(action: interactive) { Image(systemName: "keyboard") }.help("交互视图")
                        Button(action: interrupt) { Image(systemName: "stop.fill") }.help("停止命令  ⌃C")
                    } else {
                        Button(action: reuse) { Image(systemName: "arrow.uturn.backward") }.help("填入这条命令")
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.command + "\n" + block.output, forType: .string) } label: { Image(systemName: "doc.on.doc") }.help("复制区块")
                        Button { collapsed.toggle() } label: { Image(systemName: collapsed ? "chevron.down" : "chevron.up") }.help(collapsed ? "展开输出" : "折叠输出")
                    }
                    Button(action: explain) { Image(systemName: "sparkle") }.help("和 Echo 一起看这个区块")
                }
                if block.assistantRunID != nil { Text("Echo").foregroundStyle(theme.accent).help("由助手执行的命令") }
                if running { ProgressView().controlSize(.mini) }
                else {
                    Text(block.exitCode == 0 ? "✓" : "exit \(block.exitCode ?? -1)").foregroundStyle(block.exitCode == 0 ? theme.muted : .orange)
                    Text(block.duration).foregroundStyle(theme.muted.opacity(0.6))
                }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.muted).buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 5)
            HStack(alignment: .top, spacing: 10) {
                Text("❯").foregroundStyle(theme.accent.opacity(selected || hovered ? 1 : 0.7))
                if TextLayoutPolicy.needsViewport(block.command) {
                    LongTextView(text: block.command, font: preferences.terminalFont, color: NSColor(theme.text), label: "完整命令", copyOnSelection: preferences.copyOnSelection, onClick: select).frame(height: 120)
                } else {
                    SelectableText(text: block.command, font: preferences.terminalFont, color: NSColor(theme.text.opacity(selected || hovered ? 0.97 : 0.83)), copyOnSelection: preferences.copyOnSelection, label: "命令", onClick: select).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(Font(preferences.terminalFont)).padding(.horizontal, 16)
            if !collapsed && !output.isEmpty {
                BlockOutput(text: output, font: preferences.terminalFont, color: theme.text.opacity(selected || hovered ? 0.9 : 0.7), copyOnSelection: preferences.copyOnSelection, followOutput: running, onClick: select)
                    .padding(.leading, 39).padding(.trailing, 16)
            }
            if collapsed { Text("输出已折叠").font(.system(size: 10)).foregroundStyle(theme.muted).padding(.leading, 39) }
            interaction().padding(.horizontal, 16)
        }.padding(.bottom, 22).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.black.opacity(theme.isLight ? 0.045 : 0.2) : (hovered ? theme.text.opacity(0.035) : .clear))
            .overlay(alignment: .leading) { if selected { Rectangle().fill(theme.accent.opacity(0.65)).frame(width: 2).padding(.vertical, 14) } }
            .contentShape(Rectangle()).onTapGesture(perform: select).onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .accessibilityElement(children: .contain).accessibilityLabel("区块 \(index + 1)，\(selected ? "已选中，" : "")\(String(block.command.prefix(180)))")
    }
}

private struct BlockOutput: View {
    let text: String
    let font: NSFont
    let color: Color
    var copyOnSelection = false
    var followOutput = false
    var onClick: (() -> Void)? = nil
    var body: some View {
        if TextLayoutPolicy.needsViewport(text) {
            LongTextView(text: text, font: font, color: NSColor(color), label: "完整命令输出", copyOnSelection: copyOnSelection, followOutput: followOutput, onClick: onClick).frame(height: 300)
        } else {
            SelectableText(text: text, font: font, color: NSColor(color), copyOnSelection: copyOnSelection, label: "命令输出", lineSpacing: 3, onClick: onClick).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences: Preferences
    var active: Bool
    var nativeInputAllowed: Bool? = nil
    var onNativeFocusRequested: () -> Void = { }
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> TerminalViewport { TerminalViewport(terminal: session.terminal) }
    func updateNSView(_ viewport: TerminalViewport, context: Context) {
        let view = viewport.terminal
        let font = preferences.terminalFont
        if view.font != font { view.font = font }
        let background = preferences.theme.background.withAlphaComponent(preferences.opacity)
        if view.nativeBackgroundColor != background { view.nativeBackgroundColor = background }
        let foreground = NSColor(preferences.theme.text)
        if view.nativeForegroundColor != foreground { view.nativeForegroundColor = foreground }
        view.caretColor = NSColor(preferences.theme.accent)
        view.applyPalette(preferences.theme)
        let allowsNativeInput = (nativeInputAllowed ?? active) && isEnabled
        let shouldFocus = active && allowsNativeInput
        let wasAllowed = view.keyboardFocusAllowed
        view.nativeInputAllowed = allowsNativeInput
        view.onNativeFocusRequested = onNativeFocusRequested
        view.keyboardFocusAllowed = shouldFocus
        if !allowsNativeInput, let window = view.window, window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
        if shouldFocus && !wasAllowed { view.requestKeyboardFocus() }
    }
    static func dismantleNSView(_ view: TerminalViewport, coordinator: ()) {
        view.terminal.keyboardFocusAllowed = false
        view.terminal.nativeInputAllowed = false
        view.terminal.onNativeFocusRequested = nil
        if let window = view.terminal.window, window.firstResponder === view.terminal {
            window.makeFirstResponder(nil)
        }
    }
}

/// One bounded native viewport, outside the transcript's lazy scroll layout.
/// Assigning `frame` invokes SwiftTerm's grid resize and the PTY's SIGWINCH path.
final class TerminalViewport: NSView {
    let terminal: BlockTerminalView
    init(terminal: BlockTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        addSubview(terminal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        if bounds.width > 0 && bounds.height > 0 && terminal.frame != bounds {
            terminal.frame = bounds
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { terminal.requestKeyboardFocus() }
    }
}
struct BlockSearch: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences: Preferences
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var workspace: Workspace
    @FocusState private var focused: Bool
    private var theme: TerminalTheme { preferences.theme }
    private var results: [CommandBlock] { session.blocks.reversed().filter { session.search.isEmpty || $0.command.localizedCaseInsensitiveContains(session.search) || $0.output.localizedCaseInsensitiveContains(session.search) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
                TextField("查找命令或输出", text: $session.search).textFieldStyle(.plain).focused($focused)
                Text("\(results.count)").foregroundStyle(theme.muted)
                IconButton("xmark", help: "收起搜索") { session.showSearch = false; session.focus() }
            }.font(.system(size: 12)).padding(12)
            Divider().opacity(0.35)
            if let error = session.insertionError { Text(error).font(.system(size: 10)).foregroundStyle(theme.muted).padding(12) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty { Text("没有匹配的区块").font(.system(size: 12)).foregroundStyle(theme.muted).padding(18) }
                    ForEach(results) { block in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .top) {
                                Image(systemName: block.exitCode == 0 ? "checkmark" : "circle").font(.system(size: 9)).foregroundStyle(block.exitCode == 0 ? theme.accent : .orange)
                                SelectableText(text: block.command, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: NSColor(theme.text), copyOnSelection: preferences.copyOnSelection, label: "搜索结果命令")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer()
                                Text(block.duration).font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.muted)
                            }
                            if !block.output.isEmpty {
                                DisclosureGroup("输出") {
                                    LongTextView(text: block.output, font: .monospacedSystemFont(ofSize: 11, weight: .regular), color: NSColor(theme.text), label: "搜索结果输出", copyOnSelection: preferences.copyOnSelection).frame(height: 200)
                                }.font(.system(size: 10)).foregroundStyle(theme.muted)
                            }
                            HStack(spacing: 14) {
                                Button("填入命令") { if session.insert(block.command) { session.showSearch = false } }.disabled(session.running)
                                Button("复制输出") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.output, forType: .string) }
                                Button("问 Echo") { workspace.presentAssistant(for: session.id); session.showSearch = false; assistant.explain(block, session: session) }
                                Spacer()
                            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(theme.accent)
                        }.padding(14)
                        Divider().opacity(0.25)
                    }
                }
            }.frame(maxHeight: 350)
        }.frame(width: 400).background(theme.base.opacity(0.98)).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.line)).shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            .task { try? await Task.sleep(nanoseconds: 80_000_000); focused = true }
            .onExitCommand { session.showSearch = false; session.focus() }
    }
}
