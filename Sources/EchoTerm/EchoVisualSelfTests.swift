#if DEBUG
import AppKit

@MainActor enum EchoVisualSelfTests {
    static func run(check: (Bool, String) -> Void) {
        check(EchoAction(activity: .working, executing: true) == .executing && EchoAction(activity: .working, executing: false) == .replying, "Echo distinguishes PTY execution from streaming a reply")
        check(EchoAction(activity: .success, executing: true) == .success && EchoAction(activity: .stopped, executing: true) == .stopped, "Historical Echo faces never inherit a later command's activity")
        var bounded = true, motionless = true
        for action in EchoAction.allCases {
            let fixed = EchoPixels.frame(action: action, time: 0, reducedMotion: true)
            for time in stride(from: 0.0, through: 12.0, by: 0.075) {
                let pixels = EchoPixels.frame(action: action, time: time)
                bounded = bounded && pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x < Double(EchoPixels.dimension) && $0.y >= 0 && $0.y < Double(EchoPixels.dimension) && (0...1).contains($0.opacity) }
                let still = EchoPixels.frame(action: action, time: time, reducedMotion: true)
                motionless = motionless && zip(fixed, still).allSatisfy { $0.x == $1.x && $0.y == $1.y && $0.tone == $1.tone && $0.opacity == $1.opacity }
            }
        }
        check(bounded, "All Echo animation phases stay finite and inside the avatar, over two full cycles")
        check(motionless, "Reduce Motion preserves every expression without particle movement or flashing")
        let ringStart = EchoPixels.frame(action: .thinking, time: 0).filter { $0.opacity > 0 }
        let ringLater = EchoPixels.frame(action: .thinking, time: 0.1).filter { $0.opacity > 0 }
        check(ringStart.count == 46 && ringStart.allSatisfy { p in
            let radius = hypot(p.x - 6.5, p.y - 6.5)
            return abs(radius - 5.2) < 0.0001 || abs(radius - 3.1) < 0.0001
        }, "Thinking pixels form exactly two concentric rings")
        let rotation = zip(ringStart, ringLater).map { ($0.x - 6.5) * ($1.y - 6.5) - ($0.y - 6.5) * ($1.x - 6.5) }
        check(rotation.prefix(28).allSatisfy { $0 > 0 } && rotation.suffix(18).allSatisfy { $0 < 0 }, "Outer and inner rings rotate in opposite directions")
        let now = Date(timeIntervalSince1970: 100)
        check(EchoPixelMotion.celebrationRemaining(completedAt: now, now: now) == 5 &&
              EchoPixelMotion.celebrationRemaining(completedAt: now, now: now.addingTimeInterval(4.75)) == 0.25 &&
              EchoPixelMotion.celebrationRemaining(completedAt: now, now: now.addingTimeInterval(5)) == 0 &&
              EchoPixelMotion.celebrationRemaining(completedAt: now, now: now.addingTimeInterval(100)) == 0,
              "Success lasts five seconds from Block completion and is not replayed by scrolling back")
        func same(_ a: [EchoPixel], _ b: [EchoPixel]) -> Bool {
            let visibleA = a.filter { $0.opacity > 0.00001 }.sorted { $0.id < $1.id }
            let visibleB = b.filter { $0.opacity > 0.00001 }.sorted { $0.id < $1.id }
            return visibleA.count == visibleB.count && zip(visibleA, visibleB).allSatisfy {
                $0.id == $1.id && abs($0.x - $1.x) < 0.00001 && abs($0.y - $1.y) < 0.00001 &&
                abs($0.opacity - $1.opacity) < 0.00001 && $0.darkInk == $1.darkInk && $0.lightInk == $1.lightInk
            }
        }
        var continuous = true, transitionBounded = true
        for from in EchoAction.allCases { for to in EchoAction.allCases {
            var motion = EchoPixelMotion(action: from, began: now)
            let before = motion.frame(at: now)
            let flows = motion.change(to: to, at: now, reducedMotion: false)
            continuous = continuous && same(flows ? before : EchoPixels.frame(action: to, time: 0), motion.frame(at: now)) &&
                same(motion.frame(at: now.addingTimeInterval(1)), EchoPixels.frame(action: to, time: 1))
            for elapsed in stride(from: 0.0, through: 0.6, by: 0.05) {
                let frame = motion.frame(at: now.addingTimeInterval(elapsed))
                transitionBounded = transitionBounded && Set(frame.map(\.id)).count == frame.count && frame.count < 110 && frame.allSatisfy {
                    $0.x.isFinite && $0.y.isFinite && (0...13).contains($0.x) && (0...13).contains($0.y) && (0...1).contains($0.opacity)
                }
            }
            let mid = now.addingTimeInterval(0.23), snapshot = motion.frame(at: now.addingTimeInterval(0.23))
            let returnsWithFlow = motion.change(to: .idle, at: mid, reducedMotion: false)
            continuous = continuous && same(returnsWithFlow ? snapshot : EchoPixels.frame(action: .idle, time: 0), motion.frame(at: mid))
        } }
        check(continuous, "Flowing expressions preserve endpoints and interrupted pixels; discrete eye gestures switch immediately")
        check(transitionBounded, "All expression transitions keep unique, bounded particles without accumulating copies")
        var discrete = true
        for gesture in [EchoAction.blink, .wink] {
            var motion = EchoPixelMotion(action: .idle, began: now)
            let enteredWithFlow = motion.change(to: gesture, at: now, reducedMotion: false)
            discrete = discrete && !enteredWithFlow && motion.source.isEmpty && same(motion.frame(at: now), EchoPixels.frame(action: gesture, time: 0))
            let reopenedWithFlow = motion.change(to: .idle, at: now.addingTimeInterval(0.12), reducedMotion: false)
            discrete = discrete && !reopenedWithFlow && motion.source.isEmpty && same(motion.frame(at: now.addingTimeInterval(0.12)), EchoPixels.frame(action: .idle, time: 0))
            motion.change(to: gesture, at: now, reducedMotion: false)
            discrete = discrete && motion.change(to: .thinking, at: now, reducedMotion: false)
        }
        check(discrete, "Blink and wink close and reopen without flowing pixels or animation ticks; new work can still morph out of either")
        let archived = EchoPixels.frame(action: .history, time: 0)
        let visibleMark = archived.filter { $0.opacity > 0 }
        let idle = EchoPixels.frame(action: .idle, time: 0)
        check(visibleMark.count == 9 && visibleMark.allSatisfy { $0.opacity == 1 && $0.tone == 6 && $0.darkInk.y > $0.darkInk.x && $0.lightInk.y > $0.lightInk.x } &&
              visibleMark.allSatisfy { $0.x.rounded() == $0.x && $0.y.rounded() == $0.y } &&
              Set(archived.map(\.id)) == Set(idle.map(\.id)),
              "History contains only nine green check squares and preserves the original bear particle identities")
        var retiring = EchoPixelMotion(action: .idle, began: now)
        retiring.change(to: .history, at: now, reducedMotion: false)
        let midway = retiring.frame(at: now.addingTimeInterval(0.28))
        let movingSquares = zip(idle, archived).filter { hypot($0.x - $1.x, $0.y - $1.y) > 1 }.count
        check(same(retiring.frame(at: now), idle) && movingSquares > 20 && !same(midway, idle) && !same(midway, archived) &&
              same(retiring.frame(at: now.addingTimeInterval(1)), archived) &&
              same(retiring.frame(at: now.addingTimeInterval(100)), archived),
              "Bear squares flow into the history mark, then stay still without replay or rotation")
        let arrival = EchoPixelMotion.arriving(at: now)
        let appearing = arrival.frame(at: now.addingTimeInterval(0.27))
        let received = EchoPixels.frame(action: .received, time: 0)
        check(arrival.frame(at: now).allSatisfy { $0.opacity == 0 } && appearing.contains { $0.opacity > 0 && $0.opacity < 1 } &&
              !same(appearing, received) && same(arrival.frame(at: now.addingTimeInterval(0.6)), received) &&
              same(arrival.frame(at: now, reducedMotion: true), received),
              "New Echo gathers flowing pixels from an invisible frame; Reduce Motion shows the received face immediately")
        check(abs(EchoArrival.remaining(startedAt: now, now: now.addingTimeInterval(0.55), action: .thinking, reducedMotion: false) - 1) < 0.00001 &&
              EchoArrival.remaining(startedAt: now, now: now.addingTimeInterval(1.55), action: .thinking, reducedMotion: false) < 0.00001 &&
              EchoArrival.remaining(startedAt: now, now: now.addingTimeInterval(0.7), action: .replying, reducedMotion: false) > 0.8 &&
              EchoArrival.remaining(startedAt: now, now: now.addingTimeInterval(0.7), action: .success, reducedMotion: false) > 0.8 &&
              EchoArrival.remaining(startedAt: now, now: now, action: .stopped, reducedMotion: false) == 0 &&
              EchoArrival.remaining(startedAt: now, now: now, action: .history, reducedMotion: false) == 0 &&
              EchoArrival.remaining(startedAt: now, now: now.addingTimeInterval(20), action: .thinking, reducedMotion: false) == 0,
              "Received face holds one second after entrance, survives early streaming, and never delays cancellation or replays on revisiting")
        var reduced = EchoPixelMotion(action: .thinking, began: now)
        reduced.change(to: .success, at: now, reducedMotion: true)
        check(same(reduced.frame(at: now, reducedMotion: true), EchoPixels.frame(action: .success, time: 0, reducedMotion: true)), "Reduce Motion skips particle transitions immediately")
        check(TimelineLayout.railHeight(3, available: 900) == TimelineLayout.railHeight(3, available: 400), "Short timeline keeps its compact length instead of stretching with the window")
        check(TimelineLayout.railHeight(300, available: 900) <= 320 && TimelineLayout.contentHeight(300) > 320, "Long history scrolls inside a bounded floating rail")
        check(TimelineLayout.railHeight(300, available: 146) <= 122, "Timeline fits a short split pane")
        check(TimelineLayout.nearest(0, count: 0) == nil && TimelineLayout.nearest(-100, count: 3) == 0 && TimelineLayout.nearest(9000, count: 3) == 2, "Timeline safely handles empty history and pointer positions beyond either edge")
        check((0..<300).allSatisfy { TimelineLayout.nearest(TimelineLayout.y($0), count: 300) == $0 }, "Every node remains individually addressable in a 300-block history")
        check(TimelineLayout.proximity(0) > TimelineLayout.proximity(17) && TimelineLayout.proximity(17) > TimelineLayout.proximity(34) && TimelineLayout.proximity(100) < 0.001, "Magnification decreases smoothly through neighboring nodes")
        check([146.0, 400, 900].allSatisfy { h in [-100.0, 0, 50, 1000].allSatisfy { y in let p = TimelineLayout.previewY(node: y, height: h); return p >= 0 && p + 110 <= h } }, "Timeline previews remain inside short and full-height panes")
        let asset = EchoAssets.bundle.url(forResource: "echo-wave", withExtension: "png")
        let bitmap = asset.flatMap { try? Data(contentsOf: $0) }.flatMap { NSBitmapImageRep(data: $0) }
        check(EchoAssets.portrait != nil && bitmap?.hasAlpha == true && (bitmap?.pixelsWide ?? 0) > 500, "Packaged Echo illustration exists and preserves transparency")
    }
}
#endif
