#if DEBUG
import Foundation

@MainActor enum UserInteractionProtocolSelfTests {
    static func run(check: (Bool, String) -> Void) throws {
        let commandID = UUID()
        let base: [String: Any] = ["question": "请选择是否继续", "options": [["label": "继续", "value": "yes"], ["label": "直接回车", "value": ""]], "allow_custom_input": true, "command_id": commandID.uuidString]
        func ask(_ object: [String: Any]) throws -> UserQuestionSpec {
            try UserQuestionSpec.parse(call(InteractionTools.ask, object))
        }
        func rejects(_ object: [String: Any]) -> Bool { (try? ask(object)) == nil }
        let parsed = try ask(base)
        check(parsed.commandID == commandID && parsed.options.map(\.value) == ["yes", ""] && parsed.allowCustom, "Question parser preserves command identity and an empty Enter answer")
        check(try ask(base) == parsed && Set(parsed.options.map(\.id)).count == parsed.options.count, "Parsing the same question yields stable and distinct option identities")
        let plain = try ask(["question": "请补充需求"])
        check(plain.commandID == nil && plain.options.isEmpty && plain.allowCustom, "Conversation-only questions accept omitted legacy defaults")
        var question = base; question["command_id"] = ""
        check(try ask(question).commandID == nil, "An empty command identifier keeps the answer in the AI conversation")
        question["allow_custom_input"] = false; question["options"] = []
        check(rejects(question), "A question cannot strand the user with no selectable or custom answer")
        question = base; question["options"] = (0..<8).map { ["label": "选项 \($0)", "value": "\($0)"] }
        check((try? ask(question))?.options.count == 8, "A question supports the maximum eight distinct options")
        question["options"] = (0..<9).map { ["label": "选项 \($0)", "value": "\($0)"] }
        check(rejects(question), "Questions reject more than eight options")
        question = base; question["options"] = [["label": "是", "value": "yes"], ["label": "同意", "value": "yes"]]
        check(rejects(question), "Duplicate submitted values cannot create ambiguous user choices")
        question = base; question["question"] = String(repeating: "问", count: 2000)
        check((try? ask(question)) != nil, "The question length boundary accepts 2000 Unicode characters")
        question["question"] = String(repeating: "问", count: 2001)
        check(rejects(question), "Question text is bounded before display")
        question = base; question["command_id"] = ""; question["options"] = [["label": String(repeating: "选", count: 120), "value": String(repeating: "值", count: 2000)]]
        check((try? ask(question)) != nil, "Option label and value accept their documented length boundaries")
        question["options"] = [["label": String(repeating: "选", count: 121), "value": "yes"]]
        check(rejects(question), "Option labels are bounded")
        question["options"] = [["label": "选项", "value": String(repeating: "值", count: 2001)]]
        check(rejects(question), "Submitted choice values are bounded")
        question = base; question["options"] = [["label": "终端答案", "value": String(repeating: "值", count: 1365)]]
        check((try? ask(question)) != nil, "Terminal choices accept Unicode answers inside the PTY byte bound")
        question["options"] = [["label": "终端答案", "value": String(repeating: "值", count: 1366)]]
        check(rejects(question), "Terminal choices reject Unicode answers exceeding the PTY byte bound")
        for invalid in ["yes\nnext", "yes\r", "\t", "\u{0}", "\u{1b}[31m", "\u{7f}", "\u{2028}"] {
            question = base; question["options"] = [["label": "非法输入", "value": invalid]]
            check(rejects(question), "Terminal option values reject line breaks and control characters \(invalid.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ","))")
        }
        let invalidFields: [[String: Any]] = [
            ["question": "   "], ["question": 1], ["question": "问题", "options": "yes"],
            ["question": "问题", "options": [["label": " ", "value": "y"]]],
            ["question": "问题", "options": [["label": "是", "value": 1]]],
            ["question": "问题", "options": [["label": "是", "value": "y", "id": "injected"]]],
            ["question": "问题", "allow_custom_input": 1], ["question": "问题", "allow_custom_input": "true"],
            ["question": "问题", "allow_custom_input": NSNull()], ["question": "问题", "command_id": "not-a-uuid"],
            ["question": "问题", "command_id": NSNull()], ["question": "问题", "extra": true]
        ]
        check(invalidFields.allSatisfy(rejects), "Question parser rejects missing content, wrong JSON types, unknown fields and forged identifiers")
        let oversized = AIToolCall(id: "large", name: InteractionTools.ask, arguments: String(repeating: " ", count: InteractionToolArguments.maximumJSONBytes + 1))
        check((try? UserQuestionSpec.parse(oversized)) == nil, "Oversized raw question JSON is rejected before decoding")
        check(try InteractionTools.waitCommandID(call(InteractionTools.wait, ["command_id": commandID.uuidString])) == commandID, "wait_command resolves the exact original command UUID")
        let invalidWait: [[String: Any]] = [[:], ["command_id": ""], ["command_id": 1], ["command_id": commandID.uuidString, "stdin": "yes"], ["command_id": "not-a-uuid"]]
        check(invalidWait.allSatisfy { (try? InteractionTools.waitCommandID(call(InteractionTools.wait, $0))) == nil }, "wait_command cannot accept stdin, missing IDs, unknown fields or wrong types")
        var command: [String: Any] = ["command": "printf ready", "explanation": "fixture", "risk": "read"]
        check(try call(AIClient.executeTool, command).command().interactive == false, "Legacy execute_command arguments remain noninteractive by default")
        command["interactive"] = true
        check(try call(AIClient.executeTool, command).command().interactive, "execute_command preserves an explicit interactive flag")
        command["interactive"] = 1
        check((try? call(AIClient.executeTool, command).command()) == nil, "execute_command rejects numeric masquerading as interactive boolean")
        command["interactive"] = "true"
        check((try? call(AIClient.executeTool, command).command()) == nil, "execute_command rejects an interactive flag with the wrong JSON type")

        for api in APIProtocol.allCases {
            let config = ProviderConfiguration(id: "protocol-fixture", name: "fixture", endpoint: "http://localhost/v1", model: "fixture", apiProtocol: api)
            let noTools = try requestBody(config, mode: .answer)
            check(toolNames(noTools, api: api).isEmpty, "\(api.rawValue) defaults preserve tool-free Q&A")
            let onlyAsk = try requestBody(config, mode: .answer, questions: true)
            check(toolNames(onlyAsk, api: api) == [InteractionTools.ask], "\(api.rawValue) Q&A can ask the user without terminal context or execution access")
            let onlyWait = try requestBody(config, mode: .answer, controls: true)
            check(toolNames(onlyWait, api: api) == [InteractionTools.wait], "\(api.rawValue) exhausted command-start mode can still wait for an existing command")
            let initial = try requestBody(config, mode: .autonomous, questions: true)
            let initialInstructions = (initial["instructions"] ?? initial["system"] ?? (initial["messages"] as? [[String: Any]])?.first?["content"]) as? String ?? ""
            check(Set(toolNames(initial, api: api)) == [AIClient.executeTool, InteractionTools.ask]
                  && initialInstructions.contains("execute_command(interactive: true)") && !initialInstructions.contains("仅使用 interactive: false"), "\(api.rawValue) the first autonomous command may be interactive before a wait handle exists")
            let full = try requestBody(config, mode: .autonomous, questions: true, controls: true)
            check(Set(toolNames(full, api: api)) == [AIClient.executeTool, InteractionTools.ask, InteractionTools.wait], "\(api.rawValue) autonomous conversation advertises explicit execution, questions and command waiting")
            check(toolSchemas(full, api: api).allSatisfy(strictObjectSchema), "\(api.rawValue) tool schemas require every property and reject additional fields")
            for purpose in [AIRequestPurpose.intent, .tabTitle] {
                let fast = try requestBody(config, mode: .autonomous, purpose: purpose, questions: true, controls: true)
                check(toolNames(fast, api: api).isEmpty, "\(api.rawValue) \(purpose) cannot expose interaction or execution tools")
            }
            let toolCall = call(InteractionTools.ask, base)
            let reply = try AIClient.parse(JSONSerialization.data(withJSONObject: response(api: api, tool: toolCall)), apiProtocol: api)
            let returned = reply.calls.first!
            let spec = try UserQuestionSpec.parse(returned)
            let answer = AIClient.toolResults([(returned, "{\"answer\":\"yes\"}")], apiProtocol: api)
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
            check(returned.id == toolCall.id && spec == parsed && serialized.contains(toolCall.id), "\(api.rawValue) question parsing and native result envelopes retain exact tool-call IDs")
            if api == .responses {
                check((full["tools"] as? [[String: Any]])?.allSatisfy { $0["strict"] as? Bool == true } == true, "Responses question and command schemas keep explicit strict mode")
            }
        }
    }

    private static func call(_ name: String, _ object: [String: Any]) -> AIToolCall {
        .init(id: "interaction-protocol-call", name: name, arguments: String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    private static func requestBody(_ config: ProviderConfiguration, mode: AssistantMode, purpose: AIRequestPurpose = .conversation, questions: Bool = false, controls: Bool = false) throws -> [String: Any] {
        let request = try AIClient.request(config: config, key: "", messages: [], context: "", mode: mode, purpose: purpose, allowsUserInteraction: questions, allowsCommandControl: controls)
        return try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
    }
    private static func toolNames(_ body: [String: Any], api: APIProtocol) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap { (api == .chatCompletions ? $0["function"] as? [String: Any] : $0)?["name"] as? String }
    }
    private static func toolSchemas(_ body: [String: Any], api: APIProtocol) -> [[String: Any]] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap { tool in
            switch api {
            case .responses: return tool["parameters"] as? [String: Any]
            case .chatCompletions: return (tool["function"] as? [String: Any])?["parameters"] as? [String: Any]
            case .anthropic: return tool["input_schema"] as? [String: Any]
            }
        }
    }
    private static func strictObjectSchema(_ schema: [String: Any]) -> Bool {
        if schema["type"] as? String == "object" {
            guard let properties = schema["properties"] as? [String: [String: Any]], let required = schema["required"] as? [String],
                  Set(properties.keys) == Set(required), schema["additionalProperties"] as? Bool == false,
                  properties.values.allSatisfy(strictObjectSchema) else { return false }
        }
        if let item = schema["items"] as? [String: Any], !strictObjectSchema(item) { return false }
        return true
    }
    private static func response(api: APIProtocol, tool: AIToolCall) throws -> [String: Any] {
        switch api {
        case .responses:
            return ["status": "completed", "output": [["type": "function_call", "call_id": tool.id, "name": tool.name, "arguments": tool.arguments]]]
        case .chatCompletions:
            return ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": "", "tool_calls": [["id": tool.id, "type": "function", "function": ["name": tool.name, "arguments": tool.arguments]]]]]]]
        case .anthropic:
            return ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": tool.id, "name": tool.name, "input": try JSONSerialization.jsonObject(with: Data(tool.arguments.utf8))]]]
        }
    }
}
#endif
