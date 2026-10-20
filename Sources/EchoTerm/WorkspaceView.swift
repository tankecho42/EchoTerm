import SwiftUI
import AppKit

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    @ObservedObject var providers: ProviderStore
    @ObservedObject var assistant: AssistantStore
    @State private var sidebarExpanded = false
    @State private var applicationActive = NSApp.isActive
    @State private var hoveredTab: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var confirmCancelFocused: Bool
    private var theme: TerminalTheme { preferences.theme }
    private var sidebarVisible: Bool { preferences.sidebarPinned || sidebarExpanded }
    var body: some View {
        VStack(spacing: 0) {
            titlebar
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(spacing: 0) {
                if preferences.verticalTabs {
                    Color.clear.frame(width: preferences.sidebarPinned ? 196 : 44)
                    Rectangle().fill(theme.line).frame(width: 1)
                }
                VStack(spacing: 0) {
                    if !preferences.verticalTabs { horizontalTabs; Rectangle().fill(theme.line).frame(height: 1) }
                    ZStack {
                        ForEach(workspace.tabs) { tab in
                            PaneTree(node: tab.root, workspace: workspace, preferences: preferences, assistant: assistant)
                                .environment(\.echoAnimationEnabled, applicationActive && tab.id == workspace.selectedTabID && !workspace.showSettings)
                                .opacity(tab.id == workspace.selectedTabID ? 1 : 0)
                                .allowsHitTesting(tab.id == workspace.selectedTabID)
                                .accessibilityHidden(tab.id != workspace.selectedTabID)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if preferences.verticalTabs {
                    sidebar(expanded: sidebarVisible, floating: sidebarVisible && !preferences.sidebarPinned)
                        .overlay(alignment: .trailing) { Rectangle().fill(theme.line).frame(width: 1) }
                        .shadow(color: .black.opacity(sidebarExpanded && !preferences.sidebarPinned ? 0.18 * preferences.opacity : 0), radius: 14, x: 7)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                sidebarExpanded = inside
                                if !inside { hoveredTab = nil }
                            }
                        }
                }
            }
        }
        .coordinateSpace(name: "workspace-assistant")
        .overlay(alignment: .topLeading) {
            if workspace.assistantVisible, let session = workspace.assistantSession {
                PersistentAssistantOverlay(session: session, workspace: workspace, assistant: assistant, preferences: preferences).id(session.id)
            }
        }
        .onReceive(assistant.$presentation) { request in
            if let request { workspace.presentAssistant(for: request.sessionID, automatic: request.automatic) }
        }
        .background(theme.base.opacity(preferences.opacity))
        .background(WindowMaterial(enabled: preferences.blur, material: preferences.glassMaterial))
        .foregroundStyle(theme.text).preferredColorScheme(theme.isLight ? .light : .dark).tint(theme.accent)
        .disabled(workspace.inputBlockedByModal)
        .accessibilityHidden(workspace.inputBlockedByModal)
        .echoControls(theme)
        // App-owned panels keep NSApplication's Quit action available. A system
        // modal sheet can intercept it before the termination delegate runs.
        .overlay {
            if workspace.showSettings || workspace.editingTab != nil {
                GeometryReader { geometry in
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea().contentShape(Rectangle())
                        Group {
                            if workspace.showSettings {
                                SettingsView(preferences: preferences, providers: providers, usage: assistant.usage) {
                                    workspace.showSettings = false
                                    workspace.activeSession?.focus()
                                }.frame(width: min(760, geometry.size.width - 32), height: min(610, geometry.size.height - 32))
                            } else if let tab = workspace.editingTab {
                                TabSettingsView(tabID: tab.id, workspace: workspace, preferences: preferences) {
                                    workspace.editingTab = nil
                                    workspace.activeSession?.focus()
                                }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
                            .shadow(color: .black.opacity(0.3), radius: 30, y: 10)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .disabled(workspace.pendingClose != nil || workspace.pendingQuit)
        .overlay {
            if workspace.pendingClose != nil || workspace.pendingQuit {
                ZStack {
                    theme.base.opacity(0.55).ignoresSafeArea().contentShape(Rectangle())
                    VStack(alignment: .leading, spacing: 16) {
                        Text(workspace.pendingQuit ? "退出 EchoTerm？" : "结束正在运行的命令？").font(.system(size: 17, weight: .medium))
                        Text("关闭会结束相关终端会话和仍在执行的命令。").font(.system(size: 12)).foregroundStyle(theme.muted)
                        HStack {
                            Spacer()
                            Button("取消") {
                                workspace.pendingClose = nil
                                if workspace.pendingQuit { workspace.pendingQuit = false; NSApp.reply(toApplicationShouldTerminate: false) }
                                if !workspace.showSettings && workspace.editingTab == nil { workspace.activeSession?.focus() }
                            }.keyboardShortcut(.cancelAction).focusable().focused($confirmCancelFocused).focusEffectDisabled()
                            Button(workspace.pendingQuit ? "结束并退出" : "结束并关闭", role: .destructive) {
                                if workspace.pendingQuit { workspace.pendingQuit = false; NSApp.reply(toApplicationShouldTerminate: true) }
                                else if let ids = workspace.pendingClose { workspace.pendingClose = nil; for id in ids { workspace.closeSession(id, force: true) } }
                            }
                        }
                    }.padding(24).frame(width: 370).background(theme.base, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line)).shadow(color: .black.opacity(0.3), radius: 30)
                }.echoControls(theme).onAppear { confirmCancelFocused = true }
            }
        }
        .environment(\.echoAnimationEnabled, applicationActive)
        .onAppear { applicationActive = NSApp.isActive }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in applicationActive = false }
    }
    private var titlebar: some View {
        HStack(spacing: 15) {
            HStack(spacing: 8) {
                WindowDot(color: Color(hex: 0xFF6058), symbol: "xmark") { NSApp.keyWindow?.performClose(nil) }
                WindowDot(color: Color(hex: 0xFEBC2E), symbol: "minus") { NSApp.keyWindow?.miniaturize(nil) }
                WindowDot(color: Color(hex: 0x29C840), symbol: "arrow.up.left.and.arrow.down.right") { NSApp.keyWindow?.toggleFullScreen(nil) }
            }.padding(.leading, 17)
            Spacer()
            if let session = workspace.activeSession { SessionTitle(session: session, index: workspace.sessionIndex(session.id) ?? 1) }
            Spacer()
            IconButton("plus", help: "新建标签页  ⌘T") { workspace.addTab() }
            EchoMenuButton(items: { [
                .init(title: "左右分屏  ⌘D", icon: "rectangle.split.2x1") { workspace.split(vertical: true) },
                .init(title: "上下分屏  ⇧⌘D", icon: "rectangle.split.1x2") { workspace.split(vertical: false) },
                .init(title: preferences.verticalTabs ? "使用顶部标签页" : "使用左侧标签栏", icon: "sidebar.left") { preferences.verticalTabs.toggle() }
            ] }) { Image(systemName: "rectangle.split.2x1").font(.system(size: 12)).foregroundStyle(theme.muted).frame(width: 28, height: 27) }.help("分屏与标签页布局")
            Button { workspace.toggleAssistant() } label: {
                EchoAvatar(action: .idle, light: theme.isLight, ambient: true).frame(width: 26, height: 26)
                    .padding(2).background(workspace.assistantVisible ? theme.accent.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(.interaction, Rectangle())
            }.buttonStyle(.plain).help("Echo 对话与工作模式  ⌘J").accessibilityLabel("Echo 白熊助手")
            IconButton("magnifyingglass", help: "查找命令区块  ⌘F") { workspace.activeSession?.showSearch.toggle() }
            IconButton("slider.horizontal.3", help: "设置  ⌘,") { workspace.showSettings = true }.padding(.trailing, 11)
        }.frame(height: 40).background(WindowDragRegion())
    }
    private func sidebar(expanded: Bool, floating: Bool = false) -> some View {
        VStack(spacing: 0) {
            if expanded {
                HStack {
                    Text("标签页").font(.system(size: 10)).foregroundStyle(theme.muted)
                    Spacer()
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                            preferences.sidebarPinned.toggle()
                            sidebarExpanded = true
                        }
                    } label: {
                        Image(systemName: preferences.sidebarPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11)).foregroundStyle(preferences.sidebarPinned ? theme.accent : theme.muted)
                            .frame(width: 28, height: 26).contentShape(.interaction, Rectangle())
                    }.buttonStyle(.plain)
                        .help(preferences.sidebarPinned ? "取消固定侧栏" : "固定侧栏")
                        .accessibilityLabel(preferences.sidebarPinned ? "取消固定侧栏" : "固定侧栏")
                        .accessibilityAddTraits(preferences.sidebarPinned ? .isSelected : [])
                }.padding(.leading, 16).padding(.trailing, 7).padding(.top, 4)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 5) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        tabButton(tab, index: index, expanded: expanded)
                    }
                    Button { workspace.addTab() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "plus").frame(width: 26, height: 28)
                            if expanded { Text("新建标签页").font(.system(size: 11)); Spacer(minLength: 0) }
                        }.padding(.horizontal, expanded ? 9 : 4).padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(theme.muted).help("新建标签页  ⌘T").accessibilityLabel("新建标签页")
                }.padding(.horizontal, expanded ? 7 : 5).padding(.vertical, 8)
            }
        }.frame(width: expanded ? 196 : 44).frame(maxHeight: .infinity)
            .clipped()
            .background {
                if floating {
                    // A flyout needs to soften the transcript beneath it; pinned navigation
                    // shares the window background instead of stacking another opaque layer.
                    theme.base.opacity(preferences.opacity)
                        .background(WindowMaterial(enabled: preferences.blur, material: preferences.glassMaterial))
                } else {
                    theme.text.opacity(0.015 * preferences.opacity)
                }
            }
    }
    private func tabButton(_ tab: WorkspaceTab, index: Int, expanded: Bool) -> some View {
        Button {
            workspace.selectedTabID = tab.id
            workspace.activeSession?.focus()
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: tab.root.sessions.count > 1 ? "rectangle.split.2x1" : "terminal").font(.system(size: 13)).frame(width: 26, height: 28)
                    if !expanded && index > 0 { Text("\(index + 1)").font(.system(size: 7, weight: .medium, design: .monospaced)).padding(2).background(theme.base.opacity(preferences.opacity)).offset(x: 3, y: 1) }
                }.foregroundStyle(tab.id == workspace.selectedTabID ? theme.accent : theme.muted)
                if expanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Text(tab.defaultInputRoute.title + " · " + tab.defaultAssistantMode.title).font(.system(size: 9)).foregroundStyle(theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }.padding(.trailing, expanded ? 21 : 0).padding(.horizontal, expanded ? 9 : 4).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(index + 1) · \(tab.title)\n默认：\(tab.defaultInputRoute.title) · \(tab.defaultAssistantMode.title)" + (tab.namingError.map { "\nAI 命名：" + $0 } ?? "")).accessibilityLabel("标签页 \(index + 1)，\(tab.title)")
        .overlay(alignment: .trailing) {
            if expanded {
                Button { workspace.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 24, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(theme.muted).padding(.trailing, 3)
                    .opacity(hoveredTab == tab.id ? 1 : 0).allowsHitTesting(hoveredTab == tab.id)
                    .accessibilityHidden(hoveredTab != tab.id).accessibilityLabel("关闭标签页 \(index + 1)，\(tab.title)")
            }
        }
        .background(theme.accent.opacity(hoveredTab == tab.id ? 0.14 : tab.id == workspace.selectedTabID ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.accent.opacity(hoveredTab == tab.id ? 0.14 : 0)).allowsHitTesting(false))
        .onHover { inside in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil } } }
        .echoContextMenu(tabMenu(tab))
    }
    private func tabMenu(_ tab: WorkspaceTab) -> [EchoMenuItem] {
        [.init(title: "标签设置与重命名…", icon: "pawprint") { workspace.editingTab = tab }] +
        InputRoute.allCases.map { route in .init(title: "默认输入 · " + route.title, selected: route == tab.defaultInputRoute) { workspace.configureTab(tab.id, customTitle: tab.customTitle ?? "", input: route, assistant: tab.defaultAssistantMode) } } +
        AssistantMode.allCases.map { mode in .init(title: "默认 AI · " + mode.title, selected: mode == tab.defaultAssistantMode) { workspace.configureTab(tab.id, customTitle: tab.customTitle ?? "", input: tab.defaultInputRoute, assistant: mode) } } + [
            .init(title: "关闭标签页", icon: "xmark") { workspace.closeTab(tab.id) }
        ]
    }
    private var horizontalTabs: some View {
        HStack(spacing: 5) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(workspace.tabs) { tab in
                        HStack(spacing: 10) {
                            Button { workspace.selectedTabID = tab.id; workspace.activeSession?.focus() } label: { Label(tab.title, systemImage: "terminal").font(.system(size: 11)) }.buttonStyle(.plain)
                            Button { workspace.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8)).frame(width: 16, height: 18).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(theme.muted)
                                .opacity(hoveredTab == tab.id ? 1 : 0).allowsHitTesting(hoveredTab == tab.id).accessibilityHidden(hoveredTab != tab.id).accessibilityLabel("关闭标签页 \(tab.title)")
                        }.padding(.horizontal, 12).padding(.vertical, 7).background(theme.accent.opacity(hoveredTab == tab.id ? 0.14 : tab.id == workspace.selectedTabID ? 0.08 : 0)).clipShape(RoundedRectangle(cornerRadius: 5))
                            .onHover { inside in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil } } }
                            .echoContextMenu(tabMenu(tab))
                    }
                }
            }
        }.padding(.horizontal, 12).frame(height: 33)
    }
}

private struct SessionTitle: View {
    @ObservedObject var session: TerminalSession
    let index: Int
    var body: some View { Text("S\(index) · \(session.name) — \(session.shellName)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
}
struct PaneTree: View {
    let node: PaneNode
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    @ObservedObject var assistant: AssistantStore
    var body: some View {
        switch node {
        case .leaf(let session): TerminalPane(session: session, workspace: workspace, preferences: preferences, assistant: assistant)
        case .split(_, let vertical, let a, let b):
            if vertical {
                HSplitView { subtree(a); subtree(b) }
            } else {
                VSplitView { subtree(a); subtree(b) }
            }
        }
    }
    private func subtree(_ node: PaneNode) -> some View { AnyView(PaneTree(node: node, workspace: workspace, preferences: preferences, assistant: assistant)).frame(minWidth: 220, minHeight: 170) }
}

struct IconButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false
    init(_ icon: String, help: String, active: Bool = false, action: @escaping () -> Void) { self.icon = icon; self.help = help; self.active = active; self.action = action }
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .regular)).frame(width: 28, height: 27).background(hovering || active ? Color.primary.opacity(0.06) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(.interaction, Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(active ? Color.primary : Color.secondary).help(help).onHover { hovering = $0 }
    }
}
struct WindowDot: View {
    let color: Color; let symbol: String; let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) { Circle().fill(color.opacity(hover ? 1 : 0.85)).frame(width: 11, height: 11).overlay { if hover { Image(systemName: symbol).font(.system(size: 6, weight: .bold)).foregroundStyle(.black.opacity(0.65)) } } }.buttonStyle(.plain).onHover { hover = $0 }
    }
}
struct WindowDragRegion: NSViewRepresentable {
    class DragView: NSView { override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { window?.zoom(nil) } else { window?.performDrag(with: event) } } }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
