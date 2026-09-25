import SwiftUI

struct SlimePose {
    var point: CGPoint
    var squash: CGSize
    var rotation: Double
    var reveal: Double = 1
}

/// A bounded hop, with squash on takeoff/landing and a clear arc between blocks.
struct SlimeFlight {
    var from: CGPoint
    var to: CGPoint
    var started: TimeInterval
    var duration: Double = 0.72
    var roll = false
    var peek = false
    func sample(at time: TimeInterval, reduceMotion: Bool = false) -> SlimePose {
        guard !reduceMotion else { return SlimePose(point: to, squash: CGSize(width: 1, height: 1), rotation: 0) }
        let t = max(0, min(1, (time - started) / duration))
        let eased = t * t * (3 - 2 * t)
        let distance = hypot(to.x - from.x, to.y - from.y)
        let lift = min(85, 24 + distance * 0.22) * sin(.pi * t)
        let stretch = sin(.pi * t) * 0.13
        let landing = t > 0.78 && t < 1 ? sin((t - 0.78) / 0.22 * .pi) * 0.22 : 0
        return SlimePose(point: CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased - lift),
                         squash: CGSize(width: 1 - stretch + landing, height: 1 + stretch - landing),
                         rotation: roll ? 360 * eased : sin(.pi * t) * (to.x >= from.x ? 13 : -13), reveal: peek ? min(1, t * 3) : 1)
    }
    mutating func translate(_ delta: CGSize) {
        from.x += delta.width; from.y += delta.height
        to.x += delta.width; to.y += delta.height
    }
}
