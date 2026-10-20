import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var providers: ProviderStore
    @ObservedObject var usage: AIUsageStore
    let dismiss: () -> Void
    @FocusState private var closeFocused: Bool
    @State private var page = "外观"
    private var theme: TerminalTheme { preferences.theme }
    var body: some View {
        VStack(spacing: 0) {
            HStack { EchoPixelDrawing(light: theme.isLight).frame(width: 28, height: 28); Text("EchoTerm 设置").font(.system(size: 14, weight: .semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.escape, modifiers: []).focusable().focused($closeFocused).focusEffectDisabled() }.padding(22)
            Rectangle().fill(theme.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach([("外观", "paintpalette"), ("标签页", "rectangle.3.group"), ("模型与助手", "pawprint"), ("用量统计", "chart.bar"), ("快捷键", "command"), ("关于", "info.circle")], id: \.0) { item in
                        Button { page = item.0 } label: { Label(item.0, systemImage: item.1).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(11).background(page == item.0 ? theme.accent.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 6)).contentShape(.interaction, Rectangle()) }.buttonStyle(.plain)
                    }
                    Spacer()
                    EchoAvatar(action: .idle, light: theme.isLight)
                        .frame(width: 84, height: 84).frame(maxWidth: .infinity).padding(.bottom, 12)
                }.padding(13).frame(width: 160)
                Rectangle().fill(theme.line).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 25) {
                        switch page {
                        case "外观": appearance
                        case "标签页": tabSettings
                        case "模型与助手": intelligence
                        case "用量统计": UsageSettingsView(usage: usage, theme: theme)
                        case "快捷键": shortcuts
                        default: about
                        }
                    }.padding(27).frame(maxWidth: .infinity, alignment: .leading)
                }.id(page)
            }
        }.background(theme.base).foregroundStyle(theme.text).preferredColorScheme(theme.isLight ? .light : .dark).tint(theme.accent).echoControls(theme)
            .onAppear { closeFocused = true }
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 25) {
            heading("外观", detail: "主题、窗口与字体")
            VStack(alignment: .leading, spacing: 11) {
                label("配色主题")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(TerminalTheme.allCases) { item in
                        Button { preferences.theme = item } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(item.muted.opacity(0.4)).frame(width: 4, height: 4) }; Spacer(); if preferences.theme == item { Image(systemName: "checkmark.circle.fill").foregroundStyle(item.accent) } }
                                Text("❯ echo hello").font(.system(size: 10, design: .monospaced)).foregroundStyle(item.accent)
                                Text(item.rawValue).font(.system(size: 11)).foregroundStyle(item.text)
                            }.padding(13).frame(maxWidth: .infinity).background(item.base).overlay(RoundedRectangle(cornerRadius: 8).stroke(preferences.theme == item ? item.accent.opacity(0.7) : theme.line)).clipShape(RoundedRectangle(cornerRadius: 8)).contentShape(.interaction, Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { label("背景不透明度"); Spacer(); Text("\(Int(preferences.opacity * 100))%").font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.muted) }
                EchoSlider(value: $preferences.opacity, range: 0.1...1, label: "背景不透明度")
                Toggle("窗口背景毛玻璃", isOn: $preferences.blur).toggleStyle(EchoToggleStyle()).controlSize(.small).font(.system(size: 12))
                if preferences.blur {
                    EchoSegments(selection: $preferences.glassMaterial, choices: GlassMaterial.allCases.map { .init(value: $0, title: $0.rawValue) }, label: "玻璃材质")
                    Text("材质由系统实时生成；不同材质的模糊与染色不同，不是固定像素半径。低不透明度时效果更明显。").font(.system(size: 10)).foregroundStyle(theme.muted)
                }
            }
            VStack(alignment: .leading, spacing: 13) {
                label("标签页布局")
                EchoSegments(selection: $preferences.verticalTabs, choices: [.init(value: true, title: "左侧边栏"), .init(value: false, title: "顶部标签页")], label: "标签页布局")
            }
            Text("鼠标悬停提亮区块，点击后进入稍暗的阅读状态；当前输入行始终在最新区块内。").font(.system(size: 10)).foregroundStyle(theme.muted)
            EchoLabeledChoice(title: "新会话的 Shell", selection: $preferences.shellChoice, choices: ShellChoice.allCases.map { .init(value: $0, title: $0.rawValue) })
            Text("Bash / Zsh 负责执行命令，界面使用统一的区块提示符。更改 Shell 对新标签页生效。").font(.system(size: 10)).foregroundStyle(theme.muted)
            EchoLabeledChoice(title: "终端字体", selection: $preferences.fontName, choices: [.init(value: "自动", title: "自动（优先 Nerd Font）")] + Preferences.fontFamilies.map { .init(value: $0, title: $0) })
            EchoStepper(title: "终端字号 · \(Int(preferences.fontSize)) pt", value: Binding(get: { Int(preferences.fontSize) }, set: { preferences.fontSize = Double($0) }), range: 10...20)
            Toggle("选中文本后自动复制", isOn: $preferences.copyOnSelection).toggleStyle(EchoToggleStyle()).controlSize(.small).font(.system(size: 12))
            Text("适用于终端输出、历史记录与 AI 回答；输入框不参与。关闭时仍可使用 ⌘C 或复制按钮。").font(.system(size: 10)).foregroundStyle(theme.muted)
        }
    }
    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                heading("模型与助手", detail: "API 直连，密钥保存在 macOS 钥匙串。")
                Spacer(minLength: 0)
                EchoAvatar(action: .idle, light: theme.isLight).frame(width: 55, height: 55)
            }
            Text("新标签页默认 AI 工作模式").font(.system(size: 11)).foregroundStyle(theme.muted)
            AssistantModeControl(preferences: preferences)
            Text(preferences.assistantMode.detail).font(.system(size: 11)).foregroundStyle(theme.muted)
            Toggle("流式显示回复", isOn: $preferences.streamReplies).toggleStyle(EchoToggleStyle()).controlSize(.small).font(.system(size: 12))
            if preferences.assistantMode == .autonomous {
                EchoStepper(title: "每轮最多执行 \(preferences.agentStepLimit) 条命令", value: $preferences.agentStepLimit, range: 1...24)
                EchoLabeledChoice(title: "单条命令时限", selection: $preferences.commandTimeout, choices: [.init(value: 30.0, title: "30 秒"), .init(value: 60.0, title: "1 分钟"), .init(value: 180.0, title: "3 分钟"), .init(value: 600.0, title: "10 分钟")])
                Text("命令在当前 Shell 中实际执行。停止按钮或 ⌘. 可中断本轮；重新提问才会继续。").font(.system(size: 10)).foregroundStyle(theme.muted)
            }
            Rectangle().fill(theme.line).frame(height: 1)
            Toggle("命令后的快速意图建议", isOn: $preferences.quickIntents).toggleStyle(EchoToggleStyle()).controlSize(.small).font(.system(size: 12))
            Text("每次手动提交命令后，发送该命令、目录与少量近期输出，做一次关闭思考的快速判断。只显示可点击的建议，不自动执行；关闭上下文后也会停止快判。").font(.system(size: 10)).foregroundStyle(theme.muted)
            if preferences.quickIntents {
                EchoLabeledChoice(title: "快速判断 Provider", selection: $preferences.quickProviderID, choices: [.init(value: "", title: "跟随当前 Provider")] + providers.configurations.map { .init(value: $0.id, title: $0.name) })
            }
            EchoLabeledChoice(title: "Provider", selection: $providers.selectedID, choices: providers.configurations.map { .init(value: $0.id, title: $0.name) })
            ProviderEditor(config: providers.selected, providers: providers, usage: usage).id(providers.selectedID)
            Rectangle().fill(theme.line).frame(height: 1)
            Toggle(isOn: $preferences.shareContext) { VStack(alignment: .leading, spacing: 5) { Text("附带终端上下文").font(.system(size: 12)); Text("提问时发送所有会话的区块概览，正文按需读取；查找历史优先使用内部区块工具。常见密钥格式会尝试脱敏。").font(.system(size: 10)).foregroundStyle(theme.muted) } }.toggleStyle(EchoToggleStyle()).controlSize(.small)
            Text("Codex 模型通过 Responses API 接入；Claude 通过 Messages API 接入。Codex CLI 和 Claude Code 可以直接在终端中运行，当前不接管它们的登录会话。").font(.system(size: 10)).lineSpacing(4).foregroundStyle(theme.muted)
        }
    }
    private var tabSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("标签页", detail: "命名规则与默认模式。右键标签可单独修改。")
            VStack(alignment: .leading, spacing: 10) {
                label("自动命名规则")
                EchoChoicePicker(selection: $preferences.tabNamingPolicy, choices: TabNamingPolicy.allCases.map { .init(value: $0, title: $0.title) }, label: "标签自动命名规则", small: false).frame(height: 26)
                Text("自动规则立即应用于未自定义名称的标签。路径取最新区块所在会话的目录；命令取所有分屏中最近执行的一条。自定义名称始终优先。").font(.system(size: 11)).foregroundStyle(theme.muted).lineSpacing(4)
                if preferences.tabNamingPolicy == .intelligence {
                    Text(preferences.shareContext ? "使用快速判断 Provider / 模型，关闭思考，根据最近问题、命令和少量输出生成简短名称。失败时保留现有名称。" : "上下文分享已关闭，AI 命名暂停；开启后再更新。")
                        .font(.system(size: 11)).foregroundStyle(theme.muted).lineSpacing(4)
                }
            }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 12) {
                label("新标签页默认值")
                HStack { Text("输入方式"); Spacer(); EchoChoicePicker(selection: $preferences.defaultInputRoute, choices: InputRoute.allCases.map { .init(value: $0, title: $0.title) }, label: "新标签默认输入方式", small: false).frame(width: 180, height: 26) }
                HStack { Text("AI 工作模式"); Spacer(); EchoChoicePicker(selection: $preferences.assistantMode, choices: AssistantMode.allCases.map { .init(value: $0, title: $0.title) }, label: "新标签默认 AI 工作模式", small: false).frame(width: 180, height: 26) }
                Text("这些默认值用于新标签；已有标签的设置独立保留。Block 可以临时覆盖，提交后下一块恢复标签默认值。").font(.system(size: 11)).foregroundStyle(theme.muted).lineSpacing(4)
            }.font(.system(size: 12))
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 23) {
            heading("快捷键", detail: "")
            ForEach([("接受灰字补全", "Tab"), ("切换补全 / 历史", "↑ / ↓"), ("强制执行命令", "⌘ ↵"), ("强制询问 Echo", "⌥ ↵"), ("新建标签页", "⌘ T"), ("关闭当前面板", "⌘ W"), ("左右分屏", "⌘ D"), ("上下分屏", "⇧ ⌘ D"), ("搜索命令与输出", "⌘ F"), ("清空已完成区块", "⌘ K"), ("回到当前输入", "⇧ ⌘ R"), ("显示 / 隐藏助手", "⌘ J"), ("停止助手当前任务", "⌘ ."), ("填入最近的 AI 建议", "⇧ ⌘ ↵"), ("切换标签页", "⇧ ⌘ [ / ]"), ("设置", "⌘ ,")], id: \.0) { item in
                HStack { Text(item.0).font(.system(size: 12)); Spacer(); Text(item.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.muted) }
            }
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 22) {
                EchoAvatar(action: .success, light: theme.isLight).frame(width: 98, height: 98)
                VStack(alignment: .leading, spacing: 14) {
                    heading("EchoTerm", detail: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · macOS 原生预览版")
                }
            }
            Text("SwiftUI · AppKit · SwiftTerm\n\n每个面板独立运行 Bash / Zsh。重启后不会恢复会话或历史输出。").font(.system(size: 12)).lineSpacing(7).foregroundStyle(theme.muted)
            Link("SwiftTerm · MIT License", destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!).font(.system(size: 11))
        }
    }
    private func label(_ title: String) -> some View { Text(title).font(.system(size: 12, weight: .medium)) }
    private func heading(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 9) { Text(title).font(.system(size: 20, weight: .medium)); if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(theme.muted).lineSpacing(4) } } }
}

struct ProviderEditor: View {
    @State var config: ProviderConfiguration
    @ObservedObject var providers: ProviderStore
    var usage: AIUsageStore?
    @State private var key = ""
    @State private var keyChanged = false
    @State private var status = ""
    @State private var testing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            EchoLabeledChoice(title: "接口协议", selection: $config.apiProtocol, choices: APIProtocol.allCases.map { .init(value: $0, title: $0.rawValue) })
            field("API Base URL", text: $config.endpoint, placeholder: "https://…/v1")
            field("模型 ID", text: $config.model, placeholder: "填写你的 Provider 支持的模型 ID")
            VStack(alignment: .leading, spacing: 6) { Text("API Key").font(.system(size: 10)).foregroundStyle(.secondary); SecureField("本地模型可留空", text: $key).textFieldStyle(EchoTextFieldStyle()).onChange(of: key) { _, _ in keyChanged = true } }
            EchoLabeledChoice(title: "思考强度", selection: $config.effort, choices: ReasoningEffort.allCases.map { .init(value: $0, title: $0.title) })
            Text(config.reasoningDescription).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).lineSpacing(3)
            DisclosureGroup("思考参数兼容方式") {
                EchoLabeledChoice(title: "兼容方式", selection: $config.reasoningStyle, choices: ReasoningAPI.allCases.map { .init(value: $0, title: $0.title) })
                Text("自定义网关或旧模型可手动指定；不支持参数的模型可选「模型默认」。").font(.system(size: 10)).foregroundStyle(.secondary)
            }.font(.system(size: 10))
            if config.apiProtocol == .chatCompletions {
                DisclosureGroup("流式用量兼容性") {
                    Toggle("请求流式 Token 用量", isOn: $config.includeStreamUsage).toggleStyle(EchoToggleStyle()).controlSize(.small)
                    Text("默认开启。如旧网关拒绝 stream_options 参数，可关闭后保存；用量未返回时会明确标注。").font(.system(size: 10)).foregroundStyle(.secondary)
                }.font(.system(size: 10))
            }
            field("快速判断模型 ID（可选）", text: $config.fastModelID, placeholder: "留空沿用当前模型；推荐填写快速、非推理模型")
            Text("快判使用这个 Provider 的地址与密钥，关闭思考，最多输出 512 tokens，8 秒超时。旧推理模型如果不支持关闭思考，请指定非推理模型。").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("保存配置") { save() }.controlSize(.small)
                Button(testing ? "连接中…" : "测试连接") { test() }.controlSize(.small).disabled(testing)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
            }
            if !status.isEmpty { Text(status).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }
        }.onAppear { key = Keychain.read(config.id); DispatchQueue.main.async { keyChanged = false } }
    }
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.system(size: 10)).foregroundStyle(.secondary); TextField(placeholder, text: text).textFieldStyle(EchoTextFieldStyle()).font(.system(size: 11, design: .monospaced)) } }
    @discardableResult private func save() -> Bool {
        do { if keyChanged { try Keychain.save(key, for: config.id); keyChanged = false }; providers.update(config); status = "已保存"; return true }
        catch { status = error.localizedDescription; return false }
    }
    private func test() {
        guard save() else { return }
        testing = true; status = "发送一条简短测试消息（不附带终端上下文）…"
        Task { @MainActor in
            defer { testing = false }
            do {
                let send = AIUsageRecorder.wrap({ request, update in
                    try await AIClient.send(config: request.config, key: key, messages: request.messages, context: "", onUpdate: update)
                }, store: usage)
                _ = try await send(.init(config: config, messages: [["role": "user", "content": "请只回复：连接成功。"]], context: "", mode: .answer, streaming: true, usageCategory: "连接测试")) { _ in }
                status = "连接成功，模型可以正常响应。"
            }
            catch { status = error.localizedDescription }
        }
    }
}
