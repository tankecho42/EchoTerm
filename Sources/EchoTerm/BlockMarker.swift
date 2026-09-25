import SwiftUI

/// Stable semantic colors, independent of the user's accent theme.
enum BlockMarker {
    case failure, assistant
    func color(light: Bool) -> Color {
        switch self {
        case .failure: return Color(hex: light ? 0xC7424F : 0xEB7078)
        case .assistant: return Color(hex: light ? 0x3A73C4 : 0x80AEF2)
        }
    }
}

extension CommandBlock {
    var marker: BlockMarker? {
        if isAI { return .assistant }
        return exitCode.map { $0 == 0 ? nil : .failure } ?? nil
    }
}
