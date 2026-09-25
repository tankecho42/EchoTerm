import SwiftUI
import AppKit

/// TextKit lays out only the visible part of a large document. A giant SwiftUI
/// Text inside a horizontal ScrollView otherwise asks for an unbounded width.
struct LongTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    var label = "区块文本"
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.textContainerInset = NSSize(width: 0, height: 3)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.font != font { view.font = font }
        if view.textColor != color { view.textColor = color }
        if view.string != text { view.string = text }
        if view.accessibilityLabel() != label { view.setAccessibilityLabel(label) }
    }
}

enum TextLayoutPolicy {
    static func needsViewport(_ text: String) -> Bool {
        if text.utf8.count > 4_000 { return true }
        return text.lazy.filter { $0 == "\n" }.prefix(21).count >= 20
    }
}
