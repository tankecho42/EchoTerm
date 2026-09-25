import SwiftUI

/// An app-owned bubble. Dismissing its presentation preserves the conversation,
/// unsent draft and any request already running in the terminal.
struct PersistentAssistantOverlay: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var assistant: AssistantStore
    @ObservedObject var preferences: Preferences
    @State private var origin: CGPoint?
    @State private var dragOffset = CGSize.zero
    var body: some View {
        GeometryReader { geometry in
            let width = min(340, max(260, geometry.size.width - 32))
            let panelHeight = min(560, geometry.size.height - 70)
            let initial = CGPoint(x: geometry.size.width - width - 18, y: 58)
            let base = origin ?? initial
            let point = CGPoint(x: max(12, min(geometry.size.width - width - 12, base.x + dragOffset.width)),
                                y: max(48, min(geometry.size.height - panelHeight - 12, base.y + dragOffset.height)))
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { workspace.minimizeAssistant() }
                    .accessibilityHidden(true)
                AssistantBubble(session: session, assistant: assistant, providers: assistant.providers, preferences: preferences, workspace: workspace,
                            width: width, maxBodyHeight: max(80, min(300, panelHeight - 250)),
                            move: { delta, finished in
                                if finished { origin = point; dragOffset = .zero }
                                else { if origin == nil { origin = point }; dragOffset = delta }
                            })
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .onTapGesture { } // Interior blank space belongs to the bubble.
                .offset(x: point.x, y: point.y)
                .onAppear { origin = point }
            }
        }
    }
}
