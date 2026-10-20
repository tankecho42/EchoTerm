#if DEBUG
import AppKit
import Foundation

@MainActor enum InteractiveTerminalSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        workspaceNativeInputEligibility(check: check)
        normalOutputScrolling(check: check)
        for shell in ["/bin/zsh", "/bin/bash"] { try await canonicalNativeInterrupt(shell: shell, check: check) }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-vim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        for shell in ["/bin/zsh", "/bin/bash"] {
            let name = URL(fileURLWithPath: shell).lastPathComponent
            let suite = "EchoTerm.NativeViewport.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = Preferences(defaults: defaults)
            let document = fixture.appendingPathComponent("\(name) editable.txt")
            let dimensions = fixture.appendingPathComponent("\(name)-dimensions")
            let contents = (1...60).map { String(format: "line-%03d", $0) }.joined(separator: "\n") + "\n"
            try contents.write(to: document, atomically: true, encoding: .utf8)
            let session = TerminalSession(directory: fixture.path, loadShellConfig: false, shellPath: shell)
            session.usesBlockEditor = true
            defer { session.close() }
            let host = NativeTerminalTestHost(session: session, preferences: preferences)
            defer { host.close() }
            let viewport = session.terminal.superview as! TerminalViewport
            viewport.frame = NSRect(x: 0, y: 0, width: 930, height: 640); viewport.layout()
            session.start()
            try await wait { session.ready }
            let owner = UUID(); session.agentOwner = owner
            session.draft = "/usr/bin/vim -Nu NONE -n -i NONE '\(document.path)'"
            session.execute(owner: owner)
            try await wait { session.alternateScreen && screen(session).contains("line-001") }
            try await wait { session.terminal.keyboardFocusAllowed }
            host.window.makeFirstResponder(session.terminal)
            do {
                try await wait { host.window.isKeyWindow && session.terminal.nativeInputAllowed && host.window.firstResponder === session.terminal }
            } catch {
                print("NATIVE-VIM-PREFLIGHT-FAILED \(name): \(NativeTerminalTestDriver.eligibility(session.terminal)) appActive=\(NSApp.isActive)")
                throw error
            }
            check(host.window.isKeyWindow && session.terminal.nativeInputAllowed && host.window.firstResponder === session.terminal,
                  "\(name): an AI-owned Vim component has native dispatch eligibility under the CLI test key-window override [\(NativeTerminalTestDriver.eligibility(session.terminal))]")
            try await Task.sleep(nanoseconds: 120_000_000)
            check(session.presentsInteractiveTerminal && session.liveOutput.isEmpty,
                  "\(name): Vim enters the interactive viewport without a duplicate text snapshot")
            check(session.terminal.bounds.size == viewport.bounds.size && session.terminal.bounds.height > 320,
                  "\(name): native terminal fills the available viewport instead of a fixed-height block")

            // Exercise real terminal input and save only our disposable fixture.
            NativeTerminalTestDriver.insert("ggi修复测试 ", into: session.terminal)
            NativeTerminalTestDriver.escape(session.terminal)
            NativeTerminalTestDriver.insert(":w", into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
            try await wait { (try? String(contentsOf: document, encoding: .utf8))?.hasPrefix("修复测试 line-001") == true }
            check(true, "\(name): AI-owned Vim receives real AppKit modal keys and Unicode insertText through the PTY")
            NativeTerminalTestDriver.insert("gg", into: session.terminal)
            NativeTerminalTestDriver.down(session.terminal)
            NativeTerminalTestDriver.insert("i↓ ", into: session.terminal)
            NativeTerminalTestDriver.escape(session.terminal)
            NativeTerminalTestDriver.insert(":w", into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
            try await wait { (try? String(contentsOf: document, encoding: .utf8))?.contains("\n↓ line-002") == true }
            check(true, "\(name): a real AppKit Down-arrow event navigates the AI-owned TUI before Unicode insertion")
            NativeTerminalTestDriver.insert("G", into: session.terminal)
            try await wait { screen(session).contains("line-060") }

            for size in [NSSize(width: 540, height: 280), NSSize(width: 1020, height: 680)] {
                viewport.frame.size = size
                viewport.layout()
                var tty = winsize()
                let gotSize = ioctl(session.terminal.process.childfd, TIOCGWINSZ, &tty) == 0
                let grid = session.terminal.getTerminal()
                check(gotSize && Int(tty.ws_row) == grid.rows && Int(tty.ws_col) == grid.cols,
                      "\(name): viewport resize synchronizes terminal grid and PTY dimensions")
                try await Task.sleep(nanoseconds: 150_000_000)
                try? FileManager.default.removeItem(at: dimensions)
                NativeTerminalTestDriver.insert(":call writefile([string(&lines), string(&columns)], '\(dimensions.path)')", into: session.terminal)
                NativeTerminalTestDriver.enter(session.terminal)
                try await wait { FileManager.default.fileExists(atPath: dimensions.path) }
                let actual = try String(contentsOf: dimensions, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
                check(actual == [grid.rows, grid.cols], "\(name): real Vim handles SIGWINCH at \(grid.cols) × \(grid.rows)")
            }

            NativeTerminalTestDriver.insert(":q", into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
            try await wait { !session.running }
            check(!session.alternateScreen && !session.presentsInteractiveTerminal && session.blocks.last?.exitCode == 0,
                  "\(name): quitting Vim restores the block editor and records completion")
            check(session.blocks.last?.output.contains("line-060") == false,
                  "\(name): Vim's alternate-screen contents do not leak into command history")
            session.agentOwner = nil
            session.draft = "printf 'after-vim\\n'"
            session.execute()
            try await wait { !session.running }
            check(session.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "after-vim",
                  "\(name): the next ordinary command executes normally after Vim")

            session.draft = "printf 'ready\\n'; read -r reply; printf 'reply:%s\\n' \"$reply\""
            session.execute()
            try await wait { session.liveOutput.contains("ready") }
            session.interactiveView = true
            check(session.presentsInteractiveTerminal && !session.alternateScreen,
                  "\(name): manual interactive programs use the same full viewport")
            session.sendInput("done")
            try await wait { !session.running }
            check(!session.presentsInteractiveTerminal && !session.interactiveView && session.blocks.last?.output.contains("reply:done") == true,
                  "\(name): interactive stdin and normal output survive returning to blocks")

            session.draft = "printf 'focus-ready\\n'; IFS= read -r focus_reply"
            session.execute()
            try await wait { session.liveOutput.contains("focus-ready") && session.terminal.keyboardFocusAllowed }
            host.update(active: false)
            try await wait { !session.terminal.keyboardFocusAllowed }
            host.window.makeFirstResponder(host.field)
            session.terminal.requestKeyboardFocus()
            try await Task.sleep(nanoseconds: 80_000_000)
            check(host.window.firstResponder !== session.terminal, "\(name): an inactive tab cannot steal focus from another input")
            host.update(active: true, enabled: false)
            try await wait { !session.terminal.keyboardFocusAllowed }
            session.terminal.requestKeyboardFocus()
            try await Task.sleep(nanoseconds: 80_000_000)
            check(host.window.firstResponder !== session.terminal, "\(name): a disabled TerminalHost preserves settings or assistant input focus")
            host.update(active: true)
            try await wait { session.terminal.keyboardFocusAllowed }
            check(host.window.makeFirstResponder(session.terminal), "\(name): returning to the active terminal restores native input eligibility")
            NativeTerminalTestDriver.insert("done", into: session.terminal); NativeTerminalTestDriver.enter(session.terminal)
            try await wait { !session.running }
        }
    }
    private static func workspaceNativeInputEligibility(check: (Bool, String) -> Void) {
        let workspace = Workspace()
        workspace.addTab(directory: "/tmp")
        defer { workspace.closeAll() }
        let first = workspace.activeSession!
        check(first.terminal.nativeInputContextAllowsInput(), "The first production addTab session receives synchronous workspace input eligibility")
        workspace.showSettings = true
        check(!first.terminal.nativeInputContextAllowsInput(), "The first session cannot escape settings gating through a default terminal closure")
        workspace.showSettings = false
        workspace.editingTab = workspace.activeTab
        check(workspace.inputBlockedByModal && !first.terminal.nativeInputContextAllowsInput(), "Tab settings and rename participate in the same synchronous input modal gate")
        workspace.editingTab = nil
        workspace.addTab(directory: "/tmp")
        check(!first.terminal.nativeInputContextAllowsInput() && workspace.activeSession?.terminal.nativeInputContextAllowsInput() == true,
              "Switching to a new production tab revokes the old session's eligibility before any view update")
    }
    private static func normalOutputScrolling(check: (Bool, String) -> Void) {
        let terminal = BlockTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        terminal.resize(cols: 60, rows: 8)
        terminal.getTerminal().changeHistorySize(24)
        func output(_ text: String) { terminal.dataReceived(slice: Array(text.utf8)[...]) }
        func topLine() -> String { terminal.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? "" }
        output((0..<18).map { "normal-\($0)\r\n" }.joined())
        check(terminal.canScroll && terminal.scrollPosition == 1 && terminal.followsNormalOutput,
              "Native normal-screen output follows its actual bottom by default")
        terminal.scrollUp(lines: 4)
        let before = topLine(), row = terminal.getTerminal().buffer.yDisp
        output("normal-18\r\nnormal-19\r\n")
        check(!terminal.followsNormalOutput && terminal.getTerminal().buffer.yDisp == row && topLine() == before,
              "Scrolling native output upward pauses following and preserves the viewed text as more lines arrive")
        terminal.scroll(toPosition: 1)
        output((20..<40).map { "normal-\($0)\r\n" }.joined())
        check(terminal.followsNormalOutput && terminal.scrollPosition == 1,
              "Returning to the native output bottom resumes following, including bounded scrollback")
        terminal.scrollUp(lines: 4)
        let fullBefore = topLine(), fullRow = terminal.getTerminal().buffer.yDisp
        output("normal-40\r\nnormal-41\r\n")
        check(!terminal.followsNormalOutput && topLine() == fullBefore && terminal.getTerminal().buffer.yDisp == max(0, fullRow - 2),
              "A paused native viewport retains its text when full scrollback recycles older lines")
        terminal.scroll(toPosition: 1)
        terminal.scrollDown(lines: 4)
        check(terminal.followsNormalOutput, "A downward scroll while already at bottom does not pause native output")
        output("\u{1b}[?1049hTUI\u{1b}[5;3H")
        let cursor = terminal.getTerminal().getCursorLocation()
        output("still-tui")
        check(terminal.getTerminal().isCurrentBufferAlternate && terminal.getTerminal().getCursorLocation().y == cursor.y,
              "Native output following does not scroll or reposition an alternate-screen TUI")
        output("\u{1b}[?1049l")
        check(!terminal.getTerminal().isCurrentBufferAlternate && terminal.followsNormalOutput,
              "Leaving a TUI preserves the normal-screen follow policy")
    }
    private static func canonicalNativeInterrupt(shell: String, check: (Bool, String) -> Void) async throws {
        let name = URL(fileURLWithPath: shell).lastPathComponent
        let suite = "EchoTerm.NativeCanonicalInterrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: shell)
        session.usesBlockEditor = true
        let host = NativeTerminalTestHost(session: session, preferences: Preferences(defaults: defaults))
        let workspace = Workspace()
        let tab = WorkspaceTab(title: "native handoff", root: .leaf(session), activeSessionID: session.id)
        workspace.tabs = [tab]; workspace.selectedTabID = tab.id
        let router = WindowCommandInputRouter(window: host.window, workspace: workspace)
        defer { host.close(); session.close() }
        session.start(); try await wait { session.ready && session.terminal.nativeInputAllowed }
        let owner = UUID(); session.agentOwner = owner
        let script = """
        import os,signal,termios
        assert termios.tcgetattr(0)[3] & termios.ISIG
        def interrupted(signum,frame):
            os.write(1,b'CANONICAL-INTERRUPTED\\n')
            raise SystemExit(130)
        signal.signal(signal.SIGINT,interrupted)
        os.write(1,b'CANONICAL-READY\\n')
        while True: signal.pause()
        """
        for (label, unmodified, keyCode) in [("Latin base", "c", UInt16(8)), ("translated ETX", "\u{03}", UInt16(45)), ("non-Latin source", "中", UInt16(45)), ("empty base", "", UInt16(45))] {
            session.draft = "/usr/bin/python3 -u -c " + ShellWords.quote(script)
            let blockID = session.execute(owner: owner)!
            try await wait { session.liveOutput.contains("CANONICAL-READY") }
            // Cmd-F can leave this flag set while the native branch has no
            // search UI. It must not turn that live keyboard viewport inert.
            session.showSearch = true
            let hiddenSearchAllowsNative = session.terminal.nativeInputContextAllowsInput()
            session.interactiveView = false
            let displayedSearchBlocksNative = !session.terminal.nativeInputContextAllowsInput()
            session.interactiveView = true
            check(hiddenSearchAllowsNative && displayedSearchBlocksNative,
                  "\(name) \(label): a hidden search flag preserves native keys while the actual Block search blocks input")
            host.window.makeFirstResponder(session.terminal)
            var bytes: [UInt8] = []
            session.terminal.onInput = { bytes.append(contentsOf: $0) }
            let revision = session.nativeInputRevision
            host.window.makeFirstResponder(host.field)
            let ignoredField = NativeTerminalTestDriver.key("\u{03}", code: keyCode, modifiers: .control, unmodified: unmodified, into: session.terminal)
            NativeTerminalTestDriver.insert("fixture IME must stay in its field", into: session.terminal)
            session.terminal.withNativeInput { session.terminal.send(txt: "fixture paste must stay in its field") }
            check(!ignoredField && session.running && bytes.isEmpty && session.nativeInputRevision == revision,
                  "\(name) \(label): Ctrl-C in an editable helper field cannot interrupt the running command")
            host.window.makeFirstResponder(session.terminal)
            host.window.simulatedKeyEligibility = false
            let suppressed = NativeTerminalTestDriver.key("\u{03}", code: keyCode, modifiers: .control, unmodified: unmodified, into: session.terminal)
            host.window.simulatedKeyEligibility = true
            check(suppressed && bytes.isEmpty && session.nativeInputRevision == revision,
                  "\(name) \(label): a background window cannot deliver Ctrl-C")
            session.terminal.nativeInputAllowed = false
            _ = NativeTerminalTestDriver.key("\u{03}", code: keyCode, modifiers: .control, unmodified: unmodified, into: session.terminal)
            session.terminal.nativeInputAllowed = true
            check(bytes.isEmpty && session.nativeInputRevision == revision,
                  "\(name) \(label): modal native-input suppression also blocks translated Ctrl-C")
            // A real pointer event's observation path restores terminal focus;
            // no menu, paste or programmatic PTY send stands in for keyDown.
            var clicked = false
            session.terminal.onNativeFocusRequested = { clicked = true; host.window.makeFirstResponder(session.terminal) }
            host.window.makeFirstResponder(host.field)
            NativeTerminalTestDriver.click(session.terminal)
            check(clicked && host.window.firstResponder === session.terminal,
                  "\(name) \(label): an explicit click restores the native terminal's first responder")
            let handled = NativeTerminalTestDriver.key("\u{03}", code: keyCode, modifiers: .control, unmodified: unmodified, into: session.terminal)
            try await wait { !session.running }
            session.terminal.onInput = nil
            let block = session.blocks.first { $0.id == blockID }
            check(handled && bytes == [3] && session.nativeInputRevision == revision + 1 && block?.exitCode == 130
                  && block?.output.components(separatedBy: "CANONICAL-INTERRUPTED").count == 2,
                  "\(name) \(label): actual AppKit Ctrl-C sends one ETX, signals the canonical foreground child once and records exit 130")
            session.showSearch = false
            check(!session.sendNativeInterrupt(expectedBlockID: blockID), "\(name) \(label): a stale native interrupt cannot target the next command")
        }
        for terminalFirst in [true, false] {
            session.draft = "/usr/bin/python3 -u -c " + ShellWords.quote(script)
            let blockID = session.execute(owner: owner)!
            try await wait { session.liveOutput.contains("CANONICAL-READY") }
            host.window.makeFirstResponder(session.terminal)
            var bytes: [UInt8] = []
            session.terminal.onInput = { bytes.append(contentsOf: $0) }
            let event = NativeTerminalTestDriver.keyEvent("\u{03}", code: 45, modifiers: .control, unmodified: "", into: session.terminal)
            let revision = session.nativeInputRevision
            // No yield/layout pass: exercise the state change while the old
            // terminal is still attached and remains the first responder.
            session.interactiveView = false
            session.terminal.nativeInputAllowed = !terminalFirst
            func dispatch() -> Bool {
                if terminalFirst {
                    return session.terminal.dispatchNativeKeyDown(event) || router.handle(event)
                }
                return router.handle(event) || session.terminal.dispatchNativeKeyDown(event)
            }
            check(session.terminal.window === host.window && host.window.firstResponder === session.terminal,
                  "\(name): immediate Block handoff fixture retains the mounted old terminal before any layout turn")
            // Exercise the same boundary used by paste without touching the
            // user's general clipboard. IME uses the actual insertText override.
            NativeTerminalTestDriver.insert("hidden fixture IME", into: session.terminal)
            session.terminal.withNativeInput { session.terminal.send(txt: "hidden fixture paste") }
            check(bytes.isEmpty && session.nativeInputRevision == revision,
                  "\(name): immediate hidden-terminal IME and paste operations cannot write through stale native permission")
            // Reproduce stale SwiftUI permission while the session stays shown.
            session.interactiveView = true
            session.terminal.nativeInputAllowed = true
            workspace.showSettings = true
            let settingsSuppressed = dispatch()
            NativeTerminalTestDriver.insert("settings fixture IME", into: session.terminal)
            session.terminal.withNativeInput { session.terminal.send(txt: "settings fixture paste") }
            workspace.showSettings = false
            workspace.editingTab = tab
            let renameSuppressed = dispatch()
            NativeTerminalTestDriver.insert("rename fixture IME", into: session.terminal)
            session.terminal.withNativeInput { session.terminal.send(txt: "rename fixture paste") }
            workspace.editingTab = nil
            let background = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: shell)
            let backgroundTab = WorkspaceTab(title: "inactive native fixture", root: .leaf(background), activeSessionID: background.id)
            workspace.tabs.append(backgroundTab); workspace.selectedTabID = backgroundTab.id
            let backgroundSuppressed = dispatch()
            NativeTerminalTestDriver.insert("background fixture IME", into: session.terminal)
            session.terminal.withNativeInput { session.terminal.send(txt: "background fixture paste") }
            workspace.selectedTabID = tab.id
            workspace.tabs.removeLast(); background.close()
            check(settingsSuppressed && renameSuppressed && backgroundSuppressed && bytes.isEmpty
                  && session.nativeInputRevision == revision && session.running,
                  "\(name): synchronous settings, rename and tab-switch gates reject Ctrl-C, IME and paste before SwiftUI updates stale native permission")
            session.interactiveView = false
            session.terminal.nativeInputAllowed = !terminalFirst
            workspace.showSettings = true
            let blocked = dispatch()
            workspace.showSettings = false
            check(blocked && bytes.isEmpty && session.nativeInputRevision == revision && session.running,
                  "\(name): hidden-terminal Ctrl-C is consumed without stdin while a modal blocks window handoff")
            let consumed = dispatch()
            try await wait { !session.running }
            session.terminal.onInput = nil
            check(consumed && bytes == [3] && session.nativeInputRevision == revision + 1
                  && session.blocks.first(where: { $0.id == blockID })?.exitCode == 130,
                  "\(name): first Ctrl-C immediately after Block handoff interrupts once with \(terminalFirst ? "terminal" : "window") monitor first, including a closed old input gate")
        }
        session.agentOwner = nil
        session.draft = "printf 'canonical-shell-still-usable\\n'"; session.execute()
        try await wait { !session.running }
        check(session.blocks.last?.exitCode == 0 && session.blocks.last?.output.contains("canonical-shell-still-usable") == true,
              "\(name): the persistent Shell remains usable after native foreground Ctrl-C")
    }
    private static func screen(_ session: TerminalSession) -> String {
        String(decoding: session.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AIError.message("Timed out waiting for interactive terminal fixture")
    }
}
#endif
