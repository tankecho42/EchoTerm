import SwiftUI

/// Fixed pitch keeps a short history compact. Long histories scroll inside the rail.
enum TimelineLayout {
    static func milestone(_ index: Int) -> String? { index >= 0 && (index + 1) % 10 == 0 ? String(index + 1) : nil }
    static let pitch: CGFloat = 17
    static let inset: CGFloat = 19
    static func contentHeight(_ count: Int) -> CGFloat { inset * 2 + CGFloat(max(0, count - 1)) * pitch }
    static func railHeight(_ count: Int, available: CGFloat) -> CGFloat { min(contentHeight(count), max(38, min(320, available - 24))) }
    static func y(_ index: Int) -> CGFloat { inset + CGFloat(index) * pitch }
    static func nearest(_ y: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(count - 1, max(0, Int(((y - inset) / pitch).rounded())))
    }
    static func proximity(_ distance: CGFloat) -> CGFloat { exp(-pow(distance / 31, 2)) }
    static func previewY(node: CGFloat, height: CGFloat) -> CGFloat { max(0, min(max(0, height - 110), node - 44)) }
}

private struct TimelineOffset: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

struct BlockTimeline: View {
    let blocks: [CommandBlock]
    let selectedID: UUID?
    let theme: TerminalTheme
    var previewWidth: CGFloat = 255
    let jump: (UUID) -> Void
    @State private var hoverY: CGFloat = 0
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var pointerY: CGFloat?
    @State private var contentOffset: CGFloat = 0
    @State private var keyboardIndex = 0
    @Namespace private var viewport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spring: Animation? { reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.82) }
    var body: some View {
        GeometryReader { geometry in
            let railHeight = TimelineLayout.railHeight(blocks.count, available: geometry.size.height)
            let top = (geometry.size.height - railHeight) / 2
            let hoveredIndex = isHovering ? TimelineLayout.nearest(hoverY, count: blocks.count) : nil
            ZStack(alignment: .topTrailing) {
                if !blocks.isEmpty {
                    ScrollViewReader { reader in
                        ScrollView(.vertical, showsIndicators: false) {
                            ZStack(alignment: .top) {
                                // Anchors keep the selected block in the compact scrolling rail.
                                VStack(spacing: 0) {
                                    ForEach(blocks) { block in Color.clear.frame(height: TimelineLayout.pitch).id(block.id) }
                                }.padding(.top, TimelineLayout.inset - TimelineLayout.pitch / 2).allowsHitTesting(false)
                                TimelineNodes(blocks: blocks, selectedID: selectedID, theme: theme, hover: hoverY, strength: isHovering ? 1 : 0, railScale: isExpanded ? 1 : 0.66)
                                    .frame(height: TimelineLayout.contentHeight(blocks.count))
                            }
                            .frame(width: 34, height: TimelineLayout.contentHeight(blocks.count))
                            .background(GeometryReader { content in Color.clear.preference(key: TimelineOffset.self, value: content.frame(in: .named(viewport)).minY) })
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in track(value.location.y) }
                                .onEnded { value in
                                    if let i = TimelineLayout.nearest(value.location.y, count: blocks.count) { keyboardIndex = i; jump(blocks[i].id) }
                                })
                        }
                        .onChange(of: selectedID) { _, id in
                            if let id, !isHovering { withAnimation(spring) { reader.scrollTo(id, anchor: .center) } }
                        }
                        .onAppear { if let selectedID { reader.scrollTo(selectedID, anchor: .center) } }
                    }
                    .frame(width: 34, height: railHeight)
                    .coordinateSpace(name: viewport)
                    .onPreferenceChange(TimelineOffset.self) { offset in
                        guard let offset else { return }
                        if abs(contentOffset - offset) > 0.5 { contentOffset = offset }
                        if let pointerY { hoverY = pointerY - offset }
                    }
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(theme.text.opacity(0.07)))
                    .shadow(color: .black.opacity(theme.isLight ? 0.05 : 0.15), radius: 9, y: 3)
                    // Transform the drawing without changing scroll geometry or node indices.
                    // A stable hover region avoids repeated enter/leave events while it expands.
                    .scaleEffect(isExpanded ? 1 : 0.66, anchor: .trailing)
                    .opacity(isExpanded ? 1 : 0.46)
                    .offset(x: isExpanded ? -5 : -1)
                    .frame(width: 44, height: railHeight, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if !inside { pointerY = nil }
                        withAnimation(spring) {
                            isExpanded = inside
                            if !inside { isHovering = false }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): pointerY = point.y; track(point.y - contentOffset)
                        case .ended:
                            pointerY = nil
                            withAnimation(spring) { isExpanded = false; isHovering = false }
                        }
                    }
                    .offset(y: top)
                    if let i = hoveredIndex, blocks.indices.contains(i) {
                        preview(blocks[i], index: i)
                            .frame(width: min(228, previewWidth), height: 110, alignment: .topLeading)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.text.opacity(0.09)))
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .offset(x: -46, y: TimelineLayout.previewY(node: top + (pointerY ?? contentOffset + TimelineLayout.y(i)), height: geometry.size.height))
                            .allowsHitTesting(false).transition(.opacity)
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topTrailing)
                .accessibilityElement(children: .ignore).accessibilityLabel("区块时间轴，\(blocks.count) 个区块")
                .accessibilityValue(blocks.indices.contains(keyboardIndex) ? String(blocks[keyboardIndex].command.prefix(180)) : "空")
                .accessibilityHint("上下调整跳转区块；在浮动轨道上滚动可查看更早的节点")
                .accessibilityAdjustableAction { direction in
                    guard !blocks.isEmpty else { return }
                    keyboardIndex = min(blocks.count - 1, max(0, keyboardIndex + (direction == .increment ? 1 : -1)))
                    jump(blocks[keyboardIndex].id)
                }
        }.frame(width: 44).padding(.vertical, 12)
    }
    private func track(_ y: CGFloat) {
        // On entry expand at the pointer; do not sweep a fictitious pointer down the rail.
        if !isHovering { hoverY = y }
        withAnimation(spring) { hoverY = y; isHovering = true; isExpanded = true }
    }
    private func preview(_ block: CommandBlock, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if block.isAI { EchoPaw().fill(theme.accent).frame(width: 9, height: 9) }
                Text(String(format: "%02d", index + 1))
                Text(block.isAI ? "ECHO" : "SHELL").tracking(0.8)
                Spacer(minLength: 2)
                Text(block.startedAt, style: .time)
            }.font(.system(size: 8, design: .monospaced)).foregroundStyle(theme.muted)
            Text(block.command).font(.system(size: 11, weight: .medium, design: block.isAI ? .default : .monospaced)).lineLimit(2)
            Text(block.output.isEmpty ? "点击查看这个区块 ↵" : String(block.output.prefix(160)))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.muted).lineLimit(2)
        }.padding(11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct TimelineNodes: View, Animatable {
    let blocks: [CommandBlock]
    let selectedID: UUID?
    let theme: TerminalTheme
    var hover: CGFloat
    var strength: CGFloat
    var railScale: CGFloat
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { .init(.init(hover, strength), railScale) }
        set { hover = newValue.first.first; strength = newValue.first.second; railScale = newValue.second }
    }
    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2
            var track = Path(); track.move(to: CGPoint(x: cx, y: TimelineLayout.inset)); track.addLine(to: CGPoint(x: cx, y: size.height - TimelineLayout.inset))
            context.stroke(track, with: .color(theme.text.opacity(0.06)), lineWidth: 1)
            for (i, block) in blocks.enumerated() {
                let cy = TimelineLayout.y(i), proximity = TimelineLayout.proximity(hover - cy) * min(1, max(0, strength))
                let selected = selectedID == block.id
                let diameter = (selected ? 6.5 : 5) + proximity * 7
                let center = cx - proximity * 2
                let color = block.marker?.color(light: theme.isLight) ?? theme.muted
                if let label = TimelineLayout.milestone(i) {
                    // Milestone numbers remain readable when the surrounding rail contracts.
                    let scale = max(0.66, railScale)
                    let width: CGFloat = min(30, (label.count > 2 ? 23 : 19) / scale) + proximity * 3
                    let height: CGFloat = 12 / scale + proximity * 2
                    let rect = CGRect(x: center - width / 2, y: cy - height / 2, width: width, height: height)
                    let node = Path(roundedRect: rect, cornerRadius: 4)
                    context.fill(node, with: .color(theme.base))
                    context.fill(node, with: .color(color.opacity(selected ? 0.2 : 0.09)))
                    context.stroke(node, with: .color(color.opacity(selected ? 0.7 : 0.28 + proximity * 0.4)), lineWidth: 0.7)
                    context.draw(Text(label).font(.system(size: 8 / scale + proximity, weight: .medium, design: .monospaced)).foregroundColor(selected ? theme.accent : theme.text.opacity(0.8)), at: CGPoint(x: center, y: cy))
                } else {
                    let rect = CGRect(x: center - diameter / 2, y: cy - diameter / 2, width: diameter, height: diameter)
                    let node = block.isAI ? Path(roundedRect: rect, cornerRadius: diameter * 0.3) : Path(ellipseIn: rect)
                    context.fill(node, with: .color(color.opacity(selected ? 1 : 0.42 + proximity * 0.58)))
                    if selected { context.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(color.opacity(0.35)), lineWidth: 1) }
                }
            }
        }
    }
}
