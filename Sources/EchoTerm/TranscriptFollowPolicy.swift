import Foundation

/// Only content/focus changes arm following. Lazy document-size estimates can
/// need a second pass, but geometry never replenishes the finite correction
/// budget and therefore cannot create a self-sustaining scroll/layout loop.
struct TranscriptFollowPolicy: Equatable {
    private(set) var followsBottom = true
    private var remainingCorrections = 0

    mutating func observe(_ metrics: TranscriptScrollMetrics, movedUp: Bool) {
        if movedUp && !metrics.isAtBottom { pauseForUserScroll() }
        else if metrics.isAtBottom { followsBottom = true }
    }

    @discardableResult mutating func requestFollow() -> Bool {
        guard followsBottom else { return false }
        remainingCorrections = 2
        return true
    }
    mutating func takeGeometryCorrection(_ metrics: TranscriptScrollMetrics) -> Bool {
        guard followsBottom, !metrics.isAtBottom, remainingCorrections > 0 else { return false }
        remainingCorrections -= 1
        return true
    }
    mutating func pauseForUserScroll() { followsBottom = false; remainingCorrections = 0 }
    mutating func resume() { followsBottom = true }
}
