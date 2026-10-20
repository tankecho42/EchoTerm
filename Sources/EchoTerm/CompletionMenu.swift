import AppKit

enum CompletionMenuPlacement { case above, below }

/// A child panel that leaves keyboard input with the command editor.
@MainActor final class CompletionMenuController: NSObject {
    private(set) var isOpen = false
    private(set) var candidates: [String] = []
    private(set) var selectedIndex = 0
    private(set) var placement = CompletionMenuPlacement.below
    var visualCandidates: [String] { placement == .above ? Array(candidates.reversed()) : candidates }
    var selectedVisualIndex: Int { placement == .above ? candidates.count - 1 - selectedIndex : selectedIndex }
    var selectedCandidate: String? { candidates.indices.contains(selectedIndex) ? candidates[selectedIndex] : nil }
    var presentsWindows = true
    private(set) var panel: NSPanel?
    private weak var owner: NSTextView?
    private weak var ownerWindow: NSWindow?
    private var list: CompletionListView?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var accept: ((String) -> Void)?
    private var closed: (() -> Void)?
    private var keyHandler: ((NSEvent) -> Bool)?

    func show(candidates: [String], for editor: NSTextView, placementOverride: CompletionMenuPlacement? = nil,
              onKey: @escaping (NSEvent) -> Bool, onAccept: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        close()
        guard !candidates.isEmpty, let window = editor.window else { return }
        self.candidates = candidates; selectedIndex = 0
        owner = editor; ownerWindow = window; accept = onAccept; closed = onClose; keyHandler = onKey
        let end = min((editor.string as NSString).length, NSMaxRange(editor.selectedRange()))
        let caret = editor.firstRect(forCharacterRange: NSRange(location: end, length: 0), actualRange: nil)
        let available = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let wanted = CGFloat(min(8, candidates.count)) * CompletionListView.rowHeight + 8
        let below = max(0, caret.minY - available.minY - 5), above = max(0, available.maxY - caret.maxY - 5)
        placement = placementOverride ?? (below >= wanted || below >= above ? .below : .above)
        let room = placement == .below ? below : above
        let height = min(wanted, max(CompletionListView.rowHeight + 8, room))
        let width = min(640, max(260, min(available.width - 16, editor.bounds.width + 30)))
        let x = min(max(available.minX + 8, caret.minX), available.maxX - width - 8)
        let proposedY = placement == .below ? caret.minY - height - 5 : caret.maxY + 5
        let y = min(max(available.minY + 4, proposedY), available.maxY - height - 4)
        let panel = CompletionPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hasShadow = true; panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true; panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.backgroundColor = .windowBackgroundColor; panel.appearance = editor.effectiveAppearance
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.drawsBackground = false; scroll.hasVerticalScroller = candidates.count > 8; scroll.scrollerStyle = .overlay
        let list = CompletionListView(candidates: visualCandidates, width: width,
                                      font: .monospacedSystemFont(ofSize: min(13, max(11, editor.font?.pointSize ?? 12)), weight: .regular))
        list.choose = { [weak self] row in self?.acceptVisualRow(row) }
        scroll.documentView = list; panel.contentView = scroll
        self.panel = panel; self.list = list; isOpen = true
        updateSelection()
        if presentsWindows { window.addChildWindow(panel, ordered: .above); panel.orderFront(nil) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.type == .keyDown, event.window === self.ownerWindow,
               self.ownerWindow?.firstResponder === self.owner, self.keyHandler?(event) == true { return nil }
            if event.type != .keyDown { self.observeOutsideClick(event) }
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        for name in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: editor, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }
    func moveVisually(_ delta: Int) {
        guard isOpen, !candidates.isEmpty else { return }
        let row = max(0, min(candidates.count - 1, selectedVisualIndex + delta))
        selectedIndex = placement == .above ? candidates.count - 1 - row : row
        updateSelection()
    }
    func acceptSelection() {
        guard let candidate = selectedCandidate, isOpen else { return }
        let action = accept
        close()
        action?(candidate)
    }
    func acceptVisualRow(_ row: Int) {
        guard candidates.indices.contains(row), isOpen else { return }
        selectedIndex = placement == .above ? candidates.count - 1 - row : row
        acceptSelection()
    }
    func observeOutsideClick(_ event: NSEvent) {
        if isOpen, event.window !== panel { close() }
    }
    private func updateSelection() {
        list?.select(row: selectedVisualIndex)
    }
    func close() {
        guard isOpen || panel != nil else { return }
        isOpen = false
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        if let panel { ownerWindow?.removeChildWindow(panel); panel.orderOut(nil); panel.contentView = nil; panel.close() }
        panel = nil; list = nil; owner = nil; ownerWindow = nil; accept = nil; keyHandler = nil
        let action = closed; closed = nil; action?()
    }
    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CompletionRowButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
}

private final class CompletionListView: NSView {
    static let rowHeight: CGFloat = 26
    override var isFlipped: Bool { true }
    var choose: ((Int) -> Void)?
    private var rows: [CompletionRowButton] = []
    init(candidates: [String], width: CGFloat, font: NSFont) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(candidates.count) * Self.rowHeight + 8))
        for (index, candidate) in candidates.enumerated() {
            let button = CompletionRowButton(frame: NSRect(x: 4, y: 4 + CGFloat(index) * Self.rowHeight, width: width - 8, height: Self.rowHeight))
            button.title = candidate.replacingOccurrences(of: "\n", with: " ↵ ").replacingOccurrences(of: "\t", with: " ⇥ ")
            button.font = font; button.alignment = .left; button.isBordered = false; button.focusRingType = .none
            button.cell?.lineBreakMode = .byTruncatingMiddle
            button.wantsLayer = true; button.layer?.cornerRadius = 5
            button.tag = index; button.target = self; button.action = #selector(chooseRow(_:))
            button.setAccessibilityLabel("补全历史命令：" + candidate)
            button.setAccessibilityHelp("点击仅填入输入区，不会执行。")
            addSubview(button); rows.append(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func chooseRow(_ sender: NSButton) { choose?(sender.tag) }
    func select(row: Int) {
        for (index, button) in rows.enumerated() {
            button.layer?.backgroundColor = (index == row ? NSColor.selectedContentBackgroundColor : .clear).cgColor
            button.contentTintColor = index == row ? .selectedTextColor : .labelColor
        }
        if rows.indices.contains(row) { rows[row].scrollToVisible(rows[row].bounds) }
    }
}
