import SwiftUI
import AppKit

enum TerminalTheme: String, CaseIterable, Codable, Identifiable {
    case graphite = "石墨", midnight = "午夜", paper = "纸白"
    case mist = "雾蓝", iris = "鸢尾", amber = "琥珀", porcelain = "暖瓷"
    var id: String { rawValue }
    var isLight: Bool { self == .paper || self == .porcelain }
    private var palette: (background: UInt32, text: UInt32, muted: UInt32, accent: UInt32) {
        switch self {
        case .graphite: return (0x171B1D, 0xD9E1DD, 0x8B9993, 0x9DD9BB)
        case .midnight: return (0x141929, 0xD9E1DD, 0x8F9CA6, 0x9DD9BB)
        case .paper: return (0xF4F3EF, 0x303B37, 0x65736B, 0x237B62)
        case .mist: return (0x181D26, 0xDEE5EF, 0x939FB2, 0x91BBF2)
        case .iris: return (0x201C2B, 0xE8E1F2, 0xA69BB6, 0xC0A2EF)
        case .amber: return (0x252019, 0xEAE1D4, 0xA89C89, 0xE4B775)
        case .porcelain: return (0xF7F2EB, 0x463C38, 0x7B6E67, 0x9A564D)
        }
    }
    var base: Color { Color(nsColor: background) }
    var background: NSColor { NSColor(hex: palette.background) }
    var text: Color { Color(hex: palette.text) }
    var muted: Color { Color(hex: palette.muted) }
    var accent: Color { Color(hex: palette.accent) }
    var line: Color { text.opacity(0.09) }
    var surface: Color { isLight ? .white.opacity(0.55) : .white.opacity(0.025) }
    /// Preserve ANSI roles while matching the theme's contrast and temperature.
    var ansiColors: [UInt32] {
        if isLight {
            return [0x34343B, 0xB33D4B, 0x347251, 0x92701D, 0x396AB1, 0x8951A0, 0x257A80, 0xDDD8D0,
                    0x776F76, 0xC34D5B, 0x42865E, 0x997220, 0x487ABA, 0x9860B0, 0x29858C, 0xFAF7F2]
        }
        let blue: UInt32 = self == .iris ? 0xA1A9F5 : self == .amber ? 0x9CB5D6 : 0x8EBAEF
        let purple: UInt32 = self == .amber ? 0xC5A1BD : 0xC5A3E8
        return [0x34333B, 0xED969F, 0x9ECBA8, 0xE3C48C, blue, purple, 0x8FCBD0, palette.text,
                0x8B8592, 0xF5B0B7, 0xB5DDBD, 0xF1D7AA, 0xB1CEFA, 0xD9BEF5, 0xB0E0E4, 0xF8F6FB]
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
    }
}
extension Color { init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) } }

enum GlassMaterial: String, CaseIterable, Identifiable {
    case clear = "通透", soft = "柔和", frosted = "磨砂"
    var id: String { rawValue }
    var material: NSVisualEffectView.Material {
        switch self { case .clear: return .hudWindow; case .soft: return .underWindowBackground; case .frosted: return .sidebar }
    }
}

final class Preferences: ObservableObject {
    @Published var theme: TerminalTheme { didSet { save() } }
    @Published var sidebarPinned: Bool { didSet { save() } }
    @Published var shellChoice: ShellChoice { didSet { save() } }
    @Published var separators: Bool { didSet { save() } }
    @Published var verticalTabs: Bool { didSet { save() } }
    @Published var opacity: Double { didSet { save() } }
    @Published var blur: Bool { didSet { save() } }
    @Published var glassMaterial: GlassMaterial { didSet { save() } }
    @Published var fontSize: Double { didSet { save() } }
    @Published var fontName: String { didSet { save() } }
    @Published var proactive: Bool { didSet { save() } } // Legacy preference; no automatic requests in either mode.
    @Published var assistantMode: AssistantMode { didSet { save() } }
    @Published var defaultInputRoute: InputRoute { didSet { save() } }
    @Published var tabNamingPolicy: TabNamingPolicy { didSet { save() } }
    @Published var streamReplies: Bool { didSet { save() } }
    @Published var agentStepLimit: Int { didSet { save() } }
    @Published var commandTimeout: Double { didSet { save() } }
    @Published var quickIntents: Bool { didSet { save() } }
    @Published var quickProviderID: String { didSet { save() } }
    @Published var shareContext: Bool { didSet { save() } }
    @Published var copyOnSelection: Bool { didSet { save() } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sidebarPinned = defaults.bool(forKey: "sidebarPinned")
        shellChoice = ShellChoice(rawValue: defaults.string(forKey: "shellChoice") ?? "") ?? .system
        separators = defaults.object(forKey: "separators") as? Bool ?? true
        theme = TerminalTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .graphite
        verticalTabs = defaults.object(forKey: "verticalTabs") as? Bool ?? true
        opacity = min(1, max(0.1, defaults.object(forKey: "opacity") as? Double ?? 0.94))
        blur = defaults.object(forKey: "blur") as? Bool ?? true
        glassMaterial = GlassMaterial(rawValue: defaults.string(forKey: "glassMaterial") ?? "") ?? .soft
        fontSize = defaults.object(forKey: "fontSize") as? Double ?? 13
        fontName = defaults.string(forKey: "fontName") ?? "自动"
        quickIntents = defaults.object(forKey: "quickIntents") as? Bool ?? true
        quickProviderID = defaults.string(forKey: "quickProviderID") ?? ""
        proactive = defaults.bool(forKey: "proactive")
        assistantMode = AssistantMode(rawValue: defaults.string(forKey: "assistantMode") ?? "") ?? .answer
        defaultInputRoute = InputRoute(rawValue: defaults.string(forKey: "defaultInputRoute") ?? "") ?? .automatic
        tabNamingPolicy = TabNamingPolicy(rawValue: defaults.string(forKey: "tabNamingPolicy") ?? "") ?? .directory
        streamReplies = defaults.object(forKey: "streamReplies") as? Bool ?? true
        agentStepLimit = min(24, max(1, defaults.object(forKey: "agentStepLimit") as? Int ?? 8))
        commandTimeout = min(600, max(10, defaults.object(forKey: "commandTimeout") as? Double ?? 60))
        shareContext = defaults.object(forKey: "shareContext") as? Bool ?? true
        copyOnSelection = defaults.object(forKey: "copyOnSelection") as? Bool ?? false
    }
    private func save() {
        defaults.set(sidebarPinned, forKey: "sidebarPinned")
        defaults.set(shellChoice.rawValue, forKey: "shellChoice")
        defaults.set(separators, forKey: "separators")
        defaults.set(theme.rawValue, forKey: "theme")
        defaults.set(verticalTabs, forKey: "verticalTabs")
        defaults.set(opacity, forKey: "opacity")
        defaults.set(blur, forKey: "blur")
        defaults.set(glassMaterial.rawValue, forKey: "glassMaterial")
        defaults.set(fontSize, forKey: "fontSize")
        defaults.set(fontName, forKey: "fontName")
        defaults.set(quickIntents, forKey: "quickIntents")
        defaults.set(quickProviderID, forKey: "quickProviderID")
        defaults.set(proactive, forKey: "proactive")
        defaults.set(assistantMode.rawValue, forKey: "assistantMode")
        defaults.set(defaultInputRoute.rawValue, forKey: "defaultInputRoute")
        defaults.set(tabNamingPolicy.rawValue, forKey: "tabNamingPolicy")
        defaults.set(streamReplies, forKey: "streamReplies")
        defaults.set(agentStepLimit, forKey: "agentStepLimit")
        defaults.set(commandTimeout, forKey: "commandTimeout")
        defaults.set(shareContext, forKey: "shareContext")
        defaults.set(copyOnSelection, forKey: "copyOnSelection")
    }
    static var fontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            ["mono", "meslo", "nerd", "menlo", "monaco", "hack", "courier", "sf mono"].contains { family.lowercased().contains($0) } && !family.lowercased().contains("symbols")
        }.sorted()
    }
    var terminalFont: NSFont {
        if fontName != "自动", let font = NSFont(name: fontName, size: fontSize) { return font }
        for name in ["MesloLGS NF", "MesloLGS Nerd Font", "JetBrainsMono Nerd Font", "Hack Nerd Font", "Menlo"] {
            if let font = NSFont(name: name, size: fontSize) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
}

struct WindowMaterial: NSViewRepresentable {
    var enabled: Bool
    var material: GlassMaterial = .soft
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material.material
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.isHidden == enabled { view.isHidden = !enabled }
        if view.material != material.material { view.material = material.material }
    }
}
