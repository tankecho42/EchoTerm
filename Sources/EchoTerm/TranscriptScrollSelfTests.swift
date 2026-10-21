#if DEBUG
import AppKit
import SwiftUI

/// A real SwiftUI lazy transcript, rather than a fixed NSView document. The
/// window is ordered behind other windows without activation. These checks
/// exercise layout and clip geometry, not OS focus or physical wheel delivery.
@MainActor enum TranscriptScrollSelfTests {
    static func runPolicy(check: (Bool, String) -> Void) {
        let away = TranscriptScrollMetrics(top: 100, distanceFromBottom: 200,
                                           viewportSize: NSSize(width: 500, height: 300), contentHeight: 600)
        let bottom = TranscriptScrollMetrics(top: 300, distanceFromBottom: 0,
                                             viewportSize: away.viewportSize, contentHeight: away.contentHeight)
        var policy = TranscriptFollowPolicy()
        check(policy.followsBottom && !policy.takeGeometryCorrection(away),
              "Transcript geometry cannot begin following without an explicit content or focus request")
        let armed = policy.requestFollow()
        let first = policy.takeGeometryCorrection(away), second = policy.takeGeometryCorrection(away)
        check(armed && first && second && !policy.takeGeometryCorrection(away),
              "An explicit follow request has a finite two-correction budget")
        policy.observe(away, movedUp: false); policy.observe(bottom, movedUp: false)
        check(!policy.takeGeometryCorrection(away),
              "Further geometry, including measured bottom, never replenishes exhausted corrections")
        check(policy.requestFollow() && policy.takeGeometryCorrection(away),
              "A later explicit content request can rearm bounded lazy-layout corrections")
        policy.pauseForUserScroll()
        check(!policy.followsBottom && !policy.requestFollow() && !policy.takeGeometryCorrection(away),
              "User scroll intent immediately clears corrections and blocks content following")
        policy.observe(away, movedUp: false)
        check(!policy.followsBottom, "Changing off-bottom geometry cannot erase the user's paused reading state")
        policy.observe(bottom, movedUp: false)
        check(policy.followsBottom && !policy.takeGeometryCorrection(away)
              && policy.requestFollow() && policy.takeGeometryCorrection(away),
              "Returning to bottom permits the next content request without geometry arming corrections itself")
        policy.observe(away, movedUp: true)
        policy.resume()
        check(policy.followsBottom && !policy.takeGeometryCorrection(away) && policy.requestFollow(),
              "An explicit input-focus resume still waits for a requested follow to arm corrections")
    }

    static func run(check: (Bool, String) -> Void) async throws {
        let fixture = Fixture()
        let host = NSHostingView(rootView: Transcript(fixture: fixture))
        let window = NativeTerminalTestWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        await settle(host)
        for _ in 0..<80 {
            if findProbe(host)?.enclosingScrollView != nil, fixture.metrics != nil { break }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let probe = findProbe(host), let scroll = probe.enclosingScrollView,
              let document = scroll.documentView else {
            print("TRANSCRIPT-MOUNT visible=\(window.isVisible) host=\(host.frame.size) subviews=\(host.subviews.count) callbacks=\(fixture.geometryCallbacks)")
            check(false, "The mixed lazy transcript mounts its production clip-geometry observer")
            return
        }
        check(document.bounds.height > scroll.contentView.bounds.height * 3,
              "The transcript fixture contains multiple viewports of mixed short and tall lazy rows")
        fixture.requestBottom()
        await settle(host)
        check(fixture.metrics?.isAtBottom == true && fixture.bottomRequests > 0,
              "An explicit transcript focus request reaches the actual lazy document bottom")

        // Input intent arrives before AppKit moves the clip. In a lazy stack,
        // the same move can discover a different document height, so a stable
        // extent comparison alone cannot reliably identify the user gesture.
        if let point = wheelPoint(in: scroll, root: host, requireOwner: scroll) {
            let before = fixture.upwardIntents
            probe.observeUserWheel(wheel(window: window, point: point, delta: -120))
            check(fixture.upwardIntents == before && fixture.policy.followsBottom,
                  "A downward wheel event over the real outer transcript does not pause following")
            if let nested = visibleNestedScroll(in: host, outer: scroll),
               let nestedPoint = wheelPoint(in: nested, root: host, requireOwner: nested) {
                probe.observeUserWheel(wheel(window: window, point: nestedPoint, delta: 120))
                check(fixture.upwardIntents == before && fixture.policy.followsBottom,
                      "An upward wheel over a real nested output viewport does not pause the outer transcript")
            } else { check(false, "The mixed lazy transcript exposes a hit-testable nested output viewport") }
            probe.observeUserWheel(wheel(window: window, point: point, delta: 120))
            check(fixture.upwardIntents == before + 1 && !fixture.policy.followsBottom,
                  "The production wheel monitor path pauses from upward intent before clip or lazy extent changes")
        } else { check(false, "The mounted outer transcript exposes a wheel hit target") }
        scrollToFraction(0.45, scroll: scroll)
        await settle(host)
        let pausedRequests = fixture.bottomRequests
        let pausedCorrections = fixture.geometryCorrections
        let pausedTop = fixture.metrics?.top ?? -1
        fixture.expanded = true
        fixture.outputRevision += 1
        await settle(host)
        check(pausedTop > 10 && fixture.metrics?.isAtBottom == false && !fixture.policy.followsBottom,
              "A native clip move remains paused while lazy row materialization changes document extent")
        check(fixture.bottomRequests == pausedRequests && fixture.geometryCorrections == pausedCorrections,
              "Real lazy transcript geometry and output changes cannot recursively request bottom while paused")

        // Changing viewport width remeasures actual AppKit text rows as well
        // as the lazy stack; no new output/focus request was made.
        window.setContentSize(NSSize(width: 410, height: 360))
        await settle(host)
        check(fixture.metrics?.isAtBottom == false && fixture.bottomRequests == pausedRequests,
              "Remeasuring a paused mixed transcript at a narrower width does not pull it to the tail")
        let callbacksAtRest = fixture.geometryCallbacks
        let requestsAtRest = fixture.bottomRequests, correctionsAtRest = fixture.geometryCorrections
        await settle(host)
        check(fixture.geometryCallbacks - callbacksAtRest <= 2 && fixture.bottomRequests == requestsAtRest
              && fixture.geometryCorrections == correctionsAtRest,
              "Mixed lazy row geometry converges after layout instead of creating continuing scroll work")

        scrollToFraction(1, scroll: scroll)
        await settle(host)
        // scrollTo may expose a newly estimated tail. Repeat an explicit user
        // bottom action, boundedly, rather than let geometry correct itself.
        for _ in 0..<4 where fixture.metrics?.isAtBottom != true {
            scrollToFraction(1, scroll: scroll)
            await settle(host)
        }
        check(fixture.metrics?.isAtBottom == true && fixture.policy.followsBottom,
              "A real return to the transcript bottom rearms following")
        let beforeOutput = fixture.bottomRequests
        fixture.appendedRows += 1; fixture.outputRevision += 1
        await settle(host)
        check(fixture.bottomRequests == beforeOutput + 1,
              "One new output revision produces one follow request rather than a geometry-driven retry chain")
        let finalCallbacks = fixture.geometryCallbacks, finalRequests = fixture.bottomRequests
        let finalCorrections = fixture.geometryCorrections
        await settle(host)
        check(fixture.geometryCallbacks - finalCallbacks <= 2 && fixture.bottomRequests == finalRequests
              && fixture.geometryCorrections == finalCorrections,
              "Following mixed lazy output returns to idle without recurring bottom requests")
        check(fixture.correctionsByRequest.values.allSatisfy { $0 <= 2 },
              "Every real lazy-layout follow revision obeys the two-correction bound")
        print("TRANSCRIPT-LAYOUT callbacks=\(fixture.geometryCallbacks) bottomRequests=\(fixture.bottomRequests) corrections=\(fixture.geometryCorrections) height=\(Int(document.bounds.height)) top=\(Int(fixture.metrics?.top ?? -1))")
        await liveScrollExtentChange(check: check)

        // This opt-in diagnostic executes the old production feedback path,
        // but stops after 12 requests so it cannot create an unbounded hang.
        if ProcessInfo.processInfo.environment["ECHOTERM_SCROLL_TRANSCRIPT_LEGACY"] == "1" {
            fixture.policy.resume(); fixture.legacyGeometryCorrection = true
            fixture.expanded.toggle()
            scrollToFraction(0.7, scroll: scroll)
            await settle(host)
            print("TRANSCRIPT-LEGACY corrections=\(fixture.legacyCorrections) capped=\(fixture.legacyCorrections >= 12)")
        }
    }

    private final class Fixture: ObservableObject {
        @Published var expanded = false
        @Published var appendedRows = 0
        @Published var outputRevision = 0
        @Published var focusRevision = 0
        var policy = TranscriptFollowPolicy()
        var metrics: TranscriptScrollMetrics?
        var geometryCallbacks = 0
        var upwardIntents = 0
        var bottomRequests = 0
        var geometryCorrections = 0
        var correctionsByRequest: [Int: Int] = [:]
        var legacyGeometryCorrection = false
        var legacyCorrections = 0
        func requestBottom() { policy.resume(); focusRevision += 1 }
    }

    private struct Transcript: View {
        @ObservedObject var fixture: Fixture
        var body: some View {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<(60 + fixture.appendedRows), id: \.self) { index in
                                row(index).id(index)
                            }
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .background(TranscriptScrollObserver(userScrolledUp: {
                        fixture.upwardIntents += 1; fixture.policy.pauseForUserScroll()
                    }) { metrics, movedUp in
                        fixture.geometryCallbacks += 1; fixture.metrics = metrics
                        fixture.policy.observe(metrics, movedUp: movedUp)
                        if fixture.legacyGeometryCorrection && fixture.policy.followsBottom && !metrics.isAtBottom,
                           fixture.legacyCorrections < 12 {
                            fixture.legacyCorrections += 1
                            reader.scrollTo("tail", anchor: .bottom)
                        } else if !fixture.legacyGeometryCorrection && fixture.policy.takeGeometryCorrection(metrics) {
                            fixture.geometryCorrections += 1
                            fixture.correctionsByRequest[fixture.bottomRequests, default: 0] += 1
                            reader.scrollTo("tail", anchor: .bottom)
                        }
                    })
                }
                .onChange(of: fixture.focusRevision) { _, _ in follow(reader) }
                .onChange(of: fixture.outputRevision) { _, _ in
                    if fixture.policy.followsBottom { follow(reader) }
                }
            }
        }
        @ViewBuilder private func row(_ index: Int) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Fixture Block \(index)").font(.system(size: 10, design: .monospaced))
                if index % 9 == 0 || index == 59 {
                    LongTextView(text: (0..<70).map { "row \(index)-\($0) 中文🙂" }.joined(separator: "\n"),
                                 font: .monospacedSystemFont(ofSize: 12, weight: .regular), color: .textColor)
                        .frame(height: fixture.expanded ? 300 : 180)
                } else {
                    SelectableText(text: String(repeating: "lazy row \(index) 中文🙂 wrapped text ", count: index % 5 == 0 ? 12 : 1),
                                   font: .systemFont(ofSize: 12), color: .textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
        }
        private func follow(_ reader: ScrollViewProxy) {
            guard fixture.policy.requestFollow() else { return }
            fixture.bottomRequests += 1
            reader.scrollTo("tail", anchor: .bottom)
        }
    }

    private static func findProbe(_ view: NSView) -> TranscriptScrollObserver.ProbeView? {
        if let probe = view as? TranscriptScrollObserver.ProbeView { return probe }
        return view.subviews.lazy.compactMap(findProbe).first
    }
    private static func visibleNestedScroll(in view: NSView, outer: NSScrollView) -> NSScrollView? {
        if let nested = view as? OutputTextScrollView,
           outer.contentView.bounds.intersection(outer.contentView.convert(nested.bounds, from: nested)).height > 30 { return nested }
        return view.subviews.lazy.compactMap { visibleNestedScroll(in: $0, outer: outer) }.first
    }
    private static func wheelPoint(in scroll: NSScrollView, root: NSView, requireOwner owner: NSScrollView) -> NSPoint? {
        let clip = scroll.contentView, bounds = clip.bounds
        for x in [bounds.minX + 3, bounds.midX, bounds.maxX - 3] {
            for y in [bounds.midY, bounds.minY + 8, bounds.maxY - 8] {
                let point = clip.convert(NSPoint(x: x, y: y), to: nil)
                let hit = root.hitTest(root.convert(point, from: nil))
                if hit?.enclosingScrollView === owner { return point }
            }
        }
        return nil
    }
    /// NSEvent has no public wheel factory with window/location arguments.
    /// Preserve a real CGEvent-backed wheel's type and delta, while supplying
    /// fixture-owned routing metadata. The production handler and NSView hit
    /// testing are real; this does not claim OS or physical event delivery.
    private static func wheel(window: NSWindow, point: NSPoint, delta: Int32) -> NSEvent {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
        return ScopedWheelEvent(native: NSEvent(cgEvent: cg)!, window: window, point: point)
    }
    private final class ScopedWheelEvent: NSEvent {
        private let native: NSEvent
        private weak var fixtureWindow: NSWindow?
        private let point: NSPoint
        init(native: NSEvent, window: NSWindow, point: NSPoint) {
            self.native = native; fixtureWindow = window; self.point = point
            super.init()
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var type: NSEvent.EventType { native.type }
        override var scrollingDeltaY: CGFloat { native.scrollingDeltaY }
        override var window: NSWindow? { fixtureWindow }
        override var locationInWindow: NSPoint { point }
    }
    private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
    private static func liveScrollExtentChange(check: (Bool, String) -> Void) async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        let probe = TranscriptScrollObserver.ProbeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(probe); scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderBack(nil)
        defer { probe.detach(); window.orderOut(nil); window.contentView = nil; window.close() }
        var samples: [(TranscriptScrollMetrics, Bool)] = []
        probe.changed = { samples.append(($0, $1)) }
        probe.scheduleAttachment()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 600)); scroll.reflectScrolledClipView(scroll.contentView)
        await settle(scroll)
        func growAndMoveUp(height: CGFloat, y: CGFloat) {
            // Lazy host frame and clip notifications may arrive together. Hold
            // the frame notification so this bounds notification sees both
            // changes, using actual NSView geometry rather than fake metrics.
            document.postsFrameChangedNotifications = false
            document.setFrameSize(NSSize(width: 400, height: height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            document.postsFrameChangedNotifications = true
        }
        growAndMoveUp(height: 960, y: 500)
        await settle(scroll)
        check(samples.last?.1 == false,
              "A combined document-extent and clip change alone does not manufacture user scroll intent")
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        growAndMoveUp(height: 1020, y: 400)
        await settle(scroll)
        check(samples.last?.1 == true,
              "Actual upward clip motion during a scoped live gesture pauses even when lazy document height changes")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        let unrelated = NSScrollView()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: unrelated)
        growAndMoveUp(height: 1080, y: 300)
        await settle(scroll)
        check(samples.last?.1 == false,
              "Ending the outer gesture restores extent checks and unrelated scroll views cannot relax them")

        // Queue an actual bottom measurement, then inject upward input before
        // its coalesced callback is delivered. Deliberately do not move the
        // clip afterward: a stale bottom sample must not undo the new pause.
        var queuedPolicy = TranscriptFollowPolicy(), upwardIntents = 0
        probe.changed = { metrics, movedUp in
            samples.append((metrics, movedUp)); queuedPolicy.observe(metrics, movedUp: movedUp)
        }
        probe.userScrolledUp = { upwardIntents += 1; queuedPolicy.pauseForUserScroll() }
        let deliveredBefore = samples.count
        scrollToFraction(1, scroll: scroll)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        if let point = wheelPoint(in: scroll, root: scroll, requireOwner: scroll) {
            probe.observeUserWheel(wheel(window: window, point: point, delta: 120))
            check(samples.count == deliveredBefore && upwardIntents == 1 && !queuedPolicy.followsBottom,
                  "Upward wheel intent pauses while a real bottom measurement is still queued")
            await settle(scroll)
            check(!queuedPolicy.followsBottom && samples.count == deliveredBefore,
                  "A pre-input queued bottom measurement cannot resume following before the user's clip move")
        } else { check(false, "The queued-bottom fixture exposes a real outer wheel hit target") }
    }
    private static func scrollToFraction(_ fraction: CGFloat, scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        let extent = max(0, document.bounds.height - scroll.contentView.bounds.height)
        let y = document.isFlipped ? document.bounds.minY + extent * fraction : document.bounds.minY + extent * (1 - fraction)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    private static func settle(_ host: NSView) async {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
