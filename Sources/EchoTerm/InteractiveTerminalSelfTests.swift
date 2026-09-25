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
            let document = fixture.appendingPathComponent("\(name) editable.txt")
            let dimensions = fixture.appendingPathComponent("\(name)-dimensions")
            let contents = (1...60).map { String(format: "line-%03d", $0) }.joined(separator: "\n") + "\n"
            try contents.write(to: document, atomically: true, encoding: .utf8)
            let session = TerminalSession(directory: fixture.path, loadShellConfig: false, shellPath: shell)
            session.usesBlockEditor = true
            defer { session.close() }
            let viewport = TerminalViewport(terminal: session.terminal)
            viewport.frame = NSRect(x: 0, y: 0, width: 930, height: 640)
            viewport.layout()
            session.start()
            try await wait { session.ready }
            session.draft = "/usr/bin/vim -Nu NONE -n -i NONE '\(document.path)'"
            session.execute()
            try await wait { session.alternateScreen && screen(session).contains("line-001") }
            try await Task.sleep(nanoseconds: 120_000_000)
            check(session.presentsInteractiveTerminal && session.liveOutput.isEmpty,
                  "\(name): Vim enters the interactive viewport without a duplicate text snapshot")
            check(session.terminal.bounds.size == viewport.bounds.size && session.terminal.bounds.height > 320,
                  "\(name): native terminal fills the available viewport instead of a fixed-height block")

            // Exercise real terminal input and save only our disposable fixture.
            session.terminal.send(txt: "ggi修复测试 ")
            session.terminal.send(txt: "\u{1b}:w\r")
            try await wait { (try? String(contentsOf: document, encoding: .utf8))?.hasPrefix("修复测试 line-001") == true }
            check(true, "\(name): Vim receives modal keys and saves Unicode edits through the PTY")
            session.terminal.send(txt: "G")
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
                session.terminal.send(txt: ":call writefile([string(&lines), string(&columns)], '\(dimensions.path)')\r")
                try await wait { FileManager.default.fileExists(atPath: dimensions.path) }
                let actual = try String(contentsOf: dimensions, encoding: .utf8).split(separator: "\n").compactMap { Int($0) }
                check(actual == [grid.rows, grid.cols], "\(name): real Vim handles SIGWINCH at \(grid.cols) × \(grid.rows)")
            }

            session.terminal.send(txt: ":q\r")
            try await wait { !session.running }
            check(!session.alternateScreen && !session.presentsInteractiveTerminal && session.blocks.last?.exitCode == 0,
                  "\(name): quitting Vim restores the block editor and records completion")
            check(session.blocks.last?.output.contains("line-060") == false,
                  "\(name): Vim's alternate-screen contents do not leak into command history")
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
