#if DEBUG
import AppKit
import Foundation
import SwiftUI

/// Drives the AppKit input boundary rather than SwiftTerm's programmatic send API.
@MainActor enum NativeTerminalTestDriver {
    static func eligibility(_ terminal: BlockTerminalView) -> String {
        "window=\(terminal.window?.windowNumber ?? -1) visible=\(terminal.window?.isVisible ?? false) key=\(terminal.window?.isKeyWindow ?? false) firstResponder=\(terminal.window?.firstResponder === terminal) nativeAllowed=\(terminal.nativeInputAllowed) autofocusAllowed=\(terminal.keyboardFocusAllowed)"
    }
    static func insert(_ text: String, into terminal: BlockTerminalView) {
        terminal.insertText(text as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    @discardableResult static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], unmodified: String? = nil, into terminal: BlockTerminalView) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: terminal.window?.windowNumber ?? 0, context: nil,
                                    characters: characters, charactersIgnoringModifiers: unmodified ?? characters,
                                    isARepeat: false, keyCode: code)!
        // This is the same dispatcher used by the window-scoped event monitor;
        // it calls inherited AppKit keyDown once under native-input provenance.
        return terminal.dispatchNativeKeyDown(event)
    }
    static func enter(_ terminal: BlockTerminalView) { key("\r", code: 36, into: terminal) }
    static func escape(_ terminal: BlockTerminalView) { key("\u{1b}", code: 53, into: terminal) }
    static func down(_ terminal: BlockTerminalView) { key("\u{f701}", code: 125, modifiers: [.function, .numericPad], into: terminal) }
    static func up(_ terminal: BlockTerminalView) { key("\u{f700}", code: 126, modifiers: [.function, .numericPad], into: terminal) }
    static func controlC(_ terminal: BlockTerminalView) { key("\u{3}", code: 8, modifiers: .control, unmodified: "c", into: terminal) }
}

/// A CLI component fixture controls only the key-window flag. OS focus and event
/// delivery are verified separately with the bundled QA app, not by this override.
@MainActor final class NativeTerminalTestWindow: NSWindow {
    var simulatedKeyEligibility = true
    override var isKeyWindow: Bool { simulatedKeyEligibility }
}

/// Hosts real AppKit/TerminalHost objects without ordering windows or activating
/// an application. The test window supplies explicit simulated key eligibility.
@MainActor final class NativeTerminalTestHost {
    let window: NativeTerminalTestWindow
    let field = NSTextField(string: "another input owns focus")
    private let host: NSHostingView<AnyView>
    private let session: TerminalSession
    private let preferences: Preferences
    init(session: TerminalSession, preferences: Preferences) {
        self.session = session; self.preferences = preferences
        window = NativeTerminalTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        host = NSHostingView(rootView: AnyView(TerminalHost(session: session, preferences: preferences, active: true).disabled(false)))
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 560))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 510)
        field.frame = NSRect(x: 0, y: 520, width: 300, height: 24)
        surface.addSubview(host); surface.addSubview(field); window.contentView = surface
        surface.layoutSubtreeIfNeeded()
    }
    func update(active: Bool, enabled: Bool = true) {
        host.rootView = AnyView(TerminalHost(session: session, preferences: preferences, active: active).disabled(!enabled))
        host.layoutSubtreeIfNeeded()
    }
    func close() {
        host.rootView = AnyView(EmptyView()); window.contentView = nil; window.close()
    }
}

/// Isolates menu dispatch from the application's real Stop/Settings actions.
@MainActor final class NativeTerminalTestMenu: NSObject {
    private let previous: NSMenu?
    private(set) var periodInvocations = 0
    private(set) var commaInvocations = 0
    override init() {
        previous = NSApp.mainMenu
        super.init()
        let menu = NSMenu(title: "Native input fixture")
        menu.autoenablesItems = false
        let container = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "Fixture commands")
        commands.autoenablesItems = false
        let period = NSMenuItem(title: "Fixture Stop", action: #selector(NativeTerminalTestMenu.period(_:)), keyEquivalent: ".")
        period.target = self; period.keyEquivalentModifierMask = .command; period.isEnabled = true
        let comma = NSMenuItem(title: "Fixture Settings", action: #selector(NativeTerminalTestMenu.comma(_:)), keyEquivalent: ",")
        comma.target = self; comma.keyEquivalentModifierMask = .command; comma.isEnabled = true
        commands.addItem(period); commands.addItem(comma); container.submenu = commands; menu.addItem(container)
        NSApp.mainMenu = menu
    }
    @objc private func period(_ sender: Any?) { periodInvocations += 1 }
    @objc private func comma(_ sender: Any?) { commaInvocations += 1 }
    func restore() { NSApp.mainMenu = previous }
}
#endif
