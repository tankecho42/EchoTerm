import SwiftUI
import AppKit

/// A transparent terminal-style input line that belongs to the scrollable block.
struct InlineCommandEditor: NSViewRepresentable {
    @Environment(\.isEnabled) private var environmentEnabled
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont
    var color: NSColor
    var caret: NSColor
    var focusRequest: UUID
    var enabled = true
    var automaticallyFocus = true
    var explicitFocus = false
    var focusOwnerID: UUID? = nil
    var completion: String? = nil
    var completionCandidates: [String] = []
    var commandAssessment: CommandAssessment? = nil
    var onForcedSubmit: ((InputRoute) -> Void)? = nil
    var onSubmit: () -> Void
    var onHistory: (Int) -> Void
    var onFocus: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let view = CommandTextView()
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isRichText = false
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.delegate = context.coordinator
        view.onFocusEligibilityChanged = { [weak coordinator = context.coordinator, weak view] in
            if let view { coordinator?.requestFocus(view) }
        }
        view.setAccessibilityLabel("终端命令输入")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CommandTextView else { return }
        context.coordinator.parent = self
        view.onSubmit = onSubmit; view.onHistory = onHistory; view.onFocus = onFocus; view.onCancel = onCancel
        view.completion = completion; view.completionCandidates = completionCandidates; view.onForcedSubmit = onForcedSubmit
        let styleChanged = context.coordinator.styledFont != font || context.coordinator.styledColor != color
        if styleChanged {
            if view.font != font { view.font = font }
            view.textColor = color
        }
        if view.insertionPointColor != caret { view.insertionPointColor = caret }
        let canEdit = enabled && environmentEnabled
        let canFocus = automaticallyFocus && canEdit
        if !canEdit { view.dismissCompletionMenu() }
        if view.isEditable != canEdit { view.isEditable = canEdit }
        view.allowsAutomaticFocus = canFocus
        if !canFocus, let window = view.window, window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
        view.focusOwnerID = focusOwnerID
        if styleChanged { view.typingAttributes = [.font: font, .foregroundColor: color] }
        if view.string != text && !view.hasMarkedText() {
            view.dismissCompletionMenu()
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure(view)
        }
        if !view.hasMarkedText() && (styleChanged || context.coordinator.styledText != view.string || context.coordinator.styledAssessment != commandAssessment) {
            context.coordinator.styledText = view.string
            context.coordinator.styledFont = font; context.coordinator.styledColor = color
            context.coordinator.styledAssessment = commandAssessment
            let all = NSRange(location: 0, length: (view.string as NSString).length)
            view.textStorage?.addAttributes([.foregroundColor: color, .font: font], range: all)
            if let assessment = commandAssessment, let range = assessment.range, NSMaxRange(range) <= all.length {
                let tint: NSColor = assessment.dynamic ? color : assessment.isCommand ? NSColor.systemGreen : NSColor.systemRed
                view.textStorage?.addAttribute(.foregroundColor, value: tint, range: range)
            }
        }
        view.needsDisplay = true
        view.setAccessibilityHelp(completion.map { "右箭头接受灰色补全：\($0)。Tab 显示历史候选；上下键浏览匹配历史。" } ?? "Tab 显示历史候选；上下键浏览匹配历史；Return 提交；Command Return 强制执行；Option Return 询问 AI。")
        context.coordinator.requestFocus(view)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? CommandTextView else { return }
        view.allowsAutomaticFocus = false
        view.dismissCompletionMenu()
        view.onFocusEligibilityChanged = nil
        if let window = view.window, window.firstResponder === view { window.makeFirstResponder(nil) }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineCommandEditor
        var lastFocus: UUID?
        private var focusQueued = false
        var styledText: String?
        var styledFont: NSFont?
        var styledColor: NSColor?
        var styledAssessment: CommandAssessment?
        init(_ parent: InlineCommandEditor) { self.parent = parent }
        func requestFocus(_ view: CommandTextView) {
            guard view.isEditable, view.allowsAutomaticFocus, lastFocus != parent.focusRequest,
                  !focusQueued else { return }
            focusQueued = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                self.focusQueued = false
                guard let view, view.isEditable, view.allowsAutomaticFocus,
                      self.lastFocus != self.parent.focusRequest, let window = view.window,
                      window.isKeyWindow,
                      CommandTextView.canRequestFocus(in: window, ownerID: self.parent.focusOwnerID,
                                                      explicit: self.parent.explicitFocus) else { return }
                if window.firstResponder === view {
                    self.lastFocus = self.parent.focusRequest
                    view.onFocus?()
                } else if window.makeFirstResponder(view), window.firstResponder === view {
                    self.lastFocus = self.parent.focusRequest
                }
            }
        }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            styledText = nil
            parent.text = view.string
            measure(view)
        }
        func textViewDidChangeSelection(_ notification: Notification) { (notification.object as? NSTextView)?.needsDisplay = true }
        func measure(_ view: NSTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            let next: CGFloat
            if view.string.utf8.count > 4_000 { next = 160 }
            else { layout.ensureLayout(for: container); next = max(23, min(160, ceil(layout.usedRect(for: container).height) + 3)) }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(self.parent.height - next) > 1 else { return }
                self.parent.height = next
            }
        }
    }
}

final class CommandTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onHistory: ((Int) -> Void)?
    var onFocus: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocusEligibilityChanged: (() -> Void)?
    var focusOwnerID: UUID?
    private var keyWindowObserver: NSObjectProtocol?
    var allowsAutomaticFocus = true
    var completion: String?
    var completionCandidates: [String] = [] { didSet { if oldValue != completionCandidates { dismissCompletionMenu() } } }
    let completionMenu = CompletionMenuController()
    var onForcedSubmit: ((InputRoute) -> Void)?
    private var canComplete: Bool {
        guard let completion else { return false }
        return !hasMarkedText() && !string.isEmpty && !string.contains("\n") && selectedRange().length == 0 && selectedRange().location == (string as NSString).length && completion.hasPrefix(string) && completion != string
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !completionMenu.isOpen, canComplete, let completion, let font, let window else { return }
        let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let point = convert(window.convertFromScreen(screen), from: nil).origin
        let suffix = String(completion.dropFirst(string.count))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        (suffix as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5)])
        NSGraphicsContext.restoreGraphicsState()
    }
    /// Automatic completion focus never displaces another editable field. An
    /// explicit block click may transfer ownership, without altering its draft.
    static func canRequestFocus(in window: NSWindow, ownerID: UUID?, explicit: Bool) -> Bool {
        if explicit { return true }
        if let editor = window.firstResponder as? CommandTextView {
            return editor.focusOwnerID == ownerID
        }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        if let field = window.firstResponder as? NSTextField, field.isEditable { return false }
        return true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        dismissCompletionMenu()
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver); self.keyWindowObserver = nil }
        if let window {
            keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                self?.onFocusEligibilityChanged?()
            }
            onFocusEligibilityChanged?()
        }
    }
    deinit { if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) } }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override func resignFirstResponder() -> Bool {
        dismissCompletionMenu()
        return super.resignFirstResponder()
    }
    override func didChangeText() {
        dismissCompletionMenu()
        super.didChangeText()
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        dismissCompletionMenu()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    func dismissCompletionMenu() { completionMenu.close(); needsDisplay = true }
    func showHistoryCompletionMenu(placement: CompletionMenuPlacement? = nil) {
        guard isEditable, !hasMarkedText(), !string.contains("\n"), selectedRange().length == 0,
              selectedRange().location == (string as NSString).length,
              let window, window.isKeyWindow, window.firstResponder === self else { return }
        let prefix = string
        var seen: Set<String> = []
        let candidates = completionCandidates.filter { $0 != prefix && $0.hasPrefix(prefix) && seen.insert($0).inserted }
        completionMenu.show(candidates: candidates, for: self, placementOverride: placement,
                            onKey: { [weak self] in self?.handleCompletionMenuKey($0) ?? false },
                            onAccept: { [weak self] in self?.acceptHistoryCompletion($0, prefix: prefix) },
                            onClose: { [weak self] in self?.needsDisplay = true })
        needsDisplay = true
    }
    private func acceptHistoryCompletion(_ candidate: String, prefix: String) {
        guard isEditable, !hasMarkedText(), string == prefix, candidate != prefix,
              selectedRange().length == 0, selectedRange().location == (string as NSString).length,
              candidate.hasPrefix(prefix), completionCandidates.contains(candidate),
              let window, window.isKeyWindow, window.firstResponder === self else { return }
        insertText(candidate, replacementRange: NSRange(location: 0, length: (string as NSString).length))
    }
    @discardableResult func handleCompletionMenuKey(_ event: NSEvent) -> Bool {
        guard completionMenu.isOpen else { return false }
        guard isEditable, !hasMarkedText(), selectedRange().length == 0,
              selectedRange().location == (string as NSString).length,
              let window, event.window === window, window.isKeyWindow, window.firstResponder === self else {
            dismissCompletionMenu(); return false
        }
        // Return is a confirmation even with Command/Option/Shift held. The
        // panel's scoped event monitor reaches this before app menu shortcuts.
        if event.keyCode == 36 || event.keyCode == 76 { completionMenu.acceptSelection(); return true }
        if event.keyCode == 53 { dismissCompletionMenu(); return true }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            switch event.keyCode {
            case 124: completionMenu.acceptSelection(); return true
            case 126: completionMenu.moveVisually(-1); return true
            case 125: completionMenu.moveVisually(1); return true
            case 48: return true
            default: break
            }
        }
        dismissCompletionMenu()
        return false
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if completionMenu.isOpen && (event.keyCode == 36 || event.keyCode == 76), handleCompletionMenuKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        guard isEditable else { dismissCompletionMenu(); return }
        if handleCompletionMenuKey(event) { return }
        if !hasMarkedText() {
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.command), let onForcedSubmit { onForcedSubmit(.shell) }
                else if event.modifierFlags.contains(.option), let onForcedSubmit { onForcedSubmit(.assistant) }
                else if event.modifierFlags.contains(.shift) { super.insertNewline(nil) }
                else { onSubmit?() }
                return
            }
            if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "c" { onCancel?(); return }
            if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if event.keyCode == 124, canComplete, let completion {
                    insertText(completion, replacementRange: NSRange(location: 0, length: (string as NSString).length)); return
                }
                if event.keyCode == 48, !string.contains("\n") { showHistoryCompletionMenu(); return }
                if !string.contains("\n") {
                    if event.keyCode == 126 { onHistory?(-1); return }
                    if event.keyCode == 125 { onHistory?(1); return }
                }
            }
        }
        super.keyDown(with: event)
    }
}
