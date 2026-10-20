#if DEBUG
import AppKit
import SwiftUI

@MainActor enum BlockInputSelfTests {
    static func run(check: (Bool, String) -> Void) async {
        let window = NativeTerminalTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let surface = NSView(frame: window.contentLayoutRect)
        let field = NSTextField(string: "other editable input")
        field.frame = NSRect(x: 0, y: 300, width: 250, height: 24)
        let owner = UUID(), request = UUID()
        var submissions = 0, cancellations = 0
        func editor(enabled: Bool, automatic: Bool = true, explicit: Bool = false) -> InlineCommandEditor {
            InlineCommandEditor(text: .constant("retained draft"), height: .constant(24),
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                color: .textColor, caret: .textColor, focusRequest: request,
                                enabled: enabled, automaticallyFocus: automatic,
                                explicitFocus: explicit, focusOwnerID: owner,
                                onSubmit: { submissions += 1 }, onHistory: { _ in }, onFocus: {}, onCancel: { cancellations += 1 })
        }
        let host = NSHostingView(rootView: editor(enabled: false))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
        surface.addSubview(host); surface.addSubview(field); window.contentView = surface
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await settle()
        check(!(window.firstResponder is CommandTextView), "Disabled block editor does not take focus")
        _ = window.makeFirstResponder(nil)
        host.rootView = editor(enabled: true)
        host.layoutSubtreeIfNeeded()
        await settle()
        check((window.firstResponder as? CommandTextView)?.string == "retained draft",
              "Block editor retries the same unconsumed focus request after becoming enabled")

        let disabledEditor = window.firstResponder as? CommandTextView
        host.rootView = editor(enabled: false)
        host.layoutSubtreeIfNeeded()
        await settle()
        check(!(window.firstResponder is CommandTextView), "Disabled old editor releases only its own first responder")
        let returnEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\r",
                                          charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        let cancelEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{03}",
                                          charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        disabledEditor?.keyDown(with: returnEvent)
        disabledEditor?.keyDown(with: cancelEvent)
        check(disabledEditor != nil && submissions == 0 && cancellations == 0 && disabledEditor?.string == "retained draft",
              "Disabled editor rejects Return submission and Ctrl-C draft cancellation")
        _ = window.makeFirstResponder(field)
        let otherResponder = window.firstResponder
        host.rootView = editor(enabled: true, automatic: false)
        host.layoutSubtreeIfNeeded()
        await settle()
        check(window.firstResponder === otherResponder, "Disabling automatic editor focus does not resign another text field")
        // A new mounted editor has a pending request, but must preserve another field.
        let waitingHost = NSHostingView(rootView: editor(enabled: true))
        waitingHost.frame = NSRect(x: 0, y: 100, width: 500, height: 100)
        surface.addSubview(waitingHost)
        waitingHost.layoutSubtreeIfNeeded()
        await settle()
        check(!(window.firstResponder is CommandTextView), "Completion focus preserves an existing editable field")
        waitingHost.rootView = editor(enabled: true, explicit: true)
        waitingHost.layoutSubtreeIfNeeded()
        await settle()
        check((window.firstResponder as? CommandTextView)?.string == "retained draft",
              "Explicit block click can transfer focus without replacing the draft")
        waitingHost.removeFromSuperview(); host.removeFromSuperview()

        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        outer.hasVerticalScroller = false
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let probe = TranscriptScrollObserver.ProbeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(probe); outer.documentView = document; surface.addSubview(outer)
        var samples: [(TranscriptScrollMetrics, Bool)] = []
        probe.changed = { samples.append(($0, $1)) }
        outer.contentView.scroll(to: NSPoint(x: 0, y: 720)); outer.reflectScrolledClipView(outer.contentView)
        probe.scheduleAttachment()
        await settle()
        check(samples.last?.0.isAtBottom == true, "Transcript observer measures the actual bottom")
        outer.contentView.scroll(to: NSPoint(x: 0, y: 600)); outer.reflectScrolledClipView(outer.contentView)
        await settle()
        check(samples.last?.1 == true && samples.last?.0.isAtBottom == false,
              "Transcript upward movement is distinguishable from content growth")
        document.setFrameSize(NSSize(width: 400, height: 960))
        await settle()
        check(samples.last?.1 == false && (samples.last?.0.distanceFromBottom ?? 0) > 0,
              "Growing transcript does not manufacture an upward user scroll")
        let nested = NSScrollView(frame: NSRect(x: 0, y: 600, width: 200, height: 100))
        nested.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        document.addSubview(nested)
        await settle()
        let previousCount = samples.count
        nested.contentView.scroll(to: NSPoint(x: 0, y: 200)); nested.reflectScrolledClipView(nested.contentView)
        await settle()
        check(samples.count == previousCount, "Nested output scrolling does not pause the outer transcript")
        outer.contentView.scroll(to: NSPoint(x: 0, y: 780)); outer.reflectScrolledClipView(outer.contentView)
        await settle()
        check(samples.last?.0.isAtBottom == true, "Returning to transcript bottom can resume live follow")
        probe.detach()
    }
    private static func settle() async {
        // Flush SwiftUI/AppKit mounting and the coalesced geometry notification.
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
}
#endif
