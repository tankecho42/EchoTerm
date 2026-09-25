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
    var completion: String? = nil
    var commandAssessment: CommandAssessment? = nil
    var onCycleCompletion: ((Int) -> String?)? = nil
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
        view.setAccessibilityLabel("终端命令输入")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CommandTextView else { return }
        context.coordinator.parent = self
        view.onSubmit = onSubmit; view.onHistory = onHistory; view.onFocus = onFocus; view.onCancel = onCancel
        view.completion = completion; view.onCycleCompletion = onCycleCompletion; view.onForcedSubmit = onForcedSubmit
        let styleChanged = context.coordinator.styledFont != font || context.coordinator.styledColor != color
        if styleChanged {
            if view.font != font { view.font = font }
            view.textColor = color
        }
        if view.insertionPointColor != caret { view.insertionPointColor = caret }
        let canEdit = enabled && environmentEnabled
        let canFocus = automaticallyFocus && canEdit
        if view.isEditable != canEdit { view.isEditable = canEdit }
        view.allowsAutomaticFocus = canFocus
        if !canFocus { context.coordinator.lastFocus = focusRequest; view.wantsInitialFocus = false }
        if styleChanged { view.typingAttributes = [.font: font, .foregroundColor: color] }
        if view.string != text && !view.hasMarkedText() {
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
        view.setAccessibilityHelp(completion.map { "补全：\($0)。Tab 接受，上下切换。" } ?? "Return 提交；Command Return 强制执行；Option Return 询问 AI。")
        if canFocus && context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            view.wantsInitialFocus = true
            DispatchQueue.main.async { [weak view] in
                guard let view, view.isEditable, view.allowsAutomaticFocus, let window = view.window else { return }
                window.makeFirstResponder(view); view.wantsInitialFocus = false
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineCommandEditor
        var lastFocus: UUID?
        var styledText: String?
        var styledFont: NSFont?
        var styledColor: NSColor?
        var styledAssessment: CommandAssessment?
        init(_ parent: InlineCommandEditor) { self.parent = parent }
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
    var wantsInitialFocus = false
    var allowsAutomaticFocus = true
    var completion: String?
    var onCycleCompletion: ((Int) -> String?)?
    var onForcedSubmit: ((InputRoute) -> Void)?
    private var canComplete: Bool {
        guard let completion else { return false }
        return !hasMarkedText() && !string.isEmpty && !string.contains("\n") && selectedRange().length == 0 && selectedRange().location == (string as NSString).length && completion.hasPrefix(string) && completion != string
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard canComplete, let completion, let font, let window else { return }
        let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
        let point = convert(window.convertFromScreen(screen), from: nil).origin
        let suffix = String(completion.dropFirst(string.count))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        (suffix as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5)])
        NSGraphicsContext.restoreGraphicsState()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsInitialFocus && isEditable && allowsAutomaticFocus { DispatchQueue.main.async { [weak self] in guard let self, self.allowsAutomaticFocus else { return }; self.window?.makeFirstResponder(self); self.wantsInitialFocus = false } }
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocus?() }
        return result
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText() {
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.command), let onForcedSubmit { onForcedSubmit(.shell) }
                else if event.modifierFlags.contains(.option), let onForcedSubmit { onForcedSubmit(.assistant) }
                else if event.modifierFlags.contains(.shift) { super.insertNewline(nil) }
                else { onSubmit?() }
                return
            }
            if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "c" { onCancel?(); return }
            if !string.contains("\n") && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                if event.keyCode == 48, canComplete, let completion {
                    insertText(completion, replacementRange: NSRange(location: 0, length: (string as NSString).length)); return
                }
                if canComplete, let onCycleCompletion {
                    if event.keyCode == 126 { completion = onCycleCompletion(-1); needsDisplay = true; return }
                    if event.keyCode == 125 { completion = onCycleCompletion(1); needsDisplay = true; return }
                }
                if event.keyCode == 126 { onHistory?(-1); return }
                if event.keyCode == 125 { onHistory?(1); return }
            }
        }
        super.keyDown(with: event)
    }
}
