#if DEBUG
import AppKit
import Foundation

@MainActor enum CompletionInputSelfTests {
    static func run(check: (Bool, String) -> Void) async {
        let window = NativeTerminalTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        let editor = CommandTextView(frame: scroll.bounds)
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isRichText = false; editor.isEditable = true
        editor.completionMenu.presentsWindows = false
        scroll.documentView = editor
        let field = NSTextField(frame: NSRect(x: 0, y: 195, width: 300, height: 24))
        surface.addSubview(scroll); surface.addSubview(field); window.contentView = surface
        defer { editor.dismissCompletionMenu(); window.contentView = nil; window.close() }
        window.makeKey(); window.makeFirstResponder(editor)
        var submissions = 0, forcedSubmissions = 0, cancellations = 0, history: [Int] = []
        editor.onSubmit = { submissions += 1 }
        editor.onForcedSubmit = { _ in forcedSubmissions += 1 }
        editor.onCancel = { cancellations += 1 }
        editor.onHistory = { history.append($0) }
        func reset(_ draft: String, candidates: [String] = [], preview: String? = nil) {
            editor.dismissCompletionMenu(); editor.unmarkText(); editor.isEditable = true
            editor.string = draft; editor.completion = preview; editor.completionCandidates = candidates
            editor.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
            window.makeFirstResponder(editor)
        }
        func event(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)!
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) {
            editor.keyDown(with: event(code, characters, modifiers: modifiers))
        }
        reset("echo", candidates: ["echo newest"], preview: "echo preview")
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        key(124, "\u{f703}")
        check(editor.string == "echo" && editor.selectedRange() == NSRange(location: 2, length: 0),
              "Right inside the draft moves the caret rather than replacing text with a ghost completion")
        key(48, "\t")
        check(!editor.completionMenu.isOpen && editor.string == "echo", "Tab in the middle of a draft does not open completion or rewrite the command")
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        key(48, "\t"); key(124, "\u{f703}")
        check(editor.string == "echo" && !editor.completionMenu.isOpen,
              "A selection prevents both history-menu opening and ghost replacement")
        editor.setSelectedRange(NSRange(location: 4, length: 0)); key(124, "\u{f703}")
        check(editor.string == "echo preview" && submissions == 0 && forcedSubmissions == 0,
              "An ordinary Right at the unselected line end accepts ghost text without executing")

        reset("ec", preview: "echo preview")
        key(126, "\u{f700}"); key(125, "\u{f701}")
        check(history == [-1, 1] && editor.string == "ec" && editor.completion == "echo preview",
              "Up and Down use history navigation while a ghost preview is visible")
        reset("echo")
        editor.setMarkedText("候", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 4, length: 0))
        let markedCandidate = editor.string + " complete"
        editor.completion = markedCandidate; editor.completionCandidates = [markedCandidate]
        check(editor.hasMarkedText(), "The completion IME fixture contains an actual marked-text composition")
        editor.showHistoryCompletionMenu(); key(124, "\u{f703}")
        check(!editor.completionMenu.isOpen && editor.string != markedCandidate && submissions == 0 && forcedSubmissions == 0,
              "Marked text retains AppKit input handling and cannot accept ghost or history completion")

        let candidates = ["echo newest", "echo older", "echo oldest", "echo newest", "other", "echo"]
        reset("echo", candidates: candidates, preview: "echo catalog")
        key(48, "\t")
        check(editor.completionMenu.isOpen && editor.completionMenu.candidates == Array(candidates.prefix(3)) && editor.string == "echo",
              "Tab opens distinct full-prefix history candidates without accepting the ghost or changing the draft")
        check(window.firstResponder === editor && editor.completionMenu.panel?.canBecomeKey == false,
              "The completion panel cannot become key and leaves the command editor as first responder")
        key(124, "\u{f703}")
        check(editor.string == "echo newest" && !editor.completionMenu.isOpen && submissions == 0 && forcedSubmissions == 0,
              "Right accepts only the selected history candidate into the editor")
        reset("echo", candidates: candidates)
        editor.showHistoryCompletionMenu(placement: .below)
        check(editor.completionMenu.visualCandidates == Array(candidates.prefix(3)) && editor.completionMenu.selectedVisualIndex == 0,
              "A menu below the caret places and selects the newest history command in its first row")
        key(125, "\u{f701}"); key(125, "\u{f701}"); key(125, "\u{f701}")
        check(editor.completionMenu.selectedCandidate == "echo oldest", "Down moves visually through a lower menu and clamps at its oldest row")
        key(53, "\u{1b}")
        check(!editor.completionMenu.isOpen && editor.string == "echo" && cancellations == 0,
              "Escape closes candidates while preserving the draft and avoiding the editor cancel action")
        editor.showHistoryCompletionMenu(placement: .above)
        check(editor.completionMenu.visualCandidates == Array(candidates.prefix(3).reversed()) && editor.completionMenu.selectedVisualIndex == 2,
              "A menu above the caret places and selects newest history at its bottom edge")
        key(126, "\u{f700}")
        check(editor.completionMenu.selectedCandidate == "echo older", "Up in an upper menu selects the visually higher older command")
        key(125, "\u{f701}"); key(125, "\u{f701}")
        check(editor.completionMenu.selectedCandidate == "echo newest", "Down in an upper menu returns toward the newest command and clamps")
        editor.completionMenu.acceptVisualRow(0)
        check(editor.string == "echo oldest" && submissions == 0 && forcedSubmissions == 0,
              "Clicking a visual row in a reversed menu fills the matching candidate without execution")

        reset("unmatched")
        key(48, "\t")
        check(editor.string == "unmatched" && !editor.completionMenu.isOpen, "Tab with no candidates neither inserts a literal tab nor submits")
        reset("echo\n ", candidates: ["echo\n next"])
        key(48, "\t")
        check(editor.string == "echo\n \t" && !editor.completionMenu.isOpen,
              "Tab in a multiline draft retains native NSTextView indentation instead of opening history completion")
        reset("", candidates: ["last command", "older command"])
        key(48, "\t")
        check(editor.completionMenu.isOpen && editor.completionMenu.selectedCandidate == "last command", "An empty draft can browse newest-first history through its empty prefix")
        key(53, "\u{1b}")
        check(editor.string.isEmpty, "Cancelling an empty-prefix history menu leaves the draft empty")
        let windowBaseline = NSApp.windows.count, childBaseline = window.childWindows?.count ?? 0
        for _ in 0..<6 { reset("echo", candidates: candidates); key(48, "\t"); key(53, "\u{1b}") }
        await Task.yield()
        check(NSApp.windows.count <= windowBaseline && (window.childWindows?.count ?? 0) == childBaseline,
              "Repeated completion panel creation and dismissal restores AppKit's window and child-window inventory")

        for modifiers: NSEvent.ModifierFlags in [[], .command, .option, .shift, [.command, .shift]] {
            reset("echo", candidates: candidates); key(48, "\t")
            key(36, "\r", modifiers: modifiers)
            check(editor.string == "echo newest" && submissions == 0 && forcedSubmissions == 0,
                  "Return modifier mask \(modifiers.rawValue) confirms a history candidate without submit or forced routing")
        }
        let menuFixture = CompletionShortcutFixture()
        defer { menuFixture.restore() }
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            editor.dismissCompletionMenu()
            let previousInvocations = menuFixture.invocations
            let shortcutWorks = NSApp.mainMenu?.performKeyEquivalent(with: event(36, "\r", modifiers: modifiers)) == true
            check(shortcutWorks && menuFixture.invocations == previousInvocations + 1,
                  "The registered Return menu shortcut is live when completion is closed for modifier mask \(modifiers.rawValue)")
            let shortcutBaseline = menuFixture.invocations
            reset("echo", candidates: candidates); key(48, "\t")
            NSApp.sendEvent(event(36, "\r", modifiers: modifiers))
            check(editor.string == "echo newest" && menuFixture.invocations == shortcutBaseline && submissions == 0 && forcedSubmissions == 0,
                  "AppKit event dispatch confirms completion before registered Return menu shortcuts for modifier mask \(modifiers.rawValue)")
        }

        reset("echo", candidates: candidates); key(48, "\t")
        editor.insertText("x", replacementRange: editor.selectedRange())
        check(!editor.completionMenu.isOpen && editor.string == "echox", "Typing dismisses the menu and edits the draft normally")
        reset("echo", candidates: candidates); key(48, "\t")
        editor.setSelectedRange(NSRange(location: 1, length: 0)); key(124, "\u{f703}")
        check(!editor.completionMenu.isOpen && editor.string == "echo" && editor.selectedRange().location == 2,
              "Moving the caret closes candidates and restores ordinary Right movement")
        reset("echo", candidates: candidates); key(48, "\t")
        window.makeFirstResponder(field)
        check(!editor.completionMenu.isOpen && editor.string == "echo", "Losing editor focus closes candidates without changing the draft")
        reset("echo", candidates: candidates); key(48, "\t")
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        editor.completionMenu.observeOutsideClick(outside)
        check(!editor.completionMenu.isOpen && editor.completionMenu.panel == nil && editor.string == "echo",
              "An outside click tears down the child panel and retains the draft")
        reset("echo", candidates: candidates); key(48, "\t")
        editor.isEditable = false; key(36, "\r", modifiers: .command)
        check(!editor.completionMenu.isOpen && editor.string == "echo" && submissions == 0 && forcedSubmissions == 0,
              "A disabled editor closes candidates and cannot submit through a modified confirmation key")
        editor.isEditable = true
        await Task.yield()
    }
}

@MainActor private final class CompletionShortcutFixture: NSObject {
    private let previous = NSApp.mainMenu
    private(set) var invocations = 0
    override init() {
        super.init()
        let menu = NSMenu(title: "Completion test"), commands = NSMenu(title: "Completion shortcuts")
        menu.autoenablesItems = false; commands.autoenablesItems = false
        let container = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            let item = NSMenuItem(title: "Must not execute", action: #selector(invoked(_:)), keyEquivalent: "\r")
            item.keyEquivalentModifierMask = modifiers; item.target = self; item.isEnabled = true
            commands.addItem(item)
        }
        container.submenu = commands; menu.addItem(container); NSApp.mainMenu = menu
    }
    @objc private func invoked(_ sender: Any?) { invocations += 1 }
    func restore() { NSApp.mainMenu = previous }
}
#endif
