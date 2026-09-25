import SwiftUI
import AppKit

private struct EchoThemeKey: EnvironmentKey { static let defaultValue = TerminalTheme.graphite }
extension EnvironmentValues {
    var echoTheme: TerminalTheme { get { self[EchoThemeKey.self] } set { self[EchoThemeKey.self] = newValue } }
}
struct EchoMenuItem: Identifiable {
    var id = UUID()
    var title: String
    var icon = ""
    var selected = false
    var action: () -> Void
}
@MainActor final class EchoMenuStore: ObservableObject {
    struct Presentation {
        var anchor: UUID
        var items: [EchoMenuItem]
        var width: CGFloat
    }
    @Published var presentation: Presentation?
    private weak var previousResponder: NSResponder?
    func dismiss() {
        presentation = nil
        let previous = previousResponder
        DispatchQueue.main.async {
            if let view = previous as? NSView, view.window === NSApp.keyWindow { view.window?.makeFirstResponder(view) }
        }
    }
    func toggle(_ anchor: UUID, items: [EchoMenuItem], width: CGFloat = 230) {
        if presentation?.anchor == anchor { dismiss() }
        else { previousResponder = NSApp.keyWindow?.firstResponder; presentation = .init(anchor: anchor, items: items, width: width) }
    }
}
private struct EchoMenuAnchors: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) { value.merge(nextValue()) { _, new in new } }
}
private struct EchoControlHost: ViewModifier {
    let theme: TerminalTheme
    @StateObject private var menus = EchoMenuStore()
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(EchoMenuAnchors.self) { anchors in
            GeometryReader { geometry in
                if let menu = menus.presentation, let anchor = anchors[menu.anchor] {
                    let rect = geometry[anchor]
                    let width = min(menu.width, max(100, geometry.size.width - 24))
                    let height = min(CGFloat(menu.items.count) * 34 + 12, 300)
                    let x = max(12, min(rect.minX, geometry.size.width - width - 12))
                    let y = rect.maxY + height + 8 < geometry.size.height ? rect.maxY + 5 : max(12, rect.minY - height - 5)
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { menus.dismiss() }
                    EchoMenuList(items: menu.items, dismiss: { menus.dismiss() })
                        .frame(width: width, height: height).offset(x: x, y: y)
                }
            }
        }
        .environmentObject(menus).environment(\.echoTheme, theme)
        .buttonStyle(EchoButtonStyle()).toggleStyle(EchoToggleStyle()).textFieldStyle(EchoTextFieldStyle())
        .disclosureGroupStyle(EchoDisclosureStyle())
    }
}
extension View {
    func echoControls(_ theme: TerminalTheme) -> some View { modifier(EchoControlHost(theme: theme)) }
    func echoContextMenu(_ items: [EchoMenuItem]) -> some View { modifier(EchoContextMenu(items: items)) }
}
private struct EchoMenuList: View {
    let items: [EchoMenuItem]
    let dismiss: () -> Void
    @Environment(\.echoTheme) private var theme
    @State private var active = 0
    @FocusState private var focused: Bool
    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { choose(index) } label: {
                            HStack(spacing: 9) {
                                if !item.icon.isEmpty { Image(systemName: item.icon).frame(width: 13) }
                                Text(item.title).lineLimit(2)
                                Spacer(minLength: 3)
                                if item.selected { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }.font(.system(size: 11)).padding(.horizontal, 10).frame(height: 34)
                                .background(index == active ? theme.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).onHover { if $0 { active = index } }.id(index)
                            .accessibilityAddTraits(item.selected ? .isSelected : [])
                    }
                }.padding(6)
            }.onChange(of: active) { _, index in reader.scrollTo(index) }
        }.background(theme.base.opacity(0.98), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.text.opacity(0.13)))
            .shadow(color: .black.opacity(0.23), radius: 16, y: 6).foregroundStyle(theme.text)
            .focusable().focused($focused).focusEffectDisabled()
            .onAppear { active = items.firstIndex(where: \.selected) ?? 0; focused = true }
            .onKeyPress(.escape) { dismiss(); return .handled }
            .onKeyPress(.downArrow) { active = min(items.count - 1, active + 1); return .handled }
            .onKeyPress(.upArrow) { active = max(0, active - 1); return .handled }
            .onKeyPress(.return) { choose(active); return .handled }
    }
    private func choose(_ index: Int) { guard items.indices.contains(index) else { return }; let action = items[index].action; dismiss(); action() }
}

struct EchoChoice<Value: Hashable> { var value: Value; var title: String }
struct EchoChoicePicker<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [EchoChoice<Value>]
    var label: String
    var small = true
    @State private var id = UUID()
    @EnvironmentObject private var menus: EchoMenuStore
    @Environment(\.echoTheme) private var theme
    var body: some View {
        Button {
            menus.toggle(id, items: choices.map { choice in
                .init(title: choice.title, selected: choice.value == selection) { selection = choice.value }
            }, width: small ? 205 : 270)
        } label: {
            HStack(spacing: 8) {
                Text(choices.first { $0.value == selection }?.title ?? label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(theme.muted)
            }.font(.system(size: small ? 10 : 11)).foregroundStyle(theme.text)
                .padding(.horizontal, 9).frame(height: small ? 22 : 30)
                .background(theme.text.opacity(small ? 0.025 : 0.045), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line).allowsHitTesting(false))
                .contentShape(.interaction, Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(choices.first { $0.value == selection }?.title ?? "")
            .anchorPreference(key: EchoMenuAnchors.self, value: .bounds) { [id: $0] }
    }
}
struct EchoLabeledChoice<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var choices: [EchoChoice<Value>]
    var body: some View {
        HStack(spacing: 18) { Text(title).font(.system(size: 11)); Spacer(minLength: 8); EchoChoicePicker(selection: $selection, choices: choices, label: title, small: false).frame(maxWidth: 285) }
    }
}
struct EchoSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [EchoChoice<Value>]
    var label: String
    @Environment(\.echoTheme) private var theme
    var body: some View {
        HStack(spacing: 3) {
            ForEach(choices, id: \.value) { choice in
                Button { selection = choice.value } label: {
                    Text(choice.title).font(.system(size: 11, weight: choice.value == selection ? .medium : .regular))
                        .foregroundStyle(choice.value == selection ? theme.text : theme.muted).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(choice.value == selection ? theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(.interaction, Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(label + " · " + choice.title).accessibilityAddTraits(choice.value == selection ? .isSelected : [])
            }
        }.padding(3).background(theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}
struct EchoMenuButton<Label: View>: View {
    var items: () -> [EchoMenuItem]
    @ViewBuilder var label: () -> Label
    @State private var id = UUID()
    @EnvironmentObject private var menus: EchoMenuStore
    var body: some View {
        Button { menus.toggle(id, items: items()) } label: { label().contentShape(.interaction, Rectangle()) }.buttonStyle(.plain)
            .anchorPreference(key: EchoMenuAnchors.self, value: .bounds) { [id: $0] }
    }
}
private struct EchoContextMenu: ViewModifier {
    let items: [EchoMenuItem]
    @State private var id = UUID()
    @EnvironmentObject private var menus: EchoMenuStore
    func body(content: Content) -> some View {
        content.anchorPreference(key: EchoMenuAnchors.self, value: .bounds) { [id: $0] }
            .background(RightClickObserver { menus.toggle(id, items: items) })
    }
}
private struct RightClickObserver: NSViewRepresentable {
    var action: () -> Void
    final class Observer: NSView {
        var action: (() -> Void)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, event.window == self.window, !self.isHiddenOrHasHiddenAncestor, self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.action?(); return nil
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) { view.action = action }
}
struct EchoButtonStyle: ButtonStyle {
    @Environment(\.echoTheme) private var theme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(configuration.role == .destructive ? .red : theme.text)
            .background(theme.text.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line).allowsHitTesting(false))
            .contentShape(.interaction, Rectangle()).opacity(enabled ? 1 : 0.4)
    }
}
struct EchoToggleStyle: ToggleStyle {
    @Environment(\.echoTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading).allowsHitTesting(false)
                Capsule().fill(configuration.isOn ? theme.accent : theme.text.opacity(0.14)).frame(width: 30, height: 17)
                    .overlay(Circle().fill(configuration.isOn ? theme.base : theme.muted).frame(width: 11, height: 11).offset(x: configuration.isOn ? 6 : -6))
                    .allowsHitTesting(false)
            }.frame(maxWidth: .infinity, minHeight: 32).contentShape(.interaction, Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}
struct EchoTextFieldStyle: TextFieldStyle {
    @Environment(\.echoTheme) private var theme
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 8)
            .background(theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.line))
    }
}
struct EchoSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.01
    var label: String
    @Environment(\.echoTheme) private var theme
    @FocusState private var focused: Bool
    private var fraction: Double { min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound))) }
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 14)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.text.opacity(0.1)).frame(height: 4)
                Capsule().fill(theme.accent.opacity(0.75)).frame(width: max(4, width * fraction + 7), height: 4)
                Circle().fill(theme.accent).frame(width: 12, height: 12).overlay(Circle().stroke(theme.base, lineWidth: 2))
                    .offset(x: width * fraction)
            }.frame(height: 22).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                    focused = true
                    set(range.lowerBound + min(1, max(0, (event.location.x - 7) / width)) * (range.upperBound - range.lowerBound))
                })
        }.frame(height: 22).focusable().focused($focused).focusEffectDisabled()
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.accent.opacity(focused ? 0.3 : 0)))
            .accessibilityLabel(label).accessibilityValue("\(Int(value * 100))%")
            .accessibilityAdjustableAction { set(value + ($0 == .increment ? step : -step)) }
            .onKeyPress(.home) { set(range.lowerBound); return .handled }
            .onKeyPress(.end) { set(range.upperBound); return .handled }
            .onKeyPress(.leftArrow) { set(value - step); return .handled }
            .onKeyPress(.rightArrow) { set(value + step); return .handled }
    }
    private func set(_ next: Double) { value = min(range.upperBound, max(range.lowerBound, (next / step).rounded() * step)) }
}
struct EchoStepper<Value: BinaryInteger>: View {
    var title: String
    @Binding var value: Value
    var range: ClosedRange<Value>
    var body: some View {
        HStack { Text(title).font(.system(size: 11)); Spacer(); Button { value -= 1 } label: { Image(systemName: "minus") }.disabled(value <= range.lowerBound).accessibilityLabel(title + " 减少"); Button { value += 1 } label: { Image(systemName: "plus") }.disabled(value >= range.upperBound).accessibilityLabel(title + " 增加") }
    }
}

struct EchoDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.echoTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold))
                    configuration.label
                    Spacer(minLength: 0)
                }.foregroundStyle(theme.muted).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "展开" : "折叠")
            if configuration.isExpanded { configuration.content.padding(.leading, 15) }
        }
    }
}
