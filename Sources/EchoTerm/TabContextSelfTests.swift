#if DEBUG
import Foundation

@MainActor enum TabContextSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        let suite = "EchoTerm.TabContext.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        preferences.shareContext = true; preferences.quickIntents = false; preferences.tabNamingPolicy = .intelligence
        providers.configurations = [.init(id: "title-context-local", name: "fixture", endpoint: "http://localhost/v1", model: "fixture", apiProtocol: .chatCompletions)]
        providers.selectedID = "title-context-local"
        let workspace = Workspace(); workspace.addTab(directory: "/tmp")
        defer { workspace.closeAll() }
        let session = workspace.activeSession!, tabID = workspace.tabs[0].id
        session.blocks = [.init(command: "excluded-title-marker", directory: "/tmp", exitCode: 0),
                          .init(command: "selected-title-marker", directory: "/tmp", exitCode: 0)]
        var contexts: [String] = []
        let coordinator = TabTitleCoordinator(workspace: workspace, preferences: preferences, providers: providers, debounce: 50_000_000) { request, _ in
            contexts.append(request.context)
            return .init(text: #"{"title":"上下文测试"}"#)
        }
        defer { coordinator.cancel(tabID) }
        let assistant = AssistantStore(providers: providers, preferences: preferences) { _, _ in .init(text: "unused") }
        coordinator.refresh(tabID)
        assistant.setContextStart(index: 2, for: session)
        try await wait { contexts.count == 1 }
        check(!contexts[0].contains("excluded-title-marker") && contexts[0].contains("selected-title-marker"),
              "Changing the context boundary retires a pending AI title and sends only selected Block content")
        assistant.setContextStart(blockID: nil, for: session)
        try await wait { contexts.count == 2 }
        check(contexts[1].contains("excluded-title-marker") && contexts[1].contains("selected-title-marker"),
              "Expanding the boundary refreshes optional AI naming through the normal activity callback")
        session.blocks.append(.init(command: "pending-title-marker", directory: "/tmp", exitCode: 0))
        coordinator.refresh(tabID)
        session.blocks.append(.init(command: "继续分析", directory: "/tmp", exitCode: 0,
                                    assistantReplyID: UUID(), assistantContinuation: true))
        assistant.setContextStart(index: 4, for: session)
        try await Task.sleep(nanoseconds: 100_000_000)
        check(contexts.count == 2,
              "Selecting a continuation-only range cancels pending naming instead of sending the broader old scope")
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw AIError.message("Tab context fixture timed out")
    }
}
#endif
