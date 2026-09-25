import SwiftUI

/// Only the requested row animates, for a bounded duration; no timeline-wide timer.
struct BlockRevealHighlight: ViewModifier {
    let reveal: BlockReveal?
    let theme: TerminalTheme
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.overlay {
            Rectangle()
                .fill(theme.accent.opacity(lit ? 0.14 : 0))
                .overlay(Rectangle().strokeBorder(theme.accent.opacity(lit ? 0.65 : 0), lineWidth: 1.5))
                .allowsHitTesting(false).accessibilityHidden(true)
        }.task(id: reveal?.id) {
            lit = false
            guard let reveal, ProcessInfo.processInfo.systemUptime - reveal.started < 4 else { return }
            do {
                try await Task.sleep(nanoseconds: 280_000_000)
                if reduceMotion {
                    lit = true; try await Task.sleep(nanoseconds: 1_000_000_000); lit = false
                } else {
                    for _ in 0..<2 {
                        withAnimation(.easeOut(duration: 0.15)) { lit = true }
                        try await Task.sleep(nanoseconds: 240_000_000)
                        withAnimation(.easeOut(duration: 0.2)) { lit = false }
                        try await Task.sleep(nanoseconds: 260_000_000)
                    }
                }
            } catch { lit = false }
        }
    }
}
