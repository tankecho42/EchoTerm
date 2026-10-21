#if DEBUG
import Foundation

/// Opt-in, local-only data for exercising the actual transcript layout.
@MainActor enum PerformanceFixture {
    static func install(session: TerminalSession, assistant: AssistantStore) {
        let longLine = String(repeating: "0123456789 中文 output / ", count: 5_000)
        let manyLines = (0..<1_200).map { "\($0) · fixture output " + String(repeating: "abcdefgh ", count: 6) }.joined(separator: "\n")
        let denseScrollFixture = ProcessInfo.processInfo.environment["ECHOTERM_SCROLL_DENSE_FIXTURE"] == "1"
        for index in 1...40 {
            if index % 8 == 0 {
                let text: String
                if denseScrollFixture && index == 32 {
                    text = "## 密集列表测试\n\n" + String(repeating: "- item\n", count: 8_000)
                } else if denseScrollFixture && index == 24 {
                    text = "| A | B |\n| --- | --- |\n" + String(repeating: "| one | two |\n", count: 2_000)
                } else if denseScrollFixture && index == 16 {
                    text = String(repeating: "long paragraph ", count: 6_000)
                } else {
                    text = "## 长内容测试 \(index)\n\n" + String(repeating: "这是一段 **压力测试** 文本。`echo ok`\n\n", count: 80)
                }
                let reply = ChatMessage(role: "assistant", text: text)
                assistant.conversations[session.id, default: []].append(reply)
                session.blocks.append(.init(command: "[测试数据] 解释第 \(index) 组结果", directory: "/tmp", output: reply.text, finishedAt: Date(), exitCode: 0, isDemo: true, assistantReplyID: reply.id, assistantMode: .answer))
            } else {
                session.blocks.append(.init(command: index == 39 ? "[测试数据] " + longLine : "[测试数据] printf output-\(index)", directory: "/tmp", output: index % 3 == 0 ? longLine : manyLines, finishedAt: Date(), exitCode: 0, isDemo: true))
            }
        }
    }
}
#endif
