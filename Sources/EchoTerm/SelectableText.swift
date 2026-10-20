import SwiftUI
import AppKit

enum SelectionClipboard {
    @discardableResult static func copy(_ text: String?, enabled: Bool, to pasteboard: NSPasteboard = .general) -> Bool {
        guard enabled, let text, !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

/// Only read-only transcript views opt into automatic copying. Editable fields
/// and their selection notifications never pass through this component.
final class CopySelectableTextView: NSTextView, NSTextViewDelegate {
    var copyOnSelection = false
    var selectionPasteboard = NSPasteboard.general
    var updatingContent = false
    var onClick: (() -> Void)?
    var onSelectionGesture: ((Bool) -> Void)?
    private var selectionActionDepth = 0
    private var changedDuringAction = false
    private var activatedLink = false
    private var ownedTextStorage: NSTextStorage?
    private weak var selectionTrackingWindow: NSWindow?
    private var pointerDragObserved = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        // NSTextView's designated initializer leaves the text system absent
        // when passed nil. Build it explicitly for the short transcript view.
        let resolved: NSTextContainer
        if let container { resolved = container }
        else {
            let storage = NSTextStorage(), layout = NSLayoutManager()
            resolved = NSTextContainer(containerSize: NSSize(width: max(1, frameRect.width), height: CGFloat.greatestFiniteMagnitude))
            layout.addTextContainer(resolved); storage.addLayoutManager(layout)
            ownedTextStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolved)
        delegate = self
        isEditable = false; isSelectable = true; drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
    }
    required init?(coder: NSCoder) { super.init(coder: coder); delegate = self }

    private func selectionAction(_ operation: () -> Void) {
        if selectionActionDepth == 0 { changedDuringAction = false }
        selectionActionDepth += 1
        operation()
        selectionActionDepth -= 1
        if selectionActionDepth == 0, changedDuringAction, !updatingContent, !isEditable {
            let source = string as NSString
            let pieces = selectedRanges.compactMap { value -> String? in
                let range = value.rangeValue
                guard range.location != NSNotFound, range.length > 0,
                      range.location <= source.length, range.length <= source.length - range.location else { return nil }
                return source.substring(with: range)
            }
            _ = SelectionClipboard.copy(pieces.joined(separator: "\n"), enabled: copyOnSelection, to: selectionPasteboard)
        }
    }
    override func mouseDown(with event: NSEvent) {
        performMouseSelection(event) { super.mouseDown(with: event) }
    }
    /// The operation remains AppKit's native text selection. The
    /// short-lived monitor observes only drag events from this mouse gesture.
    func performMouseSelection(_ event: NSEvent, operation: () -> Void) {
        onSelectionGesture?(true)
        selectionTrackingWindow = window; pointerDragObserved = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.observeSelectionDrag(event)
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            selectionTrackingWindow = nil
            onSelectionGesture?(false)
        }
        activatedLink = false
        selectionAction(operation)
        guard event.clickCount == 1, !pointerDragObserved, !activatedLink,
              event.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty,
              selectedRanges.allSatisfy({ $0.rangeValue.length == 0 }) else { return }
        onClick?()
    }
    func observeSelectionDrag(_ event: NSEvent) {
        guard event.type == .leftMouseDragged, let selectionTrackingWindow,
              event.window === selectionTrackingWindow else { return }
        pointerDragObserved = true
    }
    override func keyDown(with event: NSEvent) { selectionAction { super.keyDown(with: event) } }
    override func selectAll(_ sender: Any?) {
        selectionAction {
            super.selectAll(sender)
            // AppKit can omit the notification when the whole document was
            // already selected. An explicit Select All still commits it.
            changedDuringAction = true
        }
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        if selectionActionDepth > 0, !updatingContent { changedDuringAction = true }
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        activatedLink = true
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
        return true
    }
}

struct SelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    var copyOnSelection = false
    var label = "区块文本"
    var lineSpacing: CGFloat = 0
    var markdown = false
    var linkColor: NSColor? = nil
    var onClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> CopySelectableTextView {
        let view = CopySelectableTextView(frame: .zero, textContainer: nil)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }
    func updateNSView(_ view: CopySelectableTextView, context: Context) {
        view.copyOnSelection = copyOnSelection
        view.onClick = onClick
        let content = attributedText()
        view.updatingContent = true
        if view.textStorage?.isEqual(to: content) != true { view.textStorage?.setAttributedString(content); view.invalidateIntrinsicContentSize() }
        view.updatingContent = false
        if view.accessibilityLabel() != label { view.setAccessibilityLabel(label) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CopySelectableTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        let natural = max(1, (view.textStorage?.size().width ?? 1).rounded(.up))
        let width = max(1, proposal.width ?? natural)
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(ceil(font.ascender - font.descender + font.leading), ceil(layout.usedRect(for: container).height)))
    }
    private func attributedText() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard markdown, let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let output = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            var attributes = base
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = runFont
            if let url = run.link, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                attributes[.link] = url; attributes[.foregroundColor] = linkColor ?? color
            }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
}
