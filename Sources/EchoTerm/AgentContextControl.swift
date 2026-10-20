import SwiftUI

/// Presentation uses the same request selection that supplies the model payload.
struct AgentContextDisplay {
    let selection: AgentContextSelection
    let firstBlockNumber: Int
    let lastBlockNumber: Int
    init(selection: AgentContextSelection, blocks: [CommandBlock]) {
        self.selection = selection
        firstBlockNumber = selection.firstBlockID.flatMap { id in blocks.firstIndex { $0.id == id }.map { $0 + 1 } } ?? selection.startIndex1
        lastBlockNumber = selection.lastBlockID.flatMap { id in blocks.firstIndex { $0.id == id }.map { $0 + 1 } } ?? selection.endIndex1
    }
    var rangeLabel: String {
        guard selection.selectedCount > 0 else { return "暂无历史 Block" }
        return firstBlockNumber == lastBlockNumber ? "Block \(firstBlockNumber)" : "Block \(firstBlockNumber)–\(lastBlockNumber)"
    }
    var tokenLabel: String {
        let count = selection.approximateTokens
        return count >= 1_000 ? String(format: "≈ %.1fk tokens", Double(count) / 1_000) : "≈ \(count) tokens"
    }
    var canAdjust: Bool { selection.isSharingEnabled && !selection.isFrozen && selection.eligibleCount > 0 }
    var canExpand: Bool { canAdjust && selection.startEligibleIndex1 > 1 }
    var canShrink: Bool { canAdjust && selection.startEligibleIndex1 < selection.eligibleCount }
    func timelineIndex(forEligiblePosition position: Int) -> Int? {
        guard selection.availableIndices.indices.contains(position - 1) else { return nil }
        return selection.availableIndices[position - 1]
    }
    static let estimateHelp = "首次请求附带的上下文估算，非模型实际计费；不含系统提示、工具定义及后续工具结果。"
}

struct AgentContextControl: View {
    let display: AgentContextDisplay
    let theme: TerminalTheme
    var enabled = true
    let setStart: (Int) -> Void
    let shift: (Int) -> Void
    let openSettings: () -> Void
    @State private var presented = false
    private var selection: AgentContextSelection { display.selection }
    var body: some View {
        Button { presented.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: selection.isSharingEnabled ? "rectangle.stack" : "lock")
                    Text(selection.isSharingEnabled ? "上下文 · " + display.rangeLabel : "不附带终端内容")
                    Text(display.tokenLabel).foregroundStyle(theme.muted)
                    if selection.isFrozen { Image(systemName: "lock.fill").font(.system(size: 8)) }
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                HStack(spacing: 5) {
                    Image(systemName: selection.isSharingEnabled ? "rectangle.stack" : "lock")
                    Text(selection.isSharingEnabled ? display.rangeLabel : "上下文已关闭")
                    Text(display.tokenLabel).foregroundStyle(theme.muted)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: selection.isSharingEnabled ? "rectangle.stack" : "lock")
                        Text(selection.isSharingEnabled ? display.rangeLabel : "上下文已关闭").lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                    Text(display.tokenLabel).foregroundStyle(theme.muted)
                }
            }.font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.accent)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).disabled(!enabled)
            .help(AgentContextDisplay.estimateHelp)
            .accessibilityLabel("当前会话 Agent 上下文")
            .accessibilityValue((selection.isSharingEnabled ? display.rangeLabel : "不附带终端内容") + "，" + display.tokenLabel + (selection.isFrozen ? "，本轮已固定" : ""))
            .popover(isPresented: $presented, arrowEdge: .bottom) { popover }
            .onChange(of: enabled) { _, allowed in if !allowed { presented = false } }
    }
    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent 上下文").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if selection.isFrozen { Label("本轮已固定", systemImage: "lock.fill").font(.system(size: 9)).foregroundStyle(theme.muted) }
            }
            if !selection.isSharingEnabled {
                Text("当前不附带终端内容。开启后，可选择从哪个 Block 开始附带上下文。")
                    .font(.system(size: 11)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                Button("打开上下文设置") { presented = false; openSettings() }.buttonStyle(EchoButtonStyle())
            } else {
                HStack {
                    Text(display.rangeLabel).font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 8)
                    Text(display.tokenLabel).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.accent)
                }.monospacedDigit()
                Text(selection.isFrozen ? "本轮使用已固定的范围。完成后可调整下一次请求。" : "从所选 Block 开始，之后的历史区块会纳入当前 Agent 上下文。")
                    .font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                if selection.eligibleCount > 1 {
                    Slider(value: Binding(get: { Double(selection.startEligibleIndex1) }, set: {
                        if let index = display.timelineIndex(forEligiblePosition: Int($0.rounded())) { setStart(index) }
                    }),
                           in: 1...Double(selection.eligibleCount), step: 1)
                        .disabled(!enabled || !display.canAdjust)
                        .accessibilityLabel("最早包含的 Block")
                        .accessibilityValue("\(display.rangeLabel)，共 \(selection.selectedCount) 个 Block，\(display.tokenLabel)")
                    HStack {
                        Text("更早 · 更多上下文")
                        Spacer()
                        Text("更近 · 更少上下文")
                    }.font(.system(size: 9)).foregroundStyle(theme.muted)
                } else {
                    Text(selection.eligibleCount == 0 ? "当前还没有可附带的历史 Block。" : "当前只有一个可附带的 Block。")
                        .font(.system(size: 10)).foregroundStyle(theme.muted)
                }
                HStack(spacing: 12) {
                    Button { shift(-1) } label: { Label("扩大", systemImage: "arrow.up") }
                        .disabled(!enabled || !display.canExpand).accessibilityLabel("向上扩大 Agent 上下文一个 Block")
                    Button { shift(1) } label: { Label("缩小", systemImage: "arrow.down") }
                        .disabled(!enabled || !display.canShrink).accessibilityLabel("向下缩小 Agent 上下文一个 Block")
                    Spacer(minLength: 0)
                    Text("\(selection.selectedCount) 个 Block").foregroundStyle(theme.muted)
                }.font(.system(size: 10)).buttonStyle(EchoButtonStyle())
                if selection.wasClipped {
                    Text("内容较长，已截取；需要更多内容时可按需读取。")
                        .font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("约数，非计费；仅首次请求所附内容，工具调用后可能增加。")
                .font(.system(size: 9)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                .help(AgentContextDisplay.estimateHelp)
        }.padding(15).frame(width: 300).foregroundStyle(theme.text).background(theme.base)
            .onExitCommand { presented = false }
    }
}

struct AgentContextBoundary: View {
    let display: AgentContextDisplay
    let theme: TerminalTheme
    var enabled = true
    let shift: (Int) -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { identity; Spacer(minLength: 4); details; arrows }
            VStack(alignment: .leading, spacing: 6) {
                identity
                HStack(spacing: 8) { details; Spacer(minLength: 0); arrows }
            }
            VStack(alignment: .leading, spacing: 5) {
                identity
                Text(display.rangeLabel).foregroundStyle(theme.muted)
                HStack { Text(display.tokenLabel).foregroundStyle(theme.muted); Spacer(minLength: 0); arrows }
            }
        }.font(.system(size: 9)).foregroundStyle(theme.accent).monospacedDigit()
            .padding(.horizontal, 13).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.accent.opacity(0.06))
            .overlay(alignment: .top) { Rectangle().fill(theme.accent.opacity(0.25)).frame(height: 1) }
            .accessibilityElement(children: .contain).accessibilityLabel("Agent 上下文起始边界")
    }
    private var identity: some View {
        Label(display.selection.isFrozen ? "本轮首次请求从此开始" : "当前 Agent 包含下方 Block", systemImage: "arrow.down.to.line")
            .fixedSize(horizontal: false, vertical: true)
    }
    private var details: some View {
        Text(display.rangeLabel + " · " + display.tokenLabel).foregroundStyle(theme.muted)
            .fixedSize(horizontal: true, vertical: false).help(AgentContextDisplay.estimateHelp)
    }
    private var arrows: some View {
        HStack(spacing: 9) {
            Button { shift(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(!enabled || !display.canExpand).help("包含更早的一个 Block")
                .accessibilityLabel("向上扩大 Agent 上下文一个 Block")
            Button { shift(1) } label: { Image(systemName: "chevron.down") }
                .disabled(!enabled || !display.canShrink).help("不再包含当前最早的 Block")
                .accessibilityLabel("向下缩小 Agent 上下文一个 Block")
        }.buttonStyle(.plain)
    }
}
