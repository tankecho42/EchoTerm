import SwiftUI
import SwiftTerm
import AppKit

struct CommandBlock: Identifiable, Codable {
    var id = UUID()
    var command: String
    var directory: String
    var output = ""
    var startedAt = Date()
    var finishedAt: Date?
    var exitCode: Int?
    var collapsed = false
    var isDemo = false
    var assistantRunID: UUID? = nil
    var assistantReplyID: UUID? = nil
    var assistantContinuation: Bool? = nil
    var assistantMode: AssistantMode? = nil
    var isAI: Bool { assistantReplyID != nil }
    var duration: String {
        guard let end = finishedAt else { return "运行中" }
        let interval = end.timeIntervalSince(startedAt)
        return interval < 1 ? "\(Int(interval * 1000)) ms" : String(format: "%.1f s", interval)
    }
}

struct BlockReveal: Equatable {
    let id = UUID()
    let blockID: UUID
    let started = ProcessInfo.processInfo.systemUptime
}

/// UI-only named keys; model tools never accept arbitrary terminal bytes.
enum TerminalInputKey { case up, down, left, right, tab, escape, enter, controlC }

final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var blocks: [CommandBlock] = []
    @Published var directory: String
    @Published var draft = ""
    @Published var defaultInputRoute: InputRoute = .automatic
    @Published var defaultAssistantMode: AssistantMode?
    @Published var inputRouteOverride: InputRoute?
    @Published var assistantModeOverride: AssistantMode?
    var inputRoute: InputRoute { get { inputRouteOverride ?? defaultInputRoute } set { inputRouteOverride = newValue } }
    func resetInputModes() { inputRouteOverride = nil; assistantModeOverride = nil }
    @Published var commandCatalog = ShellCommandCatalog()
    @Published private(set) var catalogReady = false
    private var catalogGeneration = UUID()
    @Published var running = false
    @Published var ready = false
    @Published var exited = false
    @Published var showSeparators = true
    let shellPath: String
    var shellName: String { URL(fileURLWithPath: shellPath).lastPathComponent }
    private var supportsInsertWidget: Bool { shellName == "zsh" || shellPath != "/bin/bash" }
    @Published var focusRequest = UUID()
    @Published var search = ""
    @Published var showSearch = false
    @Published var shellError: String?
    @Published var insertionError: String?
    @Published var selectedBlockID: UUID?
    @Published private(set) var readingAnchorID: UUID?
    @Published private(set) var blockReveal: BlockReveal?
    @discardableResult func revealBlock(_ id: UUID) -> Bool {
        guard blocks.contains(where: { $0.id == id }) else { return false }
        readingAnchorID = id; selectedBlockID = id; blockReveal = BlockReveal(blockID: id)
        return true
    }
    func resumeInput() { readingAnchorID = nil; blockReveal = nil }

    @Published var liveOutput = ""
    @Published var interactiveView = false
    @Published var alternateScreen = false
    @Published private(set) var nativeInputRevision = 0
    @Published private(set) var nativeControlActive = false
    var presentsInteractiveTerminal: Bool { running && (interactiveView || alternateScreen) }
    var usesBlockEditor = false
    @Published var agentOwner: UUID?
    var agentBlockID: UUID?
    private(set) var runningBlockID: UUID?
    private(set) var lastCompleted: CommandBlock?
    var onClose: (() -> Void)?
    let inputBlockID = UUID()
    private var snapshotPending = false
    var selectedBlock: CommandBlock? { blocks.first { $0.id == selectedBlockID } }
    let terminal = BlockTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 320))
    var onComplete: ((CommandBlock) -> Void)?
    var onExecute: ((String) -> Void)?
    var onActivity: (() -> Void)?
    var onNativeCommandInput: ((UUID) -> Void)?
    private var bootstrap: URL?
    private var started = false
    private let loadShellConfig: Bool
    private let environmentOverrides: [String: String]
    private var capturing = false
    private var historyIndex: Int?
    private var draftBeforeHistory = ""
    private let snapshotDelegate = SnapshotDelegate()
    private var recording: Terminal?
    private var outputCount = 0
    var displayDirectory: String { directory.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    var name: String { URL(fileURLWithPath: directory).lastPathComponent }
    init(directory: String = NSHomeDirectory(), loadShellConfig: Bool = true, shellPath: String? = nil, environmentOverrides: [String: String] = [:]) {
        self.directory = directory
        self.shellPath = shellPath ?? ShellChoice.system.executable
        self.loadShellConfig = loadShellConfig
        self.environmentOverrides = environmentOverrides
        terminal.onEvent = { [weak self] event in self?.receive(event) }
        terminal.onNativeInput = { [weak self] in self?.recordNativeInput() }
        terminal.nativeInputIsPresented = { [weak self] in
            guard let self else { return false }
            return !self.usesBlockEditor || self.presentsInteractiveTerminal
        }
        terminal.onResize = { [weak self] columns, rows in
            self?.recording?.resize(cols: columns, rows: rows)
        }
        terminal.onExit = { [weak self] code in
            guard let self else { return }
            self.ready = false; self.exited = true
            if self.running { self.finish(status: Int(code ?? -1)) }
        }
    }
    func start() {
        guard !started else { return }
        started = true
        do {
            let token = UUID().uuidString
            bootstrap = try ShellBootstrap.create(token: token)
            terminal.streamParser = ShellStreamParser(token: token)
            var env = ProcessInfo.processInfo.environment
            env.merge(environmentOverrides) { _, override in override }
            env["ECHOTERM_USER_ZDOTDIR"] = env["ZDOTDIR"] ?? env["HOME"] ?? NSHomeDirectory()
            env["ECHOTERM_HAD_ZDOTDIR"] = env["ZDOTDIR"] == nil ? "0" : "1"
            env["ECHOTERM_LOAD_CONFIG"] = loadShellConfig ? "1" : "0"
            env["ECHOTERM_BOOTSTRAP"] = bootstrap!.path
            env["ECHOTERM_INSERT_FILE"] = bootstrap!.appendingPathComponent("input").path
            env["ECHOTERM_COMMAND_FILE"] = bootstrap!.appendingPathComponent("command").path
            if shellName == "zsh" { env["ZDOTDIR"] = bootstrap!.path }
            env["SHELL"] = shellPath
            env["ECHOTERM_TOKEN"] = token
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            env["TERM_PROGRAM"] = "EchoTerm"
            env["LC_CTYPE"] = "UTF-8"
            if env["PATH"] == nil { env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" }
            let args = shellName == "bash" ? ["--rcfile", bootstrap!.appendingPathComponent("bashrc").path, "-i"] : ["-l", "-i"]
            terminal.process.startProcess(executable: shellPath, args: args, environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: directory, size: terminal.getWindowSize())
        } catch { shellError = error.localizedDescription; exited = true }
    }
    @discardableResult func execute(owner: UUID? = nil) -> UUID? {
        let command = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !running, !exited, !command.isEmpty, agentOwner == owner else { return nil }
        if owner == nil { resumeInput() }
        var payload = command
        if usesBlockEditor, let bootstrap {
            do {
                let file = bootstrap.appendingPathComponent("command")
                try command.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                // Evaluate in the existing shell. Even Bash 3.2 receives multiline input
                // as a single command, without prematurely executing each pasted line.
                payload = #"builtin eval -- "$(<"$ECHOTERM_COMMAND_FILE")""#
            } catch { insertionError = error.localizedDescription; return nil }
        }
        blocks.append(CommandBlock(command: command, directory: directory, assistantRunID: owner))
        if readingAnchorID == nil { selectedBlockID = blocks.last?.id }
        runningBlockID = blocks.last?.id
        if owner != nil { agentBlockID = blocks.last?.id }
        trimBlocks()
        running = true; capturing = true; draft = ""; historyIndex = nil; liveOutput = ""; interactiveView = true
        nativeInputRevision = 0; nativeControlActive = false
        terminal.resumeNormalOutputFollowing()
        recording = makeRecording()
        onExecute?(command)
        onActivity?()
        terminal.send(txt: "\u{01}\u{0b}")
        if terminal.getTerminal().bracketedPasteMode { terminal.send(txt: "\u{1B}[200~\(payload)\u{1B}[201~\r") }
        else { terminal.send(txt: payload + "\r") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.presentsInteractiveTerminal else { return }
            self.terminal.requestKeyboardFocus()
        }
        return runningBlockID
    }
    @discardableResult func insert(_ command: String) -> Bool {
        insertionError = nil
        guard ready, !running, !exited, agentOwner == nil else { insertionError = "终端正在由助手操作，请先停止助手。"; return false }
        guard !command.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10 && $0.value != 9) || $0.value == 127 }) else { insertionError = "命令含有无法填入的控制字符。"; return false }
        if usesBlockEditor { resumeInput(); draft = command; selectedBlockID = nil; focus(); return true }
        if supportsInsertWidget, let bootstrap {
            do {
                let file = bootstrap.appendingPathComponent("input")
                try command.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                terminal.send(txt: "\u{1b}[99~")
            } catch { insertionError = error.localizedDescription; return false }
        } else {
            // Bash 3.2 has no READLINE_LINE API; never paste multiline text as keystrokes.
            guard !command.contains("\n"), !command.contains("\t") else { insertionError = "系统 Bash 仅支持填入单行命令。这条命令可以先复制，再手动编辑。"; return false }
            terminal.send(txt: "\u{01}\u{0b}" + command)
        }
        draft = command; focusRequest = UUID(); focus()
        return true
    }
    func focus() {
        focusRequest = UUID()
        guard !usesBlockEditor || presentsInteractiveTerminal else { return }
        terminal.requestKeyboardFocus()
    }
    func sendInput(_ text: String) { guard running else { return }; terminal.send(txt: text + "\r") }
    @discardableResult func sendInput(_ text: String, expectedBlockID: UUID) -> Bool {
        guard running, !exited, runningBlockID == expectedBlockID,
              text.utf8.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }) else { return false }
        terminal.send(txt: text + "\r")
        return true
    }
    @discardableResult func sendKey(_ key: TerminalInputKey, expectedBlockID: UUID) -> Bool {
        guard running, !exited, runningBlockID == expectedBlockID else { return false }
        let application = terminal.getTerminal().applicationCursor
        let text: String
        switch key {
        case .up: text = application ? "\u{1b}OA" : "\u{1b}[A"
        case .down: text = application ? "\u{1b}OB" : "\u{1b}[B"
        case .right: text = application ? "\u{1b}OC" : "\u{1b}[C"
        case .left: text = application ? "\u{1b}OD" : "\u{1b}[D"
        case .tab: text = "\t"
        case .escape: text = "\u{1b}"
        case .enter: text = "\r"
        case .controlC: text = "\u{3}"
        }
        recordNativeInput()
        terminal.send(txt: text)
        return true
    }
    private func recordNativeInput() {
        guard running, !exited, let blockID = runningBlockID else { return }
        nativeInputRevision += 1; nativeControlActive = true
        onNativeCommandInput?(blockID)
    }
    static func isNativeInterrupt(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.option) else { return false }
        return event.characters == "\u{03}" || event.charactersIgnoringModifiers == "\u{03}"
            || event.charactersIgnoringModifiers == "c" || event.charactersIgnoringModifiers == "C"
    }
    @discardableResult func sendNativeInterrupt(expectedBlockID: UUID) -> Bool {
        guard running, !exited, runningBlockID == expectedBlockID else { return false }
        recordNativeInput()
        terminal.send(txt: "\u{03}")
        return true
    }
    func interrupt() { terminal.send(txt: "\u{03}") }
    func close() {
        onClose?(); ready = false; exited = true
        terminal.onExit = nil
        terminal.process.stop()
        if let bootstrap { try? FileManager.default.removeItem(at: bootstrap) }
    }
    deinit { if let bootstrap { try? FileManager.default.removeItem(at: bootstrap) } }
    func clear() { resumeInput(); blocks.removeAll { $0.exitCode != nil }; selectedBlockID = runningBlockID; terminal.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H"); if !running { terminal.send(txt: "\u{0c}") }; focus() }
    func history(_ direction: Int) {
        let commands = blocks.filter { !$0.isDemo && !$0.isAI }.map(\.command)
        guard !commands.isEmpty else { return }
        if historyIndex == nil { draftBeforeHistory = draft }
        let next = (historyIndex ?? commands.count) + direction
        if next >= commands.count { historyIndex = nil; draft = draftBeforeHistory }
        else { historyIndex = max(0, next); draft = commands[max(0, next)] }
    }
    private func receive(_ event: ShellStreamParser.Event) {
        switch event {
        case .began(let command):
            if !running { blocks.append(CommandBlock(command: command, directory: directory)); runningBlockID = blocks.last?.id; running = true; onExecute?(command); onActivity?(); trimBlocks() }
            if usesBlockEditor { terminal.feed(text: "\u{1b}[3J\u{1b}[2J\u{1b}[H") }
            capturing = true; outputCount = 0
            recording = makeRecording()

        case .output(let bytes):
            if capturing {
                recording?.feed(buffer: bytes[...]); outputCount += bytes.count
                let alternate = terminal.getTerminal().isCurrentBufferAlternate
                if alternateScreen != alternate {
                    alternateScreen = alternate
                    if alternate { liveOutput = "" }
                }
                // A full-screen app owns its terminal grid. Turning every cursor
                // redraw into transcript text duplicates the screen and causes
                // scroll/layout churn while the user is editing.
                if usesBlockEditor && !alternate && !snapshotPending {
                    snapshotPending = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.075) { [weak self] in
                        guard let self else { return }; self.snapshotPending = false
                        if self.running && !self.alternateScreen { self.liveOutput = self.outputSnapshot() }
                    }
                }
            }
        case .prompt(let status, let path):
            if !path.isEmpty { directory = path }
            refreshCommandCatalog()
            ready = true
            if running {
                finish(status: status)
                if !usesBlockEditor && showSeparators && !terminal.getTerminal().isCurrentBufferAlternate {
                    let prefix = terminal.getTerminal().getCursorLocation().x == 0 ? "" : "\r\n"
                    // Keep the divider short enough for the narrowest split pane, so
                    // terminal reflow doesn't turn a previous divider into several rows.
                    terminal.feed(text: prefix + "\u{1b}[2;90m" + String(repeating: "─", count: max(1, min(24, terminal.getTerminal().cols - 1))) + "\u{1b}[0m\r\n")
                }
            }
        }
    }
    private func finish(status: Int) {
        if let index = blocks.firstIndex(where: { $0.id == runningBlockID }) {
            blocks[index].output = outputSnapshot()
            if outputCount > 2_000_000 { blocks[index].output += "\n[仅保留最近 5,000 行输出]" }
            blocks[index].exitCode = status
            blocks[index].finishedAt = Date()
            let completed = blocks[index]
            lastCompleted = completed
            running = false; capturing = false; recording = nil
            runningBlockID = nil
            liveOutput = ""; alternateScreen = false; interactiveView = false; nativeControlActive = false
            if selectedBlockID == blocks[index].id && readingAnchorID == nil { selectedBlockID = nil }
            focusRequest = UUID()
            onComplete?(completed)
            onActivity?()
        } else { running = false; capturing = false }
    }
    private func makeRecording() -> Terminal {
        let grid = terminal.getTerminal()
        return Terminal(delegate: snapshotDelegate, options: TerminalOptions(cols: grid.cols, rows: grid.rows, scrollback: 5000))
    }
    private func outputSnapshot() -> String {
        guard let recording else { return "" }
        var lines = String(decoding: recording.getBufferAsData(), as: UTF8.self).replacingOccurrences(of: "\0", with: "").components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return String(lines.joined(separator: "\n").suffix(160000))
    }
    func appendAIBlock(question: String, replyID: UUID, continuation: Bool = false, mode: AssistantMode? = nil) {
        blocks.append(.init(command: question, directory: directory, assistantReplyID: replyID, assistantContinuation: continuation, assistantMode: mode))
        if readingAnchorID == nil { selectedBlockID = blocks.last?.id }
        trimBlocks()
        onActivity?()
    }
    func updateAIBlock(_ reply: ChatMessage) {
        guard let index = blocks.firstIndex(where: { $0.assistantReplyID == reply.id }) else { return }
        blocks[index].output = [reply.text, reply.status].filter { !$0.isEmpty }.joined(separator: "\n")
        if !reply.isStreaming { blocks[index].exitCode = 0; blocks[index].finishedAt = Date() }
    }
    func moveAIBlockToEnd(_ replyID: UUID) {
        guard let index = blocks.firstIndex(where: { $0.assistantReplyID == replyID }), index != blocks.count - 1 else { return }
        let block = blocks.remove(at: index); blocks.append(block)
    }
    func refreshCommandCatalog() {
        let generation = UUID(); catalogGeneration = generation
        let names = bootstrap?.appendingPathComponent("names"), path = bootstrap?.appendingPathComponent("path"), cwd = directory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let catalog = ShellCommandCatalog.load(namesURL: names, pathURL: path, directory: cwd)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.catalogGeneration == generation, !self.exited else { return }
                self.commandCatalog = catalog
                self.catalogReady = true
            }
        }
    }
    private func trimBlocks() {
        while blocks.count > 300, let index = blocks.firstIndex(where: { $0.exitCode != nil && $0.id != runningBlockID }) { blocks.remove(at: index) }
        if let anchor = readingAnchorID, !blocks.contains(where: { $0.id == anchor }) { resumeInput(); selectedBlockID = nil }
    }
}

indirect enum PaneNode: Identifiable {
    case leaf(TerminalSession)
    case split(UUID, Bool, PaneNode, PaneNode)
    var id: UUID { switch self { case .leaf(let session): return session.id; case .split(let id, _, _, _): return id } }
    var sessions: [TerminalSession] {
        switch self { case .leaf(let session): return [session]; case .split(_, _, let a, let b): return a.sessions + b.sessions }
    }
    func splitting(_ target: UUID, vertical: Bool, newSession: TerminalSession) -> PaneNode {
        switch self {
        case .leaf(let session): return session.id == target ? .split(UUID(), vertical, self, .leaf(newSession)) : self
        case .split(let id, let axis, let a, let b): return .split(id, axis, a.splitting(target, vertical: vertical, newSession: newSession), b.splitting(target, vertical: vertical, newSession: newSession))
        }
    }
    func removing(_ target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let session): return session.id == target ? nil : self
        case .split(let id, let axis, let a, let b):
            let left = a.removing(target), right = b.removing(target)
            if let left, let right { return .split(id, axis, left, right) }
            return left ?? right
        }
    }
}

struct WorkspaceTab: Identifiable {
    var id = UUID()
    var title: String
    var root: PaneNode
    var activeSessionID: UUID
    var customTitle: String?
    var generatedTitle: String?
    var namingError: String?
    var defaultInputRoute: InputRoute = .automatic
    var defaultAssistantMode: AssistantMode = .answer
}

final class Workspace: ObservableObject {
    @Published var tabs: [WorkspaceTab] = [] {
        didSet {
            for session in indexedSessions { bindNativeInputEligibility(session) }
        }
    }
    @Published var selectedTabID: UUID? { didSet { if oldValue != selectedTabID { assistantWantsFocus = false } } }
    @Published var assistantVisible = false
    @Published var assistantSessionID: UUID?
    @Published var assistantFocusRequest = UUID()
    @Published var assistantWantsFocus = false
    @Published var currentInputFocusSessionID: UUID?
    @Published var currentInputFocusRequest = UUID()
    private var assistantWasMinimized = false
    var assistantSession: TerminalSession? { tabs.flatMap { $0.root.sessions }.first { $0.id == assistantSessionID } }
    func presentAssistant(for id: UUID, automatic: Bool = false) {
        if automatic {
            guard !assistantWasMinimized else { return }
            // A suggestion from another pane never replaces the conversation being read.
            if assistantVisible && assistantSessionID != id { return }
        } else { assistantWasMinimized = false }
        assistantSessionID = id; assistantWantsFocus = !automatic; assistantVisible = true
        if !automatic { assistantFocusRequest = UUID() }
    }
    func minimizeAssistant() {
        assistantWasMinimized = true
        assistantVisible = false; assistantWantsFocus = false
        activeSession?.focus()
    }
    func toggleAssistant(session: TerminalSession? = nil) {
        if assistantVisible && (session == nil || session?.id == assistantSessionID) { minimizeAssistant() }
        else if let target = session ?? activeSession { presentAssistant(for: target.id) }
    }
    /// An explicit transcript click transfers focus without reusing its command
    /// or replacing the current draft. Modal dialogs retain their input owner.
    @discardableResult func focusCurrentInput(sessionID: UUID) -> Bool {
        guard !inputBlockedByModal,
              let session = indexedSessions.first(where: { $0.id == sessionID }) else { return false }
        revealSession(sessionID)
        assistantWantsFocus = false
        session.resumeInput(); session.selectedBlockID = nil
        if session.running { session.interactiveView = true }
        currentInputFocusSessionID = sessionID
        currentInputFocusRequest = UUID()
        session.focus()
        return true
    }
    var indexedSessions: [TerminalSession] { tabs.flatMap { $0.root.sessions } }
    func sessionIndex(_ id: UUID) -> Int? { indexedSessions.firstIndex { $0.id == id }.map { $0 + 1 } }
    @discardableResult func revealBlock(sessionID: UUID, blockID: UUID) -> Bool {
        guard let session = indexedSessions.first(where: { $0.id == sessionID }), session.revealBlock(blockID) else { return false }
        revealSession(sessionID); return true
    }
    func revealSession(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.root.sessions.contains { $0.id == id } }) else { return }
        selectedTabID = tab.id; selectSession(id)
    }
    var preferredShell: () -> String = { ShellChoice.system.executable }
    var preferredInputRoute: () -> InputRoute = { .automatic }
    var preferredAssistantMode: () -> AssistantMode = { .answer }
    var namingPolicy: () -> TabNamingPolicy = { .directory }
    var onTabActivity: ((UUID) -> Void)?
    var onTabClosed: ((UUID) -> Void)?
    @Published var showSettings = false
    @Published var editingTab: WorkspaceTab?
    @Published var pendingClose: [UUID]?
    @Published var pendingQuit = false
    var inputBlockedByModal: Bool { showSettings || editingTab != nil || pendingClose != nil || pendingQuit }
    func allowsNativeInput(sessionID: UUID) -> Bool {
        guard let session = activeSession, session.id == sessionID else { return false }
        return !inputBlockedByModal && !assistantWantsFocus && (!session.showSearch || session.presentsInteractiveTerminal)
    }
    var configureSession: ((TerminalSession) -> Void)?
    var activeTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }
    var activeSession: TerminalSession? { activeTab?.root.sessions.first { $0.id == activeTab?.activeSessionID } }
    func addTab(directory: String? = nil) {
        let session = makeSession(directory: directory ?? activeSession?.directory ?? NSHomeDirectory())
        session.defaultInputRoute = preferredInputRoute(); session.defaultAssistantMode = preferredAssistantMode()
        let tab = WorkspaceTab(title: session.displayDirectory, root: .leaf(session), activeSessionID: session.id, defaultInputRoute: session.defaultInputRoute, defaultAssistantMode: session.defaultAssistantMode ?? .answer)
        tabs.append(tab); selectedTabID = tab.id
    }
    func selectSession(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].root.sessions.contains(where: { $0.id == id }) else { return }
        if tabs[index].activeSessionID != id { tabs[index].activeSessionID = id }
    }
    func split(vertical: Bool) {
        assistantWantsFocus = false
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }), tabs[index].root.sessions.count < 6 else { return }
        let session = makeSession(directory: activeSession?.directory ?? NSHomeDirectory())
        session.defaultInputRoute = tabs[index].defaultInputRoute; session.defaultAssistantMode = tabs[index].defaultAssistantMode
        tabs[index].root = tabs[index].root.splitting(tabs[index].activeSessionID, vertical: vertical, newSession: session)
        tabs[index].activeSessionID = session.id
    }
    func closeSession(_ id: UUID, force: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0.root.sessions.contains { $0.id == id } }) else { return }
        if !force, tabs[index].root.sessions.first(where: { $0.id == id })?.running == true { pendingClose = [id]; return }
        tabs[index].root.sessions.first { $0.id == id }?.close()
        if assistantSessionID == id { assistantVisible = false; assistantSessionID = nil }
        if let root = tabs[index].root.removing(id) {
            tabs[index].root = root; tabs[index].activeSessionID = root.sessions[0].id
            refreshTitle(tabs[index].id); onTabActivity?(tabs[index].id)
        } else {
            onTabClosed?(tabs[index].id)
            tabs.remove(at: index)
            if tabs.isEmpty { addTab() }
            else if selectedTabID == nil || !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs[min(index, tabs.count - 1)].id }
        }
    }
    func closeTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.root.sessions.contains(where: \.running) { pendingClose = tab.root.sessions.map(\.id); return }
        for session in tab.root.sessions { closeSession(session.id, force: true) }
    }
    func nextTab(_ delta: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        selectedTabID = tabs[(index + delta + tabs.count) % tabs.count].id
    }
    private func makeSession(directory: String) -> TerminalSession {
        let session = TerminalSession(directory: directory, shellPath: preferredShell())
        bindNativeInputEligibility(session)
        configureSession?(session)
        session.onActivity = { [weak self, weak session] in
            guard let self, let session, let tab = self.tabs.first(where: { $0.root.sessions.contains { $0.id == session.id } }) else { return }
            self.refreshTitle(tab.id); self.onTabActivity?(tab.id)
        }
        return session
    }
    private func bindNativeInputEligibility(_ session: TerminalSession) {
        session.terminal.nativeInputContextAllowsInput = { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.allowsNativeInput(sessionID: session.id)
        }
    }
    func configureTab(_ id: UUID, customTitle: String, input: InputRoute, assistant: AssistantMode) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clean = String(customTitle.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        tabs[index].customTitle = clean.isEmpty ? nil : clean
        tabs[index].defaultInputRoute = input; tabs[index].defaultAssistantMode = assistant
        for session in tabs[index].root.sessions { session.defaultInputRoute = input; session.defaultAssistantMode = assistant }
        refreshTitle(id); onTabActivity?(id)
    }
    func refreshTitle(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        let entries = tab.root.sessions.flatMap { session in session.blocks.map { (session: session, block: $0) } }
        let latest = entries.max { $0.block.startedAt < $1.block.startedAt }
        let path = (latest?.session ?? tab.root.sessions.first)?.displayDirectory ?? "终端"
        let command = entries.filter { !$0.block.isAI }.max { $0.block.startedAt < $1.block.startedAt }?.block.command
        let automatic: String
        switch namingPolicy() {
        case .directory: automatic = path
        case .command: automatic = command.map { String($0.components(separatedBy: .newlines).joined(separator: " ").prefix(80)) } ?? path
        case .intelligence: automatic = tab.generatedTitle ?? path
        }
        let title = tab.customTitle ?? automatic
        if tabs[index].title != title { tabs[index].title = title }
    }
    func setGeneratedTitle(_ title: String?, error: String?, for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].customTitle == nil else { return }
        if let title { tabs[index].generatedTitle = title }
        tabs[index].namingError = error
        refreshTitle(id)
    }
    func closeAll() { tabs.flatMap { $0.root.sessions }.forEach { $0.close() } }
}

final class SnapshotDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
