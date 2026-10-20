import AppKit
import SwiftUI

struct TranscriptScrollMetrics: Equatable {
    let top: CGFloat
    let distanceFromBottom: CGFloat
    let viewportSize: CGSize
    let contentHeight: CGFloat
    var isAtBottom: Bool { distanceFromBottom <= 2 }
}

/// Observe the transcript's own clip view. Scrolling a nested text viewport
/// does not change these bounds and cannot pause the outer transcript.
struct TranscriptScrollObserver: NSViewRepresentable {
    var changed: (TranscriptScrollMetrics, Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.changed = changed
        view.scheduleAttachment()
    }
    static func dismantleNSView(_ view: ProbeView, coordinator: ()) { view.detach() }

    final class ProbeView: NSView {
        var changed: ((TranscriptScrollMetrics, Bool) -> Void)?
        private weak var observedScroll: NSScrollView?
        private weak var observedDocument: NSView?
        private var observers: [NSObjectProtocol] = []
        private var lastMetrics: TranscriptScrollMetrics?
        private var pendingMetrics: TranscriptScrollMetrics?
        private var pendingUpwardMovement = false
        private var attachmentScheduled = false
        private var notificationScheduled = false
        private var previousBoundsNotifications = false
        private var previousFrameNotifications = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAttachment() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAttachment() }
        override func layout() {
            super.layout()
            attachIfNeeded()
            measure(boundsChanged: false)
        }

        func scheduleAttachment() {
            guard !attachmentScheduled else { return }
            attachmentScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.attachmentScheduled = false
                self.attachIfNeeded()
                self.measure(boundsChanged: false)
            }
        }
        private func attachIfNeeded() {
            let scroll = enclosingScrollView
            if scroll === observedScroll, scroll?.documentView === observedDocument { return }
            detach()
            guard let scroll, let document = scroll.documentView else { return }
            observedScroll = scroll; observedDocument = document
            previousBoundsNotifications = scroll.contentView.postsBoundsChangedNotifications
            previousFrameNotifications = document.postsFrameChangedNotifications
            scroll.contentView.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                    object: scroll.contentView, queue: .main) { [weak self] _ in
                self?.measure(boundsChanged: true)
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                    object: document, queue: .main) { [weak self] _ in
                self?.measure(boundsChanged: false)
            })
        }
        private func measure(boundsChanged: Bool) {
            guard let scroll = observedScroll, let document = observedDocument else { return }
            let visible = document.convert(scroll.contentView.bounds, from: scroll.contentView)
            let top = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
            let bottom = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
            let metrics = TranscriptScrollMetrics(top: max(0, top), distanceFromBottom: max(0, bottom),
                                                   viewportSize: scroll.contentView.bounds.size,
                                                   contentHeight: document.bounds.height)
            let movedUp = boundsChanged && lastMetrics.map {
                abs($0.viewportSize.height - metrics.viewportSize.height) < 0.5 &&
                abs($0.viewportSize.width - metrics.viewportSize.width) < 0.5 &&
                abs($0.contentHeight - metrics.contentHeight) < 0.5 && metrics.top < $0.top - 0.5
            } == true
            guard metrics != lastMetrics || movedUp else { return }
            lastMetrics = metrics; pendingMetrics = metrics
            pendingUpwardMovement = pendingUpwardMovement || movedUp
            guard !notificationScheduled else { return }
            notificationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.notificationScheduled = false
                guard self.window != nil, self.observedScroll != nil, let metrics = self.pendingMetrics else { return }
                let movedUp = self.pendingUpwardMovement
                self.pendingMetrics = nil; self.pendingUpwardMovement = false
                self.changed?(metrics, movedUp)
            }
        }
        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            observedScroll?.contentView.postsBoundsChangedNotifications = previousBoundsNotifications
            observedDocument?.postsFrameChangedNotifications = previousFrameNotifications
            observedScroll = nil; observedDocument = nil
            lastMetrics = nil; pendingMetrics = nil; pendingUpwardMovement = false
        }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    }
}
