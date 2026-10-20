import SwiftUI
import AppKit

/// TextKit lays out only the visible part of a large document. A giant SwiftUI
/// Text inside a horizontal ScrollView otherwise asks for an unbounded width.
struct LongTextView: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    var label = "区块文本"
    var copyOnSelection = false
    var followOutput = false
    var onClick: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(containerSize: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; container.lineFragmentPadding = 0
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        let view = CopySelectableTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.drawsBackground = false; view.textContainerInset = NSSize(width: 0, height: 3)
        view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = OutputTextScrollView(); scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        scroll.documentView = view
        context.coordinator.attach(scroll)
        view.onSelectionGesture = { [weak coordinator = context.coordinator] active in coordinator?.setSelectionTracking(active) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? CopySelectableTextView else { return }
        view.copyOnSelection = copyOnSelection
        view.onClick = onClick
        context.coordinator.followEnabled = followOutput
        if !followOutput { context.coordinator.pendingFollow = false }
        let changed = view.string != text
        if changed && followOutput && context.coordinator.followsBottom && !context.coordinator.userScrollActive { context.coordinator.pendingFollow = true }
        context.coordinator.programmatic = true
        view.updatingContent = true
        if view.font != font { view.font = font }
        if view.textColor != color { view.textColor = color }
        if changed {
            let old = Array(view.string.utf16), new = Array(text.utf16)
            let anchor = context.coordinator.followsBottom ? nil : readingAnchor(view: view, scroll: scroll)
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            // Different supplementary scalars may share a high surrogate.
            // Never split a UTF-16 pair at the replacement boundary.
            if prefix > 0, prefix < old.count, (0xD800...0xDBFF).contains(old[prefix - 1]), (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
            if prefix > 0, prefix < new.count, (0xD800...0xDBFF).contains(new[prefix - 1]), (0xDC00...0xDFFF).contains(new[prefix]) { prefix -= 1 }
            let suffix = (text as NSString).substring(from: prefix)
            let replacement = NSAttributedString(string: suffix, attributes: [.font: font, .foregroundColor: color])
            view.textStorage?.replaceCharacters(in: NSRange(location: prefix, length: old.count - prefix), with: replacement)
            if let anchor, prefix <= anchor.location, let layout = view.layoutManager {
                let found = matchingAnchor(anchor, in: text as NSString)
                if found.location != NSNotFound {
                    // A rewrite or bounded-log trim can invalidate layout above
                    // the reader. Lay out only through that reading position,
                    // then restore the still-present line and pixel offset.
                    layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(new.count, found.location + anchor.visibleLength)))
                    let glyph = layout.glyphIndexForCharacter(at: found.location)
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let target = line.minY + view.textContainerOrigin.y + anchor.offset
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: target))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
        view.updatingContent = false
        context.coordinator.programmatic = false
        context.coordinator.refreshGeometry()
        if view.accessibilityLabel() != label { view.setAccessibilityLabel(label) }
        if changed { context.coordinator.followIfNeeded() }
    }
    private struct ReadingAnchor { let location: Int; let context: String; let offset: CGFloat; let visibleLength: Int }
    private func matchingAnchor(_ anchor: ReadingAnchor, in source: NSString) -> NSRange {
        var best = NSRange(location: NSNotFound, length: 0), distance = Int.max, start = 0
        while start < source.length {
            let candidate = source.range(of: anchor.context, options: .literal, range: NSRange(location: start, length: source.length - start))
            guard candidate.location != NSNotFound else { break }
            let delta = abs(candidate.location - anchor.location)
            if delta < distance { best = candidate; distance = delta }
            start = candidate.location + 1
        }
        return best
    }
    private func readingAnchor(view: NSTextView, scroll: NSScrollView) -> ReadingAnchor? {
        guard let layout = view.layoutManager, let container = view.textContainer, !view.string.isEmpty else { return nil }
        let source = view.string as NSString
        let visible = scroll.contentView.documentVisibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return nil }
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard characters.location < source.length else { return nil }
        let range = source.lineRange(for: NSRange(location: characters.location, length: 0))
        var contextEnd = NSMaxRange(range)
        for _ in 0..<2 where contextEnd < source.length {
            contextEnd = NSMaxRange(source.lineRange(for: NSRange(location: contextEnd, length: 0)))
        }
        contextEnd = min(contextEnd, range.location + 512)
        if contextEnd > range.location, contextEnd < source.length,
           (0xD800...0xDBFF).contains(source.character(at: contextEnd - 1)), (0xDC00...0xDFFF).contains(source.character(at: contextEnd)) { contextEnd -= 1 }
        let glyph = layout.glyphIndexForCharacter(at: range.location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return ReadingAnchor(location: range.location, context: source.substring(with: NSRange(location: range.location, length: contextEnd - range.location)),
                             offset: scroll.contentView.bounds.origin.y - line.minY - view.textContainerOrigin.y,
                             visibleLength: max(1, characters.length + characters.location - range.location))
    }
    final class Coordinator {
        weak var scroll: OutputTextScrollView?
        var followEnabled = false
        var followsBottom = true
        var programmatic = false
        var pendingFollow = false
        private var liveScrollActive = false
        private var selectionTracking = false
        private var explicitBottomDuringTracking = false
        var userScrollActive: Bool { liveScrollActive || selectionTracking }
        private var observers: [NSObjectProtocol] = []
        private var lastClipBounds: NSRect?
        private var lastDocumentSize: NSSize?
        func attach(_ scroll: OutputTextScrollView) {
            self.scroll = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.clipBoundsChanged()
            })
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in self?.refreshGeometry() })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.liveScrollActive = true; self?.pendingFollow = false; self?.explicitBottomDuringTracking = false
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                guard let self, self.liveScrollActive else { return }
                if !self.explicitBottomDuringTracking { self.recordUserScroll() }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                guard let self, self.liveScrollActive else { return }
                self.liveScrollActive = false
                if self.explicitBottomDuringTracking { self.requestBottomFollow() }
                else { self.recordUserScroll() }
            })
            scroll.onUserScroll = { [weak self] in self?.recordUserScroll() }
            scroll.onUserRequestedBottom = { [weak self] in self?.requestBottomFollow() }
            scroll.observeVerticalScrollerActions()
            refreshGeometry()
        }
        func refreshGeometry() {
            lastClipBounds = scroll?.contentView.bounds
            lastDocumentSize = scroll?.documentView?.frame.size
        }
        private func clipBoundsChanged() {
            guard let scroll, let previous = lastClipBounds, let documentSize = lastDocumentSize else { refreshGeometry(); return }
            let current = scroll.contentView.bounds
            let currentDocumentSize = scroll.documentView?.frame.size
            defer { refreshGeometry() }
            // AX scrollbar actions can move the clip without posting AppKit's
            // live-scroll lifecycle. Treat a real upward viewport move as a
            // pause even while an output-follow action is queued. Extent/layout
            // changes and our own scrolling only update the geometry baseline.
            guard !programmatic, current.size == previous.size, currentDocumentSize == documentSize else { return }
            if current.origin.y < previous.origin.y - 0.5 {
                pendingFollow = false; followsBottom = isAtBottom
            } else if isAtBottom {
                followsBottom = true
            } else if !pendingFollow, !userScrollActive {
                followsBottom = false
            }
        }
        func recordUserScroll() {
            guard !programmatic else { return }
            explicitBottomDuringTracking = false
            pendingFollow = false; followsBottom = isAtBottom
        }
        private func requestBottomFollow() {
            guard !programmatic else { return }
            followsBottom = true
            // During knob/wheel tracking, TextKit can discover more document
            // extent before AppKit sends didEndLiveScroll. Preserve the user's
            // explicit bottom request until then; geometry alone cannot erase it.
            explicitBottomDuringTracking = userScrollActive
            if userScrollActive { pendingFollow = false }
            else if followEnabled { pendingFollow = true; followIfNeeded() }
        }
        func setSelectionTracking(_ active: Bool) {
            selectionTracking = active
            explicitBottomDuringTracking = false
            pendingFollow = false
            if !active { recordUserScroll() }
        }
        private var isAtBottom: Bool {
            guard let scroll, let document = scroll.documentView else { return true }
            return document.bounds.maxY - scroll.contentView.documentVisibleRect.maxY <= 8
        }
        func followIfNeeded() {
            guard followEnabled, pendingFollow, !userScrollActive else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.followEnabled, self.pendingFollow, self.followsBottom, !self.userScrollActive,
                      let view = self.scroll?.documentView as? NSTextView else { return }
                self.programmatic = true
                view.scrollRangeToVisible(NSRange(location: (view.string as NSString).length, length: 0))
                self.programmatic = false; self.pendingFollow = false
                self.refreshGeometry()
            }
        }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

final class OutputTextScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?
    var onUserRequestedBottom: (() -> Void)?
    private weak var observedScroller: NSScroller?
    private weak var originalScrollerTarget: AnyObject?
    private var originalScrollerAction: Selector?
    func observeVerticalScrollerActions() {
        guard let scroller = verticalScroller, observedScroller !== scroller else { return }
        observedScroller = scroller
        originalScrollerTarget = scroller.target; originalScrollerAction = scroller.action
        scroller.target = self; scroller.action = #selector(handleVerticalScroller(_:))
    }
    @objc private func handleVerticalScroller(_ sender: NSScroller) {
        // AX value changes and knob tracking carry an explicit bottom request.
        // Capture it before TextKit lays out a previously unseen tail and
        // changes the estimated document extent during the original action.
        let part = sender.hitPart
        let requestedBottom = sender.doubleValue >= 0.999_999 && (part == .knob || part == .noPart)
        if let action = originalScrollerAction { NSApp.sendAction(action, to: originalScrollerTarget, from: sender) }
        if requestedBottom || (part == .incrementPage && sender.doubleValue >= 0.999_999) {
            onUserRequestedBottom?()
        } else { onUserScroll?() }
    }
    override func scrollWheel(with event: NSEvent) {
        let wasAtBottom = (verticalScroller?.doubleValue ?? 0) >= 0.999_999
        super.scrollWheel(with: event)
        if event.scrollingDeltaY < 0 && (wasAtBottom || (verticalScroller?.doubleValue ?? 0) >= 0.999_999) { onUserRequestedBottom?() }
        else { onUserScroll?() }
    }
}

enum TextLayoutPolicy {
    static func needsViewport(_ text: String) -> Bool {
        if text.utf8.count > 4_000 { return true }
        return text.lazy.filter { $0 == "\n" }.prefix(21).count >= 20
    }
}
