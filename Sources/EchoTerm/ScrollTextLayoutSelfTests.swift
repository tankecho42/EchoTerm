#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Isolated production-view mount/layout cases. A background heartbeat remains
/// visible if a synchronous AppKit/SwiftUI layout prevents the main actor ticking.
@MainActor enum ScrollTextLayoutSelfTests {
    static func includesCase(_ name: String) -> Bool {
        let filter = ProcessInfo.processInfo.environment["ECHOTERM_SCROLL_LAYOUT_CASES"] ?? ""
        return filter.isEmpty || filter.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }
    static func run(check: (Bool, String) -> Void) async {
        if includesCase("markdown-policy") { runPolicy(check: check) }
        let cases: [(String, String?)] = [
            ("selectable-probes", nil),
            ("paragraph90k", paragraph()),
            ("list2000", (0..<2_000).map { "- layout-case item \($0) short value" }.joined(separator: "\n")),
            ("list8000", (0..<8_000).map { "- item\($0)" }.joined(separator: "\n")),
            ("table2000", "| layout-case | Value |\n| --- | --- |\n" + (0..<2_000).map { "| row \($0) | short value |" }.joined(separator: "\n"))
        ]
        for (name, markdown) in cases where includesCase(name) {
            await runCase(name, markdown: markdown, check: check)
        }
    }
    static func runPolicy(check: (Bool, String) -> Void) {
        func isViewport(_ source: String) -> Bool { if case .viewport = MarkdownRenderPolicy.plan(for: source) { return true }; return false }
        let ordinary = "# Heading\n\n**bold** with [link](https://example.com) and `code`\n\n> quoted\n\n- first item\n\n```sh\nprintf ordinary\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |"
        if case .rich(let pieces) = MarkdownRenderPolicy.plan(for: ordinary) {
            check(pieces.contains(.heading(1, "Heading")) && pieces.contains(.quote("quoted")) && pieces.contains(.item("•", "first item"))
                  && pieces.contains(.code("sh", "printf ordinary")) && pieces.contains(.table([["A", "B"], ["1", "2"]]))
                  && pieces.contains(.paragraph("**bold** with [link](https://example.com) and `code`")),
                  "Ordinary headings, inline formatting, links, quotes, lists, shell fences and tables keep the rich Markdown path")
        } else { check(false, "Ordinary Markdown retains rich formatting") }
        let denseList = (0..<8_000).map { "- item\($0)" }.joined(separator: "\n")
        check(denseList.utf8.count < 100_000 && isViewport(denseList),
              "A dense list below the byte cutoff uses a bounded viewport rather than thousands of native text views")
        let table = "| A | B | C | D | E | F | G | H |\n| --- | --- | --- | --- | --- | --- | --- | --- |\n"
            + Array(repeating: "| a | b | c | d | e | f | g | h |", count: 40).joined(separator: "\n")
        check(isViewport(table), "Rich table budgeting counts cells cumulatively rather than treating each entire table as one component")
        check(isViewport(paragraph()) && isViewport(String(repeating: "中", count: 3_000)),
              "Oversized inline paragraphs are bounded using UTF-8 cost even below the full-response byte cutoff")
        check(!isViewport(Array(repeating: "short line", count: 64).joined(separator: "\n"))
              && isViewport(Array(repeating: "short line", count: 65).joined(separator: "\n")),
              "A many-line single paragraph is bounded independently of its small byte count")
        let code = String(repeating: "| fenced code row |\n", count: 1_000)
        if case .rich(let pieces) = MarkdownRenderPolicy.plan(for: "~~~text\n" + code + "~~~") {
            check(pieces == [.code("text", String(code.dropLast()))] && TextLayoutPolicy.needsViewport(code),
                  "Fenced code lines and pipes keep their existing bounded code viewport without inflating rich component counts")
        } else { check(false, "Fenced code keeps its bounded rich code container") }
        let atBudget = (0..<256).map { "- item\($0)" }.joined(separator: "\n")
        check(!isViewport(atBudget) && isViewport(atBudget + "\n- one more"),
              "The rich component boundary remains usable and the next list item selects the bounded fallback")
    }
    private static func paragraph() -> String {
        let unit = "layout-case paragraph **bold** 中文🙂 [link](https://example.com) plain words. "
        let count = 90_000 / unit.utf8.count
        let prefix = String(repeating: unit, count: count)
        return prefix + String(repeating: "x", count: 90_000 - prefix.utf8.count)
    }
    private final class Metrics: @unchecked Sendable {
        private let lock = NSLock()
        private let started = ProcessInfo.processInfo.systemUptime
        private var lastBeat = ProcessInfo.processInfo.systemUptime
        private var beats = 0, probes = 0, startedProbes = 0, finiteProbeFailures = 0, infiniteResults = 0
        private var maximumMainGap: TimeInterval = 0
        private var maximumTextViews = 0
        private var currentProbe = "none"
        func beat() {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            maximumMainGap = max(maximumMainGap, now - lastBeat)
            beats += 1; lastBeat = now
        }
        func observe(textViews: Int) { lock.lock(); maximumTextViews = max(maximumTextViews, textViews); lock.unlock() }
        func beginProbe(width: CGFloat?) {
            lock.lock(); startedProbes += 1
            currentProbe = width.map { String(describing: $0) } ?? "nil"
            let report = startedProbes <= 6 ? "PROBE start=\(startedProbes) width=\(currentProbe)" : nil
            lock.unlock()
            if let report { ScrollTextLayoutSelfTests.log(report) }
        }
        func probe(width: CGFloat?, result: CGSize) {
            lock.lock(); defer { lock.unlock() }; probes += 1
            if !result.width.isFinite || !result.height.isFinite {
                infiniteResults += 1
                if width?.isFinite != false { finiteProbeFailures += 1 }
            }
        }
        func snapshot() -> (beats: Int, probes: Int, finiteFailures: Int, maxMainGap: TimeInterval, maxTextViews: Int, text: String) {
            lock.lock(); defer { lock.unlock() }
            let now = ProcessInfo.processInfo.systemUptime
            let maximumGap = max(maximumMainGap, now - lastBeat)
            return (beats, probes, finiteProbeFailures, maximumGap, maximumTextViews,
                    String(format: "elapsed=%.2fs mainBeats=%d mainGap=%.2fs maxMainGap=%.2fs probes=%d/%d nonfinite=%d finiteProposalFailures=%d maxTextViews=%d", now - started, beats, now - lastBeat, maximumGap, probes, startedProbes, infiniteResults, finiteProbeFailures, maximumTextViews) + " currentWidth=" + currentProbe)
        }
    }
    private struct RepeatedProposals: Layout {
        let metrics: Metrics
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            for width: CGFloat? in [0, nil, .infinity, 320, 640, 320] {
                metrics.beginProbe(width: width)
                metrics.probe(width: width, result: child.sizeThatFits(ProposedViewSize(width: width, height: nil)))
            }
            return child.sizeThatFits(ProposedViewSize(width: proposal.width ?? 640, height: nil))
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
    private struct FixtureView: View {
        let markdown: String?
        let metrics: Metrics
        var body: some View {
            if let markdown {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // Use a concrete initially visible row, independently of
                        // Reader lookup into an unmaterialized lazy Group.
                        VStack(alignment: .leading) { MarkdownContent(text: markdown, theme: .graphite) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(0..<60) { index in Text("newer filler \(index)").frame(height: 100) }
                    }.padding(16)
                }
            } else {
                RepeatedProposals(metrics: metrics) {
                    SelectableText(text: String(repeating: "layout-case short wrapped 中文🙂 text ", count: 20),
                                   font: .systemFont(ofSize: 13), color: .textColor, lineSpacing: 4, markdown: true)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
    private struct Geometry: Equatable {
        let size: NSSize
        let origin: NSPoint
        let textViews: Int
        let scrollViews: Int
    }
    private static func runCase(_ name: String, markdown: String?, check: (Bool, String) -> Void) async {
        let metrics = Metrics()
        log("BEGIN \(name) bytes=\(markdown?.utf8.count ?? 0)")
        if let markdown { check(markdown.utf8.count <= 100_000, "\(name) exercises the normal Markdown path below its raw-text cutoff") }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "EchoTerm.ScrollLayout.heartbeat"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { log("HEARTBEAT \(name) \(metrics.snapshot().text)") }
        timer.resume()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { metrics.beat(); try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        let host = NSHostingView(rootView: FixtureView(markdown: markdown, metrics: metrics))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        defer {
            heartbeat.cancel(); timer.cancel()
            window.contentView = nil; window.close()
            log("END \(name) \(metrics.snapshot().text)")
        }
        log("STEP \(name) present-background-window")
        // Lazy SwiftUI content need not materialize in an unordered window.
        // Order behind the user's windows without activating or taking focus.
        window.orderBack(nil)
        window.displayIfNeeded()
        log("STEP \(name) initial-layout")
        host.layoutSubtreeIfNeeded()
        let mounted = await settle(host, requireText: true, name: name, metrics: metrics)
        check(mounted, "\(name) mounts production text views and reaches stable geometry while the main loop remains runnable")
        guard mounted else { return }
        if let markdown, case .viewport = MarkdownRenderPolicy.plan(for: markdown) {
            let sourceView = findTextViews(in: host).first { $0.string == markdown }
            check(sourceView != nil, "\(name) retains its complete source in the bounded fallback document")
            if let sourceView {
                let pasteboard = NSPasteboard.withUniqueName()
                sourceView.selectionPasteboard = pasteboard; sourceView.copyOnSelection = true
                sourceView.selectAll(nil)
                check(pasteboard.string(forType: .string) == markdown, "\(name) can select and copy the complete fallback source without truncation")
                sourceView.copyOnSelection = false; sourceView.selectionPasteboard = .general
                pasteboard.releaseGlobally()
            }
        }
        for width: CGFloat in [620, 840, 620, 760] {
            log("STEP \(name) resize=\(Int(width))")
            window.setContentSize(NSSize(width: width, height: 520))
            host.layoutSubtreeIfNeeded()
            let stable = await settle(host, requireText: true, name: name, metrics: metrics)
            check(stable, "\(name) converges after a finite width change to \(Int(width))")
            if !stable { return }
        }
        if markdown != nil {
            guard let scroll = findScroll(in: host), let document = scroll.documentView else {
                check(false, "\(name) exposes the actual native clip view for the hosted lazy scroll container")
                return
            }
            for destination in ["bottom", "target", "bottom", "target"] {
                log("STEP \(name) native-clip-scroll=\(destination)")
                let top = document.bounds.minY
                let y = destination == "bottom" ? max(top, document.bounds.maxY - scroll.contentView.bounds.height) : top
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                check(await settle(host, requireText: destination == "target", name: name, metrics: metrics), "\(name) converges after scrolling to \(destination)")
            }
        }
        let final = metrics.snapshot()
        check(final.beats >= 3, "\(name) allows main-actor heartbeat progress between layout and scroll operations")
        check(final.maxMainGap < 2, "\(name) keeps the main-actor heartbeat gap below two seconds through text mounting and layout")
        check(final.maxTextViews <= 512, "\(name) bounds mounted selectable text systems to 512 rather than one per unbounded Markdown node")
        if markdown == nil {
            check(final.probes > 0 && final.finiteFailures == 0, "Finite, nil and infinite proposal probes do not produce invalid geometry for finite proposals")
        }
    }
    private static func settle(_ host: NSView, requireText: Bool, name: String, metrics: Metrics) async -> Bool {
        var previous: Geometry?, unchanged = 0
        for attempt in 0..<60 {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            let geometry = geometry(in: host)
            metrics.observe(textViews: geometry.textViews)
            if geometry == previous, (!requireText || geometry.textViews > 0) { unchanged += 1 } else { unchanged = 0 }
            if unchanged >= 4 {
                let dimensions = String(format: "doc=%.0fx%.0f y=%.0f", Double(geometry.size.width), Double(geometry.size.height), Double(geometry.origin.y))
                log("SETTLED \(name) ticks=\(attempt + 1) textViews=\(geometry.textViews) scrollViews=\(geometry.scrollViews) \(dimensions)")
                return geometry.size.width.isFinite && geometry.size.height.isFinite && geometry.origin.y.isFinite
            }
            previous = geometry
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let geometry = previous ?? geometry(in: host)
        let dimensions = String(format: "host=%.0fx%.0f doc=%.0fx%.0f origin=%.0f,%.0f", Double(host.frame.width), Double(host.frame.height), Double(geometry.size.width), Double(geometry.size.height), Double(geometry.origin.x), Double(geometry.origin.y))
        log("UNSETTLED \(name) windowVisible=\(host.window?.isVisible == true) textViews=\(geometry.textViews) scrollViews=\(geometry.scrollViews) \(dimensions)")
        return false
    }
    private static func geometry(in host: NSView) -> Geometry {
        var firstScroll: NSScrollView?, textViews = 0, scrollViews = 0
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView { if firstScroll == nil { firstScroll = scroll }; scrollViews += 1 }
            if view is CopySelectableTextView { textViews += 1 }
            view.subviews.forEach(visit)
        }
        visit(host)
        return Geometry(size: firstScroll?.documentView?.frame.size ?? host.frame.size, origin: firstScroll?.contentView.bounds.origin ?? .zero, textViews: textViews, scrollViews: scrollViews)
    }
    private static func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(findScroll).first
    }
    private static func findTextViews(in view: NSView) -> [CopySelectableTextView] {
        (view as? CopySelectableTextView).map { [$0] } ?? view.subviews.flatMap(findTextViews)
    }
    nonisolated private static func log(_ message: String) {
        print("SCROLL-LAYOUT \(message)"); fflush(stdout)
    }
}
#endif
