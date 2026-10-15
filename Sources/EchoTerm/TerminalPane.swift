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
    @State private var completionIndex = 0
    @State private var completionTask: Task<Void, Never>?
    @State private var visibleBlockID: UUID?
    @State private var followBottom = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var theme: TerminalTheme { preferences.theme }
    private var active: Bool { workspace.activeSession?.id == session.id }
    private var isSplit: Bool { (workspace.activeTab?.root.sessions.count ?? 0) > 1 }
    @State private var assessment = CommandAssessment(isCommand: false)
    private var route: InputRoute { session.inputRoute == .automatic ? (assessment.isCommand ? .shell : .assistant) : session.inputRoute }
    private var completion: String? { completions.indices.contains(completionIndex) ? completions[completionIndex] : nil }
    var body: some View {
        let latestAIBlockID = session.blocks.last(where: \.isAI)?.id
        return VStack(spacing: 0) {
            if isSplit { paneHeader }
            GeometryReader { viewport in
                if session.presentsInteractiveTerminal {
                    interactiveTerminal
                        .frame(width: viewport.size.width, height: viewport.size.height)
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(session.blocks.enumerated()), id: \.element.id) { index, block in
                                    VStack(spacing: 0) {
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
                                if assistant.canStartBlock(in: session) && !session.exited { inputBlock.id(session.inputBlockID) }
                                if session.exited || session.shellError != nil {
                                    HStack { Text(session.shellError ?? "Shell 会话已结束"); Spacer(); Button("新建会话") { workspace.addTab(directory: session.directory) } }.font(.system(size: 11)).padding(20).foregroundStyle(theme.muted)
                                }
                                Color.clear.frame(height: 0).id("end")
                            }.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .contentMargins(.all, 0, for: .scrollContent)
                        .coordinateSpace(name: session.id)
                        .onAppear {
                            if let id = session.readingAnchorID { reader.scrollTo(id, anchor: .top) }
                            else { scrollToCurrent(reader) }
                        }
                        .background(ScrollActivityObserver { if followBottom { followBottom = false } })
                        .onPreferenceChange(BlockFrames.self) { frames in
                            let next = session.blocks.first { block in guard let frame = frames[block.id] else { return false }; return frame.maxY > 50 && frame.minY < viewport.size.height }?.id
                            if next != visibleBlockID { visibleBlockID = next }
                        }
                        .simultaneousGesture(DragGesture(minimumDistance: 3).onChanged { _ in followBottom = false })
                        .onChange(of: session.selectedBlockID) { _, id in
                            if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { reader.scrollTo(id, anchor: .top) } }
                        }
                        .onChange(of: session.blocks.count) { _, _ in
                            guard session.readingAnchorID == nil else { return }
                            followBottom = true; scrollToCurrent(reader)
                        }
                        .task(id: session.blockReveal?.id) {
                            guard let target = session.readingAnchorID else { return }
                            followBottom = false
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { reader.scrollTo(target, anchor: .top) }
                        }
                        .onChange(of: assistant.canStartBlock(in: session)) { _, ready in
                            guard ready, followBottom, session.readingAnchorID == nil,
                                  session.selectedBlockID == nil || session.selectedBlockID == session.blocks.last?.id else { return }
                            if active && !workspace.assistantWantsFocus && !workspace.showSettings && !workspace.pendingQuit && workspace.pendingClose == nil {
                                session.selectedBlockID = nil
                                session.focus()
                            } else { scrollToCurrent(reader) }
                        }
                        .onChange(of: session.focusRequest) { _, _ in
                            if !session.running {
                                if let selected = session.selectedBlockID {
                                    followBottom = false
                                    reader.scrollTo(selected, anchor: .top)
                                } else { followBottom = true; scrollToCurrent(reader) }
                            }
                        }
                        .onChange(of: session.liveOutput) { _, _ in if followBottom { reader.scrollTo("end", anchor: .bottom) } }
                        .onChange(of: assistant.messages(for: session).last?.text) { _, _ in if followBottom { reader.scrollTo("end", anchor: .bottom) } }
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
        .onChange(of: active) { _, value in if value { session.focus() } }
        .onChange(of: session.ready) { _, value in if value && active { session.focus() } }
        .onChange(of: session.commandCatalog.names) { _, _ in updateCompletions() }
        .onChange(of: session.directory) { _, _ in updateCompletions() }
        .onChange(of: session.draft) { _, _ in
            if session.agentOwner == nil && !session.running && !session.draft.isEmpty { session.resumeInput(); session.selectedBlockID = nil }
            updateCompletions()
        }
    }
    private var interactiveTerminal: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "terminal").foregroundStyle(theme.accent)
                Text(session.blocks.first(where: { $0.id == session.runningBlockID })?.command ?? "终端")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("交互终端").foregroundStyle(theme.muted)
                if !session.alternateScreen {
                    Button("返回区块") { session.interactiveView = false; session.focus() }
                        .buttonStyle(.plain).foregroundStyle(theme.accent)
                }
            }.font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 12).frame(height: 29)
            Rectangle().fill(theme.line).frame(height: 1)
            TerminalHost(session: session, preferences: preferences, active: active && !workspace.assistantWantsFocus)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(session.agentOwner == nil)
        }
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
                                select: { workspace.assistantWantsFocus = false; workspace.selectSession(session.id); session.selectedBlockID = block.id },
                                reuse: { _ = session.insert(block.command) },
                                explain: { workspace.selectSession(session.id); assistant.explain(block, session: session) },
                                interrupt: { if session.agentOwner != nil { assistant.cancel(session: session) } else { session.interrupt() } },
                                interactive: { session.interactiveView.toggle(); if session.interactiveView { session.focus() } }) {
            if running {
                RunningCommandInput(blockID: block.id, session: session, workspace: workspace,
                                    assistant: assistant, preferences: preferences).id(block.id)
            }
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
                InlineCommandEditor(text: $session.draft, height: $editorHeight, font: preferences.terminalFont, color: NSColor(theme.text), caret: NSColor(theme.accent), focusRequest: session.focusRequest, enabled: session.ready && active && session.agentOwner == nil && !workspace.pendingQuit && workspace.pendingClose == nil, automaticallyFocus: session.readingAnchorID == nil && !workspace.assistantWantsFocus && !workspace.pendingQuit && workspace.pendingClose == nil,
                                    completion: completion, commandAssessment: assessment,
                                    onCycleCompletion: { direction in guard !completions.isEmpty else { return nil }; completionIndex = (completionIndex + direction + completions.count) % completions.count; return completions[completionIndex] },
                                    onForcedSubmit: { submit($0) },
                                    onSubmit: { submit() }, onHistory: { session.history($0) },
                                    onFocus: { session.resumeInput(); workspace.assistantWantsFocus = false; if session.selectedBlockID != nil { session.selectedBlockID = nil }; workspace.selectSession(session.id) },
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
    }
    private var inputHint: some View {
        HStack(spacing: 7) {
            if session.draft.isEmpty { Text("命令，或直接问 Echo") }
            else {
                Image(systemName: route == .shell ? "return" : "sparkle")
                Text(route == .shell ? (assessment.dynamic ? "Return · 交给 Shell 解析" : "Return · 执行命令") : "Return · 发送给 Echo")
                if completion != nil { Text("· Tab 补全  ↑↓ \(completionIndex + 1)/\(completions.count)") }
            }
        }.font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize().help("⌘Return 强制执行命令 · ⌥Return 强制提问 · ⇧Return 换行")
    }
    private var assistantMode: Binding<AssistantMode> { Binding(get: { assistant.mode(for: session) }, set: { assistant.setMode($0, session: session) }) }
    private func submit(_ forced: InputRoute? = nil) {
        if assistant.submitInput(session: session, forced: forced) { completions = []; completionIndex = 0 }
    }
    private func updateCompletions() {
        completionTask?.cancel(); completions = []; completionIndex = 0
        assessment = session.commandCatalog.assess(session.draft, directory: session.directory)
        let draft = session.draft, catalog = session.commandCatalog, directory = session.directory
        guard draft.utf8.count <= 4_000 else { return }
        let history = session.blocks.filter { !$0.isAI && !$0.isDemo }.map(\.command)
        completionTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 55_000_000) } catch { return }
            let next = await Task.detached(priority: .userInitiated) { catalog.completions(for: draft, directory: directory, history: history) }.value
            guard !Task.isCancelled, session.draft == draft else { return }; completions = next
        }
    }
    private func scrollToCurrent(_ reader: ScrollViewProxy) {
        DispatchQueue.main.async {
            if reduceMotion { reader.scrollTo("end", anchor: .bottom) }
            else { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo("end", anchor: .bottom) } }
        }
    }
}

/// Manual input is always an explicit affordance, independent of output heuristics.
private struct RunningCommandInput: View {
    let blockID: UUID
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var preferences: Preferences
    @State private var expanded = false
    @State private var draft = ""
    @State private var error: String?
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
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8))
                    Text("向命令输入").font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(theme.accent)
                .accessibilityLabel(expanded ? "收起向命令输入" : "展开向命令输入")
            if expanded {
                Text(session.agentOwner != nil ? "输入将发送到 Echo 正在执行的这条命令。" : "输入将发送到上方正在运行的命令。")
                    .font(.system(size: 10)).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("单行输入", text: $draft).textFieldStyle(EchoTextFieldStyle())
                    .font(Font(preferences.terminalFont)).autocorrectionDisabled(true)
                    .onSubmit(sendDraft).disabled(!enabled)
                    .accessibilityLabel("发送给当前运行命令的单行内容")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) { actions; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 7) { actions }
                }.buttonStyle(EchoButtonStyle())
                if let message = validation ?? error {
                    Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }.padding(.leading, 23).frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var actions: some View {
        Button("发送", action: sendDraft).disabled(!enabled || draft.isEmpty || validation != nil)
        Button("仅发送 Return") { send("") }.disabled(!enabled)
            .help("向这条命令发送一个空行")
            .accessibilityLabel("向当前命令仅发送 Return 空行")
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

private struct ScrollActivityObserver: NSViewRepresentable {
    var onScroll: () -> Void
    final class ObserverView: NSView {
        var onScroll: (() -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window == self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)), abs(event.scrollingDeltaY) > 0 { self.onScroll?() }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.onScroll = onScroll }
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
                    LongTextView(text: block.command, font: preferences.terminalFont, color: NSColor(theme.text), label: "完整命令").frame(height: 120)
                } else {
                    Text(block.command).foregroundStyle(theme.text.opacity(selected || hovered ? 0.97 : 0.83)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.font(Font(preferences.terminalFont)).padding(.horizontal, 16)
            if !collapsed && !output.isEmpty {
                BlockOutput(text: output, font: preferences.terminalFont, color: theme.text.opacity(selected || hovered ? 0.9 : 0.7))
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
    var body: some View {
        if TextLayoutPolicy.needsViewport(text) {
            LongTextView(text: text, font: font, color: NSColor(color), label: "完整命令输出").frame(height: 300)
        } else { content }
    }
    private var content: some View { Text(text).font(Font(font)).foregroundStyle(color).lineSpacing(3).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
}

struct TerminalHost: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    @ObservedObject var preferences: Preferences
    var active: Bool
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
        let shouldFocus = active && isEnabled && session.agentOwner == nil
        let wasAllowed = view.keyboardFocusAllowed
        view.keyboardFocusAllowed = shouldFocus
        if shouldFocus && !wasAllowed { view.requestKeyboardFocus() }
    }
    static func dismantleNSView(_ view: TerminalViewport, coordinator: ()) {
        view.terminal.keyboardFocusAllowed = false
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
                                Text(block.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Text(block.duration).font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.muted)
                            }
                            if !block.output.isEmpty {
                                DisclosureGroup("输出") { ScrollView([.vertical, .horizontal]) { Text(block.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 200) }.font(.system(size: 10)).foregroundStyle(theme.muted)
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
