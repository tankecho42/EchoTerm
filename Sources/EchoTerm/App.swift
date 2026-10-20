import AppKit
import SwiftUI

@main struct EchoTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建标签页") { delegate.workspace.addTab() }.keyboardShortcut("t")
                Button("关闭当前面板") { if let session = delegate.workspace.activeSession { delegate.workspace.closeSession(session.id) } }.keyboardShortcut("w")
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { delegate.workspace.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("终端") {
                Button("左右分屏") { delegate.workspace.split(vertical: true) }.keyboardShortcut("d")
                Button("上下分屏") { delegate.workspace.split(vertical: false) }.keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("搜索区块") { delegate.workspace.activeSession?.showSearch.toggle() }.keyboardShortcut("f")
                Button("清空已完成区块") { delegate.workspace.activeSession?.clear() }.keyboardShortcut("k")
                Button("回到当前输入") { if let session = delegate.workspace.activeSession { delegate.workspace.focusCurrentInput(sessionID: session.id) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("下一个标签页") { delegate.workspace.nextTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("上一个标签页") { delegate.workspace.nextTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
            CommandMenu("Echo") {
                Button("显示 / 隐藏助手") { delegate.workspace.toggleAssistant() }.keyboardShortcut("j")
                Button("停止助手当前任务") { if let session = ((delegate.workspace.assistantVisible ? delegate.workspace.assistantSession : nil) ?? delegate.workspace.activeSession) { delegate.assistant.cancel(session: session) } }.keyboardShortcut(".")
                Button("采用最近的命令建议") { if let session = delegate.workspace.activeSession { delegate.assistant.useLatest(session: session) } }.keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let preferences = Preferences()
    let providers = ProviderStore()
    let workspace = Workspace()
    let usage = AIUsageStore(fileURL: AIUsageStore.defaultURL)
    lazy var assistant = AssistantStore(providers: providers, preferences: preferences, usage: usage)
    var tabTitles: TabTitleCoordinator?
    var commandInputRouter: WindowCommandInputRouter?
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--self-test-selection") {
            Task { @MainActor in
                var failures = 0
                await SelectionCopySelfTests.run { passed, name in
                    print("\(passed ? "PASS" : "FAIL") \(name)")
                    if !passed { failures += 1 }
                }
                exit(failures == 0 ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in exit(await SelfTests.run() ? 0 : 1) }
            return
        }
        #endif
        NSApplication.shared.setActivationPolicy(.regular)
        assistant.workspace = workspace
        workspace.preferredShell = { [weak self] in self?.preferences.shellChoice.executable ?? ShellChoice.system.executable }
        workspace.preferredInputRoute = { [weak self] in self?.preferences.defaultInputRoute ?? .automatic }
        workspace.preferredAssistantMode = { [weak self] in self?.preferences.assistantMode ?? .answer }
        tabTitles = TabTitleCoordinator(workspace: workspace, preferences: preferences, providers: providers, usage: usage)
        workspace.configureSession = { [weak self] session in
            session.usesBlockEditor = true
            session.onClose = { [weak self, weak session] in guard let session else { return }; self?.assistant.close(session: session) }
            session.onComplete = { [weak self, weak session] block in guard let session else { return }; self?.assistant.didComplete(block, session: session) }
            session.onExecute = { [weak self, weak session] command in guard let session else { return }; self?.assistant.didExecute(command, session: session) }
            session.terminal.onFocus = { [weak self, weak session] in guard let session else { return }; self?.workspace.selectSession(session.id) }
        }
        let isDemo = CommandLine.arguments.contains("--demo")
        workspace.addTab(directory: isDemo ? FileManager.default.currentDirectoryPath : nil)
        #if DEBUG
        if Bundle.main.bundleIdentifier?.hasPrefix("app.echoterm.qa.") == true, UserDefaults.standard.bool(forKey: "performanceFixture"), let session = workspace.activeSession {
            PerformanceFixture.install(session: session, assistant: assistant)
        }
        if Bundle.main.bundleIdentifier?.hasPrefix("app.echoterm.qa.") == true, UserDefaults.standard.bool(forKey: "blockToolsFixture") {
            let firstID = workspace.activeSession!.id
            for index in 1...35 { workspace.activeSession!.blocks.append(.init(command: "printf 'navigation fixture \(index)\\n'", directory: "/tmp", output: "[本地测试记录] Block \(index)\nstatus: completed\nresult: navigation-\(index)", finishedAt: Date(), exitCode: 0)) }
            workspace.addTab(directory: "/tmp")
            for index in 1...15 { workspace.activeSession!.blocks.append(.init(command: "echo second-session-\(index)", directory: "/tmp", output: "[本地测试记录] Session 2 · Block \(index)", finishedAt: Date(), exitCode: 0)) }
            workspace.revealSession(firstID)
        }
        #endif
        if isDemo, let session = workspace.activeSession {
            workspace.presentAssistant(for: session.id)
            assistant.conversations[session.id] = [.init(role: "assistant", text: "这是界面演示，尚未连接模型。建议会显示在这里，填入后仍由你决定是否执行。", suggestions: [.init(command: "git diff --stat", explanation: "快速查看当前工作区的改动范围。", risk: "read")])]
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "EchoTerm"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.toolbar = nil; window.isOpaque = false; window.backgroundColor = .clear
        window.minSize = NSSize(width: 880, height: 560)
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: WorkspaceView(workspace: workspace, preferences: preferences, providers: providers, assistant: assistant).ignoresSafeArea())
        commandInputRouter = WindowCommandInputRouter(window: window, workspace: workspace)
        window.delegate = self; window.setFrameAutosaveName("EchoTerm.main")
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = workspace.tabs.flatMap { $0.root.sessions }.filter(\.running)
        guard !running.isEmpty else { return .terminateNow }
        workspace.pendingQuit = true
        window.makeKeyAndOrderFront(nil)
        return .terminateLater
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationWillTerminate(_ notification: Notification) { workspace.closeAll() }
}
