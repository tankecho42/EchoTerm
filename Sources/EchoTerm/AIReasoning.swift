import Foundation

enum AssistantMode: String, Codable, CaseIterable, Identifiable {
    case answer, autonomous
    var id: String { rawValue }
    var title: String { self == .answer ? "问答" : "自主操控" }
    var detail: String { self == .answer ? "回答问题、读取历史区块并按需跳转，不执行命令；快速意图建议可单独开关。" : "提问后在当前会话执行命令、读取输出并继续排查；可以随时停止。" }
}
enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case automatic, off, low, medium, high
    var id: String { rawValue }
    var title: String { switch self { case .automatic: return "模型默认"; case .off: return "关闭思考"; case .low: return "轻量 · 更快"; case .medium: return "均衡"; case .high: return "深入 · 更充分" } }
}
enum ReasoningAPI: String, Codable, CaseIterable, Identifiable {
    case automatic, openAI, thinkingSwitch, glm, claudeAdaptive, claudeBudget, unsupported
    var id: String { rawValue }
    var title: String { switch self {
    case .automatic: return "自动识别"
    case .openAI: return "OpenAI reasoning effort"
    case .thinkingSwitch: return "Thinking 开关（DeepSeek 等）"
    case .glm: return "智谱 GLM"
    case .claudeAdaptive: return "Claude adaptive + effort"
    case .claudeBudget: return "Claude thinking token budget"
    case .unsupported: return "不发送思考参数"
    } }
}
extension ProviderConfiguration {
    var resolvedReasoningStyle: ReasoningAPI {
        if reasoningStyle != .automatic { return reasoningStyle }
        let lower = model.lowercased(), host = URL(string: endpoint)?.host?.lowercased() ?? ""
        if apiProtocol == .anthropic {
            let legacy = ["3-7", "3.7", "4-0", "4-1", "4-5", "4.0", "4.1", "4.5", "sonnet-4-202", "opus-4-202"].contains { lower.contains($0) }
            return legacy ? .claudeBudget : .claudeAdaptive
        }
        if apiProtocol == .responses { return .openAI }
        if host == "api.deepseek.com" || lower.hasPrefix("deepseek") { return .thinkingSwitch }
        if host.hasSuffix(".bigmodel.cn") || lower.hasPrefix("glm-") { return .glm }
        if host == "api.openai.com" || lower.hasPrefix("gpt-") || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") { return .openAI }
        return .unsupported
    }
    var reasoningParameters: [String: Any] {
        guard effort != .automatic else { return [:] }
        switch resolvedReasoningStyle {
        case .openAI:
            let value = effort == .off ? "none" : effort.rawValue
            return apiProtocol == .responses ? ["reasoning": ["effort": value]] : ["reasoning_effort": value]
        case .thinkingSwitch, .glm:
            var result: [String: Any] = ["thinking": ["type": effort == .off ? "disabled" : "enabled"]]
            if resolvedReasoningStyle == .glm, effort != .off {
                let lower = model.lowercased()
                if lower.hasPrefix("glm-5.3") { result["reasoning_effort"] = effort == .medium ? "high" : effort.rawValue }
                else if lower.hasPrefix("glm-5.2") { result["reasoning_effort"] = effort == .high ? "max" : "high" }
            }
            return result
        case .claudeAdaptive:
            if effort == .off { return ["thinking": ["type": "disabled"]] }
            return ["thinking": ["type": "adaptive"], "output_config": ["effort": effort.rawValue]]
        case .claudeBudget:
            if effort == .off { return ["thinking": ["type": "disabled"]] }
            let budget = effort == .low ? 1024 : effort == .medium ? 4096 : 8192
            return ["thinking": ["type": "enabled", "budget_tokens": budget], "max_tokens": budget + 4096]
        case .automatic, .unsupported: return [:]
        }
    }
    var reasoningDescription: String {
        if effort == .automatic { return "由模型决定思考深度，不额外发送思考参数。强度影响取舍，不是固定的等待秒数。" }
        if resolvedReasoningStyle == .unsupported { return "尚未识别这个模型的思考接口。当前不发送参数，可在下方指定兼容方式。" }
        let data = try? JSONSerialization.data(withJSONObject: reasoningParameters, options: [.sortedKeys])
        let actual = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let onlySwitch = [.thinkingSwitch, .glm].contains(resolvedReasoningStyle) && reasoningParameters["reasoning_effort"] == nil
        return (onlySwitch ? "当前适配为思考开关，轻量 / 均衡 / 深入均开启思考。\n" : "具体档位仍需当前模型支持。\n") + "实际参数：" + actual
    }
}
