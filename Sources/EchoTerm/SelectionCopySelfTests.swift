#if DEBUG
import AppKit
import Foundation
import SwiftUI

@MainActor enum SelectionCopySelfTests {
    static func run(check: (Bool, String) -> Void) async {
        let suite = "EchoTerm.CopySelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        check(!preferences.copyOnSelection, "Copy-on-selection is off for a fresh preferences suite")
        preferences.copyOnSelection = true
        check(Preferences(defaults: defaults).copyOnSelection, "Copy-on-selection persists its enabled setting")
        preferences.copyOnSelection = false
        check(!Preferences(defaults: defaults).copyOnSelection, "Copy-on-selection persists its disabled setting")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("existing clipboard", forType: .string)
        check(!SelectionClipboard.copy("replacement", enabled: false, to: pasteboard)
              && pasteboard.string(forType: .string) == "existing clipboard", "Disabled selection copying leaves the clipboard unchanged")
        check(!SelectionClipboard.copy("", enabled: true, to: pasteboard)
              && !SelectionClipboard.copy(nil, enabled: true, to: pasteboard)
              && pasteboard.string(forType: .string) == "existing clipboard", "Empty or absent selections do not erase the clipboard")
        let sample = "  中文🙂\nsecond line  "
        check(SelectionClipboard.copy(sample, enabled: true, to: pasteboard)
              && pasteboard.string(forType: .string) == sample, "Selected Unicode, whitespace and newlines are copied without trimming")

        let view = CopySelectableTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: nil)
        let textWindow = NativeTerminalTestWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        textWindow.isReleasedWhenClosed = false; textWindow.animationBehavior = .none
        textWindow.contentView = view
        defer { textWindow.contentView = nil; textWindow.close() }
        view.selectionPasteboard = pasteboard
        view.string = sample
        check(view.textStorage != nil && view.string == sample,
              "A short selectable transcript view owns a complete text system and retains its displayed text")
        view.layoutSubtreeIfNeeded()
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        textWindow.makeFirstResponder(view)
        func diagnose(_ phase: String) {
            let ranges = view.selectedRanges.map { "\($0.rangeValue.location):\($0.rangeValue.length)" }.joined(separator: ",")
            let clipboardLength = ((pasteboard.string(forType: .string) ?? "") as NSString).length
            print("SELECTION-FIXTURE \(phase): utf16=\((view.string as NSString).length) ranges=\(ranges) enabled=\(view.copyOnSelection) editable=\(view.isEditable) selectable=\(view.isSelectable) updating=\(view.updatingContent) firstResponder=\(textWindow.firstResponder === view) clipboardUTF16=\(clipboardLength)")
        }
        pasteboard.setString("unchanged", forType: .string)
        view.selectAll(nil)
        diagnose("disabled selectAll")
        check(pasteboard.string(forType: .string) == "unchanged", "A selectable read-only view respects its disabled copy setting")
        view.copyOnSelection = true
        view.selectAll(nil)
        diagnose("enabled unchanged selectAll")
        check(pasteboard.string(forType: .string) == sample, "A read-only select-all action copies through the scoped selection component")
        pasteboard.setString("programmatic selection", forType: .string)
        view.setSelectedRange(NSRange(location: 0, length: 2))
        check(pasteboard.string(forType: .string) == "programmatic selection", "Programmatic range changes do not trigger automatic copying")
        view.updatingContent = true
        view.string = "streaming update"
        view.selectAll(nil)
        view.updatingContent = false
        check(pasteboard.string(forType: .string) == "programmatic selection", "Content replacement and layout updates cannot copy a selection")
        view.isEditable = true
        view.selectAll(nil)
        check(pasteboard.string(forType: .string) == "programmatic selection", "Editable text never participates even if a copy-enabled view is misconfigured")
        view.isEditable = false; view.string = ""
        view.selectAll(nil)
        check(pasteboard.string(forType: .string) == "programmatic selection", "Clearing a read-only document leaves the clipboard intact")
        plainClickTracking(view: view, window: textWindow, check: check)

        longOutputFollowing(check: check)
        await pendingLongOutputScroll(check: check)
        await hostedLongOutputScroll(check: check)
        await nativeSelection(check: check, pasteboard: pasteboard)
    }
    private final class LiveTextFixture: ObservableObject {
        @Published var text = (0..<150).map { "hosted-stream-\($0)" }.joined(separator: "\n")
    }
    private struct LiveTextFixtureView: View {
        @ObservedObject var fixture: LiveTextFixture
        var body: some View {
            LongTextView(text: fixture.text, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                         color: .textColor, followOutput: true).frame(width: 400, height: 200)
        }
    }
    private static func hostedLongOutputScroll(check: (Bool, String) -> Void) async {
        let fixture = LiveTextFixture()
        let host = NSHostingView(rootView: LiveTextFixtureView(fixture: fixture))
        let window = NativeTerminalTestWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func output(_ view: NSView) -> OutputTextScrollView? {
            if let scroll = view as? OutputTextScrollView { return scroll }
            return view.subviews.lazy.compactMap(output).first
        }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<50 {
            if let scroll = output(host), let document = scroll.documentView,
               document.frame.height > 400, document.bounds.maxY - scroll.contentView.documentVisibleRect.maxY <= 8 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let scroll = output(host), let document = scroll.documentView else {
            check(false, "The hosted streaming LongText fixture mounts its actual NSViewRepresentable")
            return
        }
        let originalID = ObjectIdentifier(scroll)
        let before = scroll.contentView.bounds.origin.y
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(1, before / 2)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let pausedY = scroll.contentView.bounds.origin.y
        for index in 150..<155 {
            fixture.text += "\nhosted-stream-\(index)"
            try? await Task.sleep(nanoseconds: 80_000_000)
            host.layoutSubtreeIfNeeded()
        }
        print("HOSTED-LONG before=\(before) paused=\(pausedY) after=\(scroll.contentView.bounds.origin.y) height=\(document.frame.height) sameView=\(output(host).map(ObjectIdentifier.init) == originalID)")
        check(before > 100 && pausedY < before - 10 && abs(scroll.contentView.bounds.origin.y - pausedY) < 1,
              "A hosted LongTextView preserves a real upward clip scroll across repeated SwiftUI streaming updates")
        check(output(host).map(ObjectIdentifier.init) == originalID,
              "Streaming updates preserve the mounted LongText NSView identity")
        let textView = document as! NSTextView
        textView.setSelectedRange(NSRange(location: 3, length: 5))
        fixture.text += "\nshared-pair-😀"
        try? await Task.sleep(nanoseconds: 60_000_000)
        fixture.text = fixture.text.replacingOccurrences(of: "shared-pair-😀", with: "shared-pair-😁")
        try? await Task.sleep(nanoseconds: 60_000_000)
        check(textView.string == fixture.text && !textView.string.contains("�") && textView.selectedRange() == NSRange(location: 3, length: 5),
              "A streaming rewrite across a shared UTF-16 high surrogate preserves exact Unicode and an untouched prefix selection")
        check(abs(scroll.contentView.bounds.origin.y - pausedY) < 1,
              "Rewriting the streaming tail leaves the paused reading position intact")
        func visibleLine() -> String {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return "" }
            let rect = scroll.contentView.documentVisibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
            guard glyphs.length > 0 else { return "" }
            let index = layout.characterIndexForGlyph(at: glyphs.location), source = textView.string as NSString
            guard index < source.length else { return "" }
            return source.substring(with: source.lineRange(for: NSRange(location: index, length: 0)))
        }
        let beforeTrim = visibleLine()
        fixture.text = fixture.text.components(separatedBy: "\n").dropFirst(10).joined(separator: "\n") + "\nrolling-window-终🙂"
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(textView.string == fixture.text && !beforeTrim.isEmpty && visibleLine() == beforeTrim,
              "A rolling-log prefix trim preserves an available visible line while replacing the backing text accurately")
        let selection = textView.selectedRange(), length = (textView.string as NSString).length
        check(selection.location != NSNotFound && selection.location <= length && selection.length <= length - selection.location,
              "TextKit keeps selection ranges valid after a streaming prefix truncation")
        fixture.text += (0..<160).map { "\nunlaid-stream-\($0)" }.joined()
        try? await Task.sleep(nanoseconds: 80_000_000)
        var bottomRequests = 0
        let resume = scroll.onUserRequestedBottom
        scroll.onUserRequestedBottom = { bottomRequests += 1; resume?() }
        scroll.verticalScroller?.setAccessibilityValue(NSNumber(value: 1))
        for index in 0..<5 {
            fixture.text += "\naccessibility-resume-\(index)"
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        check(bottomRequests == 1 && document.bounds.maxY - scroll.contentView.documentVisibleRect.maxY <= 8 && (scroll.verticalScroller?.doubleValue ?? 0) > 0.99,
              "An actual NSScroller accessibility bottom request resumes following across subsequent streamed updates")
        scroll.verticalScroller?.setAccessibilityValue(NSNumber(value: 0.5))
        let axPausedY = scroll.contentView.bounds.origin.y
        for index in 0..<3 {
            fixture.text += "\naccessibility-paused-\(index)"
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        check(bottomRequests == 1 && abs(scroll.contentView.bounds.origin.y - axPausedY) < 1,
              "An actual NSScroller accessibility upward adjustment pauses again without being misclassified as a bottom request")
        scroll.verticalScroller?.setAccessibilityValue(NSNumber(value: 1))
        fixture.text += "\naccessibility-second-resume"
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(bottomRequests == 2 && document.bounds.maxY - scroll.contentView.documentVisibleRect.maxY <= 8,
              "Repeated accessibility pause/resume cycles rearm following exactly once per explicit bottom request")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        fixture.text += "\nhosted-stream-final"
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(document.bounds.maxY - scroll.contentView.documentVisibleRect.maxY <= 8,
              "Returning a hosted streaming LongTextView to bottom resumes following through its production update path")
        func scrollToCharacter(_ index: Int) {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: index)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: line.minY + textView.textContainerOrigin.y + 0.5))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func visiblePair() -> String {
            guard let layout = textView.layoutManager, let container = textView.textContainer else { return "" }
            let rect = scroll.contentView.documentVisibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
            let glyphs = layout.glyphRange(forBoundingRect: rect, in: container)
            guard glyphs.length > 0 else { return "" }
            let source = textView.string as NSString, index = layout.characterIndexForGlyph(at: glyphs.location)
            guard index < source.length else { return "" }
            let first = source.lineRange(for: NSRange(location: index, length: 0))
            let end = NSMaxRange(first) < source.length ? NSMaxRange(source.lineRange(for: NSRange(location: NSMaxRange(first), length: 0))) : NSMaxRange(first)
            return source.substring(with: NSRange(location: first.location, length: end - first.location))
        }
        fixture.text = (0..<100).flatMap { ["repeat-line", "context-\($0)"] }.joined(separator: "\n")
        try? await Task.sleep(nanoseconds: 80_000_000)
        scrollToCharacter((fixture.text as NSString).range(of: "repeat-line\ncontext-40").location)
        let repeatedPair = visiblePair()
        fixture.text = "rewritten-prefix\n" + fixture.text
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(repeatedPair.hasPrefix("repeat-line\ncontext-40") && visiblePair() == repeatedPair && scroll.contentView.bounds.origin.y > 200,
              "A rewrite preserves a repeated visible log line with its neighboring context instead of jumping to the first identical line")
        fixture.text = Array(repeating: "identical-line", count: 200).joined(separator: "\n")
        try? await Task.sleep(nanoseconds: 80_000_000)
        let sameLineIndex = (Array(repeating: "identical-line", count: 80).joined(separator: "\n") as NSString).length + 1
        scrollToCharacter(sameLineIndex)
        let repeatedTop = scroll.contentView.bounds.origin.y
        fixture.text = "new-prefix\n" + fixture.text
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(repeatedTop > 200 && abs(scroll.contentView.bounds.origin.y - repeatedTop) < 30,
              "When every bounded log context is identical, restoration chooses a nearby occurrence instead of the document's first match")
    }
    private static func plainClickTracking(view: CopySelectableTextView, window: NSWindow, check: (Bool, String) -> Void) {
        view.string = "readonly click fixture"; view.copyOnSelection = false
        view.setSelectedRange(NSRange(location: 0, length: 0))
        var clicks = 0
        view.onClick = { clicks += 1 }
        defer { view.onClick = nil }
        func event(_ type: NSEvent.EventType, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 12, y: 12), modifierFlags: modifiers,
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                              context: nil, eventNumber: 1, clickCount: count, pressure: 1)!
        }
        let down = event(.leftMouseDown)
        view.performMouseSelection(down) {}
        check(clicks == 1, "A window-local plain text click focuses current input without comparing the global pointer position")
        view.performMouseSelection(down) { view.observeSelectionDrag(event(.leftMouseDragged)) }
        check(clicks == 1, "An observed left-drag event suppresses text-click focus even if the final selected range is empty")
        view.performMouseSelection(event(.leftMouseDown, count: 2)) {}
        view.performMouseSelection(event(.leftMouseDown, count: 3)) {}
        view.performMouseSelection(event(.leftMouseDown, modifiers: .shift)) {}
        check(clicks == 1, "Double, triple and extended-selection clicks retain text selection instead of transferring focus")
        view.performMouseSelection(down) { view.setSelectedRange(NSRange(location: 0, length: 8)) }
        check(clicks == 1, "A nonempty read-only selection does not transfer focus to the latest command")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.performMouseSelection(down) { _ = view.textView(view, clickedOnLink: "unsupported:fixture", at: 0) }
        check(clicks == 1, "Link activation retains link behavior without transferring text-click focus")
        view.observeSelectionDrag(event(.leftMouseDragged))
        view.performMouseSelection(down) {}
        check(clicks == 2, "Drag observation is confined to its active selection gesture and cannot suppress a later plain click")
    }
    private static func longOutputFollowing(check: (Bool, String) -> Void) {
        let scroll = OutputTextScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
        let coordinator = LongTextView.Coordinator()
        coordinator.attach(scroll); coordinator.followEnabled = true
        coordinator.pendingFollow = true
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        check(coordinator.userScrollActive && !coordinator.pendingFollow,
              "A scrollbar tracking gesture cancels a queued output follow before it can pull the reader downward")
        scroll.contentView.scroll(to: .zero)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        check(!coordinator.followsBottom, "Live scrolling above a long document's bottom pauses following")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1_000 - scroll.contentView.bounds.height))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        check(!coordinator.userScrollActive && coordinator.followsBottom,
              "Finishing a user scroll at the actual bottom resumes long-output following")
        coordinator.pendingFollow = true; coordinator.setSelectionTracking(true)
        check(coordinator.userScrollActive && !coordinator.pendingFollow,
              "Read-only mouse selection cancels queued following while TextKit may auto-scroll")
        coordinator.setSelectionTracking(false)
        check(!coordinator.userScrollActive && coordinator.followsBottom,
              "Ending a selection keeps following available when the viewport remains at bottom")
    }
    private static func pendingLongOutputScroll(check: (Bool, String) -> Void) async {
        let scroll = OutputTextScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.hasVerticalScroller = true
        let view = CopySelectableTextView(frame: scroll.bounds, textContainer: nil)
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.minSize = .zero; view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        let window = NativeTerminalTestWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        view.string = (0..<150).map { "stream-line-\($0)" }.joined(separator: "\n")
        view.sizeToFit(); scroll.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let coordinator = LongTextView.Coordinator()
        coordinator.attach(scroll); coordinator.followEnabled = true
        coordinator.pendingFollow = true; coordinator.followIfNeeded()
        let upper = NSPoint(x: 0, y: max(1, scroll.contentView.bounds.origin.y / 2))
        scroll.contentView.scroll(to: upper)
        scroll.reflectScrolledClipView(scroll.contentView)
        let pausedY = scroll.contentView.bounds.origin.y
        check(!coordinator.pendingFollow && !coordinator.followsBottom,
              "A real TextKit clip scroll cancels pending follow without live-scroll notifications, including AX-style viewport adjustments")
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(abs(scroll.contentView.bounds.origin.y - pausedY) < 1 && !coordinator.followsBottom,
              "An already queued output follow cannot pull a manually adjusted long-output viewport back to bottom")
        coordinator.programmatic = true
        view.string += "\nstream-line-150\nstream-line-151"
        view.sizeToFit()
        coordinator.programmatic = false; coordinator.refreshGeometry()
        check(!coordinator.followsBottom && abs(scroll.contentView.bounds.origin.y - pausedY) < 1,
              "Programmatic text growth preserves a paused long-output reader instead of rearming following")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.height - scroll.contentView.bounds.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        check(coordinator.followsBottom, "A real clip scroll back to the long-output bottom rearms following")
        coordinator.pendingFollow = true; coordinator.followIfNeeded()
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(coordinator.followsBottom && !coordinator.pendingFollow,
              "A resumed programmatic output follow does not classify its own clip movement as a user pause")
        func appendWhileTracking(_ suffix: String) {
            coordinator.programmatic = true
            view.textStorage?.append(NSAttributedString(string: suffix, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
            view.sizeToFit()
            coordinator.programmatic = false; coordinator.refreshGeometry()
        }
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.verticalScroller?.setAccessibilityValue(NSNumber(value: 1))
        appendWhileTracking((0..<20).map { "\nlive-extent-\($0)" }.joined())
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try? await Task.sleep(nanoseconds: 40_000_000)
        check(coordinator.followsBottom && !coordinator.pendingFollow && view.bounds.maxY - scroll.contentView.documentVisibleRect.maxY <= 8,
              "An explicit live-tracking bottom request survives streamed extent growth and follows the actual tail when tracking ends")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.verticalScroller?.setAccessibilityValue(NSNumber(value: 1))
        scroll.verticalScroller?.setAccessibilityValue(NSNumber(value: 0.5))
        let cancelledTop = scroll.contentView.bounds.origin.y
        appendWhileTracking((0..<20).map { "\nlive-cancel-\($0)" }.joined())
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try? await Task.sleep(nanoseconds: 40_000_000)
        check(!coordinator.followsBottom && !coordinator.pendingFollow && abs(scroll.contentView.bounds.origin.y - cancelledTop) < 1,
              "A subsequent upward user action cancels live bottom intent and remains paused through growth and tracking end")
    }
    private static func nativeSelection(check: (Bool, String) -> Void, pasteboard: NSPasteboard) async {
        let terminal = BlockTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let window = NativeTerminalTestWindow(contentRect: terminal.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = terminal
        defer { window.contentView = nil; window.close() }
        terminal.resize(cols: 60, rows: 8)
        terminal.selectionPasteboard = pasteboard
        terminal.nativeInputAllowed = true; terminal.keyboardFocusAllowed = true
        var nativeInputCount = 0
        terminal.onNativeInput = { nativeInputCount += 1 }
        let sample = "中文🙂 alpha\r\nsecond line"
        terminal.dataReceived(slice: Array(sample.utf8)[...])
        window.makeFirstResponder(terminal)
        pasteboard.setString("native unchanged", forType: .string)
        terminal.selectAll()
        check(pasteboard.string(forType: .string) == "native unchanged", "Programmatic terminal selection does not auto-copy")

        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let menu = NSMenu(title: "Selection fixture"), commands = NSMenu(title: "Selection commands")
        menu.autoenablesItems = false; commands.autoenablesItems = false
        let container = NSMenuItem(title: "Selection", action: nil, keyEquivalent: "")
        let select = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        select.target = terminal; select.keyEquivalentModifierMask = .command; select.isEnabled = true
        commands.addItem(select); container.submenu = commands; menu.addItem(container); NSApp.mainMenu = menu
        terminal.selectNone()
        _ = NativeTerminalTestDriver.key("a", code: 0, modifiers: .command, into: terminal)
        check(pasteboard.string(forType: .string) == "native unchanged", "Terminal menu selection respects the disabled setting")
        terminal.copyOnSelection = true; terminal.selectNone()
        _ = NativeTerminalTestDriver.key("a", code: 0, modifiers: .command, into: terminal)
        let selected = terminal.getSelection()
        check(selected?.contains("中文🙂 alpha") == true && pasteboard.string(forType: .string) == selected,
              "Native menu selection copies exact selected Unicode through an isolated pasteboard")
        pasteboard.setString("same native range", forType: .string)
        _ = NativeTerminalTestDriver.key("a", code: 0, modifiers: .command, into: terminal)
        check(pasteboard.string(forType: .string) == selected,
              "Repeating native Select All copies even when the full terminal range is unchanged")

        pasteboard.setString("pointer selection", forType: .string)
        terminal.selectNone()
        NativeTerminalTestDriver.click(terminal, clickCount: 3)
        for _ in 0..<20 where pasteboard.string(forType: .string) == "pointer selection" {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let pointerSelection = terminal.getSelection()
        check(pointerSelection?.contains("中文🙂 alpha") == true && pasteboard.string(forType: .string) == pointerSelection,
              "A real native multi-click selection copies after mouse-up finalizes the range")
        pasteboard.setString("output update", forType: .string)
        terminal.selectNone()
        terminal.dataReceived(slice: Array("\r\nnew output".utf8)[...])
        await Task.yield()
        check(pasteboard.string(forType: .string) == "output update" && nativeInputCount == 0,
              "Terminal redraws, selection clearing and copying do not overwrite clipboard or count as stdin input")
    }
}
#endif
