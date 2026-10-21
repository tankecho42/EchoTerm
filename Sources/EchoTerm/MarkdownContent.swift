import SwiftUI
import AppKit

enum MarkdownPiece: Equatable, Sendable {
    case paragraph(String), heading(Int, String), code(String, String), quote(String), item(String, String), rule, table([[String]])
}
enum MarkdownBlocks {
    static func parse(_ markdown: String) -> [MarkdownPiece] {
        let lines = markdown.components(separatedBy: .newlines)
        var pieces: [MarkdownPiece] = [], paragraph: [String] = [], i = 0
        func flush() { if !paragraph.isEmpty { pieces.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] } }
        func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
            return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while i < lines.count {
            let line = lines[i], trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush(); let fence = String(trimmed.prefix(3)), language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1; var code: [String] = []
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(lines[i]); i += 1 }
                pieces.append(.code(language, code.joined(separator: "\n"))); if i < lines.count { i += 1 }; continue
            }
            if i + 1 < lines.count, line.contains("|"), cells(lines[i + 1]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }), cells(lines[i + 1]).count > 1 {
                flush(); var rows = [cells(line)]; i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { rows.append(cells(lines[i])); i += 1 }
                pieces.append(.table(rows)); continue
            }
            if trimmed.isEmpty { flush() }
            else if ["---", "***", "___"].contains(trimmed) { flush(); pieces.append(.rule) }
            else if let match = trimmed.range(of: #"^#{1,6} "#, options: .regularExpression) { flush(); pieces.append(.heading(trimmed[match].count - 1, String(trimmed[match.upperBound...]))) }
            else if trimmed.hasPrefix("> ") { flush(); pieces.append(.quote(String(trimmed.dropFirst(2)))) }
            else if let match = trimmed.range(of: #"^(?:[-*+] |[0-9]+[.)] )"#, options: .regularExpression) {
                flush(); let prefix = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
                pieces.append(.item(prefix.first?.isNumber == true ? prefix : "•", String(trimmed[match.upperBound...])))
            } else { paragraph.append(line) }
            i += 1
        }
        flush(); return pieces
    }
}

enum MarkdownRenderPlan: Sendable {
    case rich([MarkdownPiece]), viewport
}

/// Bound the native view tree as well as the source size. A short Markdown
/// source can still contain thousands of list items or table cells.
enum MarkdownRenderPolicy {
    static let maximumSourceBytes = 100_000
    static let maximumRichComponents = 256
    static let maximumInlineBytes = 8_192
    static let maximumInlineLines = 64

    static func plan(for source: String) -> MarkdownRenderPlan {
        guard !requiresViewportBeforeParsing(source) else { return .viewport }
        let pieces = MarkdownBlocks.parse(source)
        guard pieces.count <= maximumRichComponents else { return .viewport }
        var components = 0
        for piece in pieces {
            switch piece {
            case .paragraph(let text), .heading(_, let text), .quote(let text), .item(_, let text):
                guard inlineFits(text) else { return .viewport }
                components += 1
            case .code:
                // Code already uses its own bounded viewport when large.
                components += 1
            case .table(let rows):
                for row in rows {
                    for cell in row {
                        guard inlineFits(cell) else { return .viewport }
                        components += 1
                        if components > maximumRichComponents { return .viewport }
                    }
                }
            case .rule: break
            }
            if components > maximumRichComponents { return .viewport }
        }
        return .rich(pieces)
    }
    private static func inlineFits(_ text: String) -> Bool {
        text.utf8.count <= maximumInlineBytes && text.lazy.filter { $0.isNewline }.prefix(maximumInlineLines).count < maximumInlineLines
    }
    private static func requiresViewportBeforeParsing(_ source: String) -> Bool {
        guard source.utf8.count <= maximumSourceBytes else { return true }
        var fence: String?, outsideLines = 0, components = 0
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if trimmed.hasPrefix(current) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3)); components += 1
            } else if !trimmed.isEmpty {
                outsideLines += 1
                // Conservatively count possible table cells before constructing
                // row arrays; exact parsed component counts are checked above.
                components += trimmed.contains("|") ? trimmed.split(separator: "|", omittingEmptySubsequences: true).count : 1
            }
            if outsideLines > maximumRichComponents || components > maximumRichComponents { return true }
        }
        return false
    }
}

/// Serial planning prevents detached parse jobs accumulating while streamed
/// text changes. Obsolete queued tasks stop before parsing or publishing.
private actor MarkdownRenderPlanner {
    static let shared = MarkdownRenderPlanner()
    func plan(for source: String) -> MarkdownRenderPlan? {
        guard !Task.isCancelled else { return nil }
        let plan = MarkdownRenderPolicy.plan(for: source)
        return Task.isCancelled ? nil : plan
    }
}

struct MarkdownContent: View {
    let text: String
    let theme: TerminalTheme
    var fontSize: CGFloat = 13
    var insertCommand: ((String) -> Void)? = nil
    var copyOnSelection = false
    var onClick: (() -> Void)? = nil
    var isStreaming = false
    @State private var plan: MarkdownRenderPlan = .rich([])
    private var pieces: [MarkdownPiece] { if case .rich(let pieces) = plan { return pieces }; return [] }
    private var usesViewport: Bool {
        if case .viewport = plan { return true }
        return text.utf8.count > MarkdownRenderPolicy.maximumSourceBytes
    }
    private func inline(_ text: String, size: CGFloat? = nil, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> SelectableText {
        SelectableText(text: text, font: .systemFont(ofSize: size ?? fontSize, weight: weight), color: color ?? NSColor(theme.text),
                       copyOnSelection: copyOnSelection, label: "AI 回答", lineSpacing: 4, markdown: true, linkColor: NSColor(theme.accent), onClick: onClick)
    }
    var body: some View {
        Group {
            if usesViewport {
                VStack(alignment: .leading, spacing: 8) {
                    Text("较长或密集的回复 · 完整内容可滚动、选择和复制").font(.system(size: 10)).foregroundStyle(theme.muted)
                    LongTextView(text: text, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular), color: NSColor(theme.text), label: "长回复原文", copyOnSelection: copyOnSelection, followOutput: isStreaming, onClick: onClick).frame(height: 360)
                }
            } else { rendered }
        }.task(id: text) {
            let source = text
            if let next = await MarkdownRenderPlanner.shared.plan(for: source), !Task.isCancelled { plan = next }
        }
    }
    private var rendered: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .paragraph(let text): inline(text)
                case .heading(let level, let text): inline(text, size: fontSize + CGFloat(max(1, 5 - level)), weight: .semibold).padding(.top, 5)
                case .quote(let text): HStack(alignment: .top, spacing: 10) { RoundedRectangle(cornerRadius: 2).fill(theme.accent.opacity(0.55)).frame(width: 3); inline(text, color: NSColor(theme.muted)).frame(maxWidth: .infinity, alignment: .leading) }.fixedSize(horizontal: false, vertical: true)
                case .item(let marker, let text): HStack(alignment: .top, spacing: 8) { Text(marker).foregroundStyle(theme.muted).frame(minWidth: 13); inline(text).frame(maxWidth: .infinity, alignment: .leading) }
                case .rule: Rectangle().fill(theme.line).frame(height: 1).padding(.vertical, 4)
                case .code(let language, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(language.isEmpty ? "code" : language).font(.system(size: 9, design: .monospaced)).foregroundStyle(theme.muted)
                            Spacer()
                            if ["sh", "bash", "zsh", "shell", "console"].contains(language.lowercased()), let insertCommand {
                                Button("填入终端") { insertCommand(code) }.help("填入输入区，确认后执行")
                            }
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) } label: { Label("复制", systemImage: "doc.on.doc") }
                        }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(theme.muted).padding(.horizontal, 12).padding(.vertical, 8)
                        Rectangle().fill(theme.line).frame(height: 1)
                        if TextLayoutPolicy.needsViewport(code) {
                            LongTextView(text: code, font: .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular), color: NSColor(theme.text), label: "完整代码", copyOnSelection: copyOnSelection, onClick: onClick).frame(height: 250).padding(12)
                        } else {
                            ScrollView(.horizontal) { SelectableText(text: code, font: .monospacedSystemFont(ofSize: fontSize - 1, weight: .regular), color: NSColor(theme.text), copyOnSelection: copyOnSelection, label: "代码", lineSpacing: 4, onClick: onClick).fixedSize(horizontal: true, vertical: true).padding(12) }
                        }
                    }.background(theme.text.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.line))
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, cell in inline(cell, weight: index == 0 ? .semibold : .regular).frame(minWidth: 60, alignment: .leading) } }
                                if index == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                            }
                        }.padding(10)
                    }.background(theme.text.opacity(0.025)).clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }
        }.font(.system(size: fontSize)).foregroundStyle(theme.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).tint(theme.accent)
            .environment(\.openURL, OpenURLAction { url in
                guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return .discarded }
                return .systemAction
            })
    }
}
