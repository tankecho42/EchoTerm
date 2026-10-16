#if DEBUG
import AppKit
import Foundation

@MainActor enum InteractiveTerminalSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
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
