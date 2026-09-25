import SwiftUI
import AppKit

enum TabNamingPolicy: String, CaseIterable, Identifiable {
    case directory, command, intelligence
    var id: String { rawValue }
    var title: String { switch self { case .directory: return "最新区块的路径"; case .command: return "最近执行的命令"; case .intelligence: return "AI 概括会话" } }
}

struct TabSettingsView: View {
    let tabID: UUID
    @ObservedObject var workspace: Workspace
    @ObservedObject var preferences: Preferences
    let dismiss: () -> Void
    @State private var customName = ""
    @State private var inputMode: InputRoute = .automatic
    @State private var aiMode: AssistantMode = .answer
    @FocusState private var nameFocused: Bool
    private var tab: WorkspaceTab? { workspace.tabs.first { $0.id == tabID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack { EchoPaw().fill(preferences.theme.accent).frame(width: 18, height: 18); Text("标签页设置").font(.system(size: 17, weight: .semibold)); Spacer(); Text(tab?.title ?? "").font(.system(size: 11)).foregroundStyle(preferences.theme.muted).lineLimit(1) }
            VStack(alignment: .leading, spacing: 9) {
                Text("自定义名称").font(.system(size: 12, weight: .medium))
                TextField("留空，使用自动命名", text: $customName).textFieldStyle(EchoTextFieldStyle()).focused($nameFocused)
                Text("留空时按设置中的「\(preferences.tabNamingPolicy.title)」更新；填写名称后会固定使用。").font(.system(size: 10)).foregroundStyle(preferences.theme.muted)
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 12) {
                Text("新 Block 的默认模式").font(.system(size: 12, weight: .medium))
                HStack { Text("输入方式"); Spacer(); EchoChoicePicker(selection: $inputMode, choices: InputRoute.allCases.map { .init(value: $0, title: $0.title) }, label: "标签默认输入方式", small: false).frame(width: 180) }
                HStack { Text("AI 工作模式"); Spacer(); EchoChoicePicker(selection: $aiMode, choices: AssistantMode.allCases.map { .init(value: $0, title: $0.title) }, label: "标签默认 AI 工作模式", small: false).frame(width: 180) }
                Text("同一标签的分屏共用这些默认值。Block 内的选择仅对本次输入生效，运行中的任务保持原模式。").font(.system(size: 10)).foregroundStyle(preferences.theme.muted).lineSpacing(3)
            }.font(.system(size: 12))
            HStack {
                Button("恢复自动命名") { customName = "" }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    workspace.configureTab(tabID, customTitle: customName, input: inputMode, assistant: aiMode)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 455).background(preferences.theme.base).foregroundStyle(preferences.theme.text).echoControls(preferences.theme)
            .onAppear { customName = tab?.customTitle ?? ""; inputMode = tab?.defaultInputRoute ?? .automatic; aiMode = tab?.defaultAssistantMode ?? .answer; nameFocused = true }
    }
}
