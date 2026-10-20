#if DEBUG
import AppKit
import Foundation

@MainActor enum WindowCommandInputSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        for shell in ["/bin/zsh", "/bin/bash"] {
            let workspace = Workspace()
            let session = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: shell)
            session.usesBlockEditor = true
            let background = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: shell)
            background.usesBlockEditor = true
            let tab = WorkspaceTab(title: "interrupt fixture", root: .leaf(session).splitting(session.id, vertical: true, newSession: background), activeSessionID: session.id)
            workspace.tabs = [tab]; workspace.selectedTabID = tab.id
            defer { workspace.closeAll() }
            let window = NativeTerminalTestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let surface = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
            let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
            surface.addSubview(field); window.contentView = surface
            defer { window.contentView = nil; window.close() }
            let router = WindowCommandInputRouter(window: window, workspace: workspace)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: "\u{3}",
                                        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
            session.start(); background.start()
            try await wait { session.ready && background.ready }
            session.draft = "printf 'interrupt-ready\\n'; sleep 30"; session.execute()
            background.draft = "printf 'background-ready\\n'; sleep 30"; background.execute()
            try await wait { session.liveOutput.contains("interrupt-ready") && background.liveOutput.contains("background-ready") }
            session.interactiveView = false
            let revision = session.nativeInputRevision

            window.makeFirstResponder(field)
            check(!router.handle(event) && session.nativeInputRevision == revision && session.running,
                  "\(shell): Block-view Ctrl-C preserves editable-field input instead of interrupting a command")
            window.makeFirstResponder(nil)
            workspace.showSettings = true
            let settingsBlocked = !router.handle(event)
            workspace.showSettings = false; workspace.pendingQuit = true
            let quitBlocked = !router.handle(event)
            workspace.pendingQuit = false; workspace.pendingClose = [session.id]
            let closeBlocked = !router.handle(event)
            workspace.pendingClose = nil; workspace.assistantWantsFocus = true
            let assistantBlocked = !router.handle(event)
            workspace.assistantWantsFocus = false; session.showSearch = true
            let searchBlocked = !router.handle(event)
            session.showSearch = false; window.simulatedKeyEligibility = false
            let inactiveBlocked = !router.handle(event)
            window.simulatedKeyEligibility = true
            check(settingsBlocked && quitBlocked && closeBlocked && assistantBlocked && searchBlocked && inactiveBlocked && session.nativeInputRevision == revision,
                  "\(shell): window interrupt fallback respects modal, search, assistant and inactive-window gates")

            // The terminal remains detached: the window route reaches the same
            // original foreground job without requiring an editable prompt.
            check(session.terminal.window == nil && router.handle(event),
                  "\(shell): Ctrl-C is routed from Block view with no attached native terminal")
            try await wait { !session.running }
            check(session.blocks.last?.exitCode == 130 && session.nativeInputRevision == revision + 1 && background.running,
                  "\(shell): routed Ctrl-C interrupts the original foreground job once and leaves the other pane running")
            check(!router.handle(event), "\(shell): finished commands do not receive a stale window interrupt")
            session.draft = "printf 'after-window-interrupt\\n'"; session.execute()
            try await wait { !session.running }
            check(session.blocks.last?.exitCode == 0 && session.blocks.last?.output.contains("after-window-interrupt") == true,
                  "\(shell): shell remains usable after Block-view keyboard interruption")
        }
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw AIError.message("Window command input fixture timed out")
    }
}
#endif
