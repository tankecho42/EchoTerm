#if DEBUG
import Foundation
import AppKit

@MainActor enum PerformanceSelfTests {
    static func run(check: (Bool, String) -> Void) throws {
        let line = "printf '" + String(repeating: "长输入 hello ", count: 20_000) + "'"
        let start = ProcessInfo.processInfo.systemUptime
        let word = ShellWords.executable(in: line)
        check(word?.value == "printf" && word?.range == NSRange(location: 0, length: 6), "Long command assessment reads the executable without lexing its giant argument")
        let assigned = ShellWords.executable(in: "A='some value' B=2 " + line)
        check(assigned?.value == "printf", "Early executable lookup preserves quoted environment assignments")
        check(TextLayoutPolicy.needsViewport(line) && TextLayoutPolicy.needsViewport(String(repeating: "row\n", count: 1_200)) && !TextLayoutPolicy.needsViewport("short output\n"), "Long lines and many-line outputs use bounded text viewports")
        let layout = NSLayoutManager(); layout.allowsNonContiguousLayout = true
        let storage = NSTextStorage(string: line)
        let container = NSTextContainer(containerSize: NSSize(width: 800, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 800, height: 300), in: container)
        check(storage.string == line && layout.allowsNonContiguousLayout && layout.glyphRange(forBoundingRect: NSRect(x: 0, y: 0, width: 800, height: 300), in: container).length < storage.length, "TextKit preserves full long input while laying out only the visible viewport")
        let suite = "EchoTerm.Performance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.1, forKey: "opacity")
        let preferences = Preferences(defaults: defaults)
        preferences.glassMaterial = .clear
        let restored = Preferences(defaults: defaults)
        check(restored.opacity == 0.1 && restored.glassMaterial == .clear, "Ten-percent background opacity and glass material persist")
        defaults.set(-1.0, forKey: "opacity")
        check(Preferences(defaults: defaults).opacity == 0.1, "Invalid stored opacity clamps to the new supported minimum")
        print(String(format: "INFO long-input / viewport checks: %.1f ms", (ProcessInfo.processInfo.systemUptime - start) * 1_000))
    }
}
#endif
