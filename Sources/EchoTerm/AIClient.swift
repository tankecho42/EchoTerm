import Foundation
import Security

enum APIProtocol: String, Codable, CaseIterable, Identifiable {
    case responses = "OpenAI Responses"
    case chatCompletions = "OpenAI Compatible"
    case anthropic = "Anthropic Messages"
    var id: String { rawValue }
    var path: String { switch self { case .responses: return "responses"; case .chatCompletions: return "chat/completions"; case .anthropic: return "messages" } }
}
struct ProviderConfiguration: Codable, Identifiable {
    var id: String
    var name: String
    var endpoint: String
    var model: String
    var apiProtocol: APIProtocol
    // Optional stored fields retain compatibility with configurations saved before 0.4.
    var reasoning: ReasoningEffort? = nil
    var reasoningAPI: ReasoningAPI? = nil
    var quickModel: String? = nil
    var streamUsage: Bool? = nil
    var includeStreamUsage: Bool { get { streamUsage ?? true } set { streamUsage = newValue } }
    var effort: ReasoningEffort { get { reasoning ?? .automatic } set { reasoning = newValue } }
    var reasoningStyle: ReasoningAPI { get { reasoningAPI ?? .automatic } set { reasoningAPI = newValue } }
    static let presets: [Self] = [
        .init(id: "openai", name: "OpenAI / Codex", endpoint: "https://api.openai.com/v1", model: "", apiProtocol: .responses),
        .init(id: "anthropic", name: "Anthropic / Claude", endpoint: "https://api.anthropic.com/v1", model: "", apiProtocol: .anthropic),
        .init(id: "deepseek", name: "DeepSeek", endpoint: "https://api.deepseek.com/v1", model: "deepseek-chat", apiProtocol: .chatCompletions),
        .init(id: "zhipu", name: "智谱 GLM", endpoint: "https://open.bigmodel.cn/api/paas/v4", model: "", apiProtocol: .chatCompletions),
        .init(id: "custom", name: "自定义 / 本地模型", endpoint: "http://localhost:11434/v1", model: "", apiProtocol: .chatCompletions)
    ]
}
final class ProviderStore: ObservableObject {
    @Published var configurations: [ProviderConfiguration] { didSet { persist() } }
    @Published var selectedID: String { didSet { defaults.set(selectedID, forKey: "providerID") } }
    private let defaults: UserDefaults
    var selected: ProviderConfiguration { configurations.first { $0.id == selectedID } ?? configurations[0] }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configurations = defaults.data(forKey: "providers").flatMap { try? JSONDecoder().decode([ProviderConfiguration].self, from: $0) }.flatMap { $0.isEmpty ? nil : $0 } ?? ProviderConfiguration.presets
        selectedID = defaults.string(forKey: "providerID") ?? "openai"
    }
    func update(_ config: ProviderConfiguration) { if let i = configurations.firstIndex(where: { $0.id == config.id }) { configurations[i] = config } }
    private func persist() { if let data = try? JSONEncoder().encode(configurations) { defaults.set(data, forKey: "providers") } }
}

enum Keychain {
    static func read(_ id: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.echoterm.provider", kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ key: String, for id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.echoterm.provider", kSecAttrAccount as String: id]
        if key.isEmpty { let status = SecItemDelete(query as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw AIError.message("钥匙串删除失败：\(status)") }; return }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AIError.message("钥匙串保存失败：\(status)") }
    }
}

enum AIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct CommandSuggestion: Identifiable, Equatable {
    var id = UUID()
    var command: String
    var explanation: String
    var risk: String
    var state = "pending"
}
struct AIToolCall {
    var id: String
    var name: String
    var arguments: String
    func command() throws -> CommandSuggestion {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count < 16384,
              !command.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 10 && $0.value != 9) || $0.value == 127 }) else {
            throw AIError.message("模型返回的命令参数无效，未执行。")
        }
        let risk = object["risk"] as? String ?? "write"
        return .init(command: command, explanation: object["explanation"] as? String ?? "", risk: ["read", "write", "destructive"].contains(risk) ? risk : "write")
    }
}
struct AIReply {
    var text: String
    var suggestions: [CommandSuggestion] = []
    var calls: [AIToolCall] = []
    // Provider-native content, including opaque reasoning, is replayed unchanged within a tool loop.
    var continuation: [[String: Any]] = []
    var usage: TokenUsage?
}
enum AgentStepKind { case command, read, jump, list
    var icon: String { switch self { case .command: return "terminal"; case .read: return "doc.text.magnifyingglass"; case .jump: return "arrow.up.forward"; case .list: return "list.number" } }
}
struct AgentStep: Identifiable {
    var id = UUID()
    var command: String
    var explanation: String
    var status = "执行中"
    var blockID: UUID?
    var kind: AgentStepKind = .command
    var sessionID: UUID?
}
struct AIStreamUpdate {
    var text: String
    var phase: String
    var activity: CompanionActivity
    var usage: TokenUsage?
    init(text: String, phase: String, activity: CompanionActivity? = nil, usage: TokenUsage? = nil) {
        self.usage = usage
        self.text = text; self.phase = phase; self.activity = activity ?? (text.isEmpty ? .thinking : .working)
    }
}

struct ChatMessage: Identifiable {
    var id = UUID()
    var role: String
    var text: String
    var suggestions: [CommandSuggestion] = []
    var steps: [AgentStep] = []
    var status = ""
    var isStreaming = false
    var activity: CompanionActivity = .idle
    var runID: UUID?
    var roundSummary: AIRoundSummary?
}

final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}


enum ContextRedactor {
    static func redact(_ text: String) -> String {
        var result = text
        let rules = [
            #"(?i)((?:api[_-]?key|token|secret|password|authorization)\s*[:=]\s*)([^\s,;]+)"#,
            #"(?i)(bearer\s+)[a-z0-9._\-]+"#,
            #"\b(sk-[a-zA-Z0-9_\-]{12,})\b"#
        ]
        for (index, rule) in rules.enumerated() {
            if let regex = try? NSRegularExpression(pattern: rule) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: index == 2 ? "[REDACTED]" : "$1[REDACTED]")
            }
        }
        return result
    }
}
