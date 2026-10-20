import AppKit

/// Keeps Ctrl-C available when the running command is shown as a Block rather
/// than an attached native terminal. Editable fields retain their own keys.
@MainActor final class WindowCommandInputRouter {
    private weak var window: NSWindow?
    private weak var workspace: Workspace?
    private var monitor: Any?

    init(window: NSWindow, workspace: Workspace) {
        self.window = window
        self.workspace = workspace
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard Self.isInterrupt(event), let window, event.window === window,
              let workspace else { return false }
        let terminalResponder = window.firstResponder as? BlockTerminalView
        // A detached/disabled native responder must never receive AppKit's
        // inherited keyDown as a fallback if a modal or another pane owns input.
        let consumesHiddenTerminal = terminalResponder?.nativeInputIsPresented() == false
        guard window.isKeyWindow, !workspace.inputBlockedByModal, !workspace.assistantWantsFocus,
              let session = workspace.activeSession, session.running, !session.exited,
              !session.showSearch, let blockID = session.runningBlockID else { return consumesHiddenTerminal }

        // The terminal's own dispatcher must send the key exactly once, retaining
        // raw/TUI semantics. Never intercept a different terminal's responder.
        if let terminal = terminalResponder {
            guard terminal === session.terminal, session.usesBlockEditor,
                  !session.presentsInteractiveTerminal else { return consumesHiddenTerminal }
        }
        if let text = window.firstResponder as? NSTextView, text.isEditable || text.isFieldEditor { return false }
        if window.firstResponder is NSTextField { return false }
        return session.sendNativeInterrupt(expectedBlockID: blockID) || consumesHiddenTerminal
    }

    static func isInterrupt(_ event: NSEvent) -> Bool {
        TerminalSession.isNativeInterrupt(event) && !event.modifierFlags.contains(.command)
    }
}
