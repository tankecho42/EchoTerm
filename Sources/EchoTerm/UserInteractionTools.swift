import Foundation
import CoreFoundation

struct UserChoiceOption: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

struct UserQuestionSpec: Equatable {
    let question: String
    let options: [UserChoiceOption]
    let allowCustom: Bool
    let commandID: UUID?

    static func parse(_ call: AIToolCall) throws -> Self {
        guard call.name == InteractionTools.ask else { throw AIError.message("不是有效的用户提问工具。") }
        let object = try InteractionToolArguments.object(call.arguments, allowed: ["question", "options", "allow_custom_input", "command_id"])
        guard let question = object["question"] as? String, question.count <= 2000,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.message("提问内容不能为空，且不能超过 2000 字符。")
        }
        let allowCustom = try InteractionToolArguments.boolean(object["allow_custom_input"], default: true)
        let commandID = try InteractionToolArguments.commandID(object["command_id"], required: false)
        var items: [Any] = []
        if let value = object["options"] {
            guard let options = value as? [Any] else { throw AIError.message("提问选项必须为数组。") }
            items = options
        }
        guard items.count <= 8 else { throw AIError.message("提问最多支持 8 个选项。") }
        var values = Set<String>()
        let options: [UserChoiceOption] = try items.enumerated().map { index, item in
            guard let option = item as? [String: Any], Set(option.keys) == ["label", "value"],
                  let label = option["label"] as? String, label.count <= 120,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let value = option["value"] as? String, value.count <= 2000,
                  commandID == nil || value.utf8.count <= 4096,
                  InteractionToolArguments.isSingleLineValue(value), values.insert(value).inserted else {
                throw AIError.message("提问选项格式无效：名称不能为空且最多 120 字符；值必须唯一、最多 2000 字符且不含换行或控制字符。终端答案最多 4096 字节。")
            }
            // Position is stable across parsing the same specification and avoids process-randomized hashes.
            return .init(id: "option-\(index + 1)", label: label.trimmingCharacters(in: .whitespacesAndNewlines), value: value)
        }
        guard allowCustom || !options.isEmpty else { throw AIError.message("提问至少需要一个选项或允许自定义输入。") }
        return .init(question: question.trimmingCharacters(in: .whitespacesAndNewlines), options: options, allowCustom: allowCustom, commandID: commandID)
    }
}

/// Shared bounded decoding rejects unknown fields and numeric substitutes for JSON booleans.
enum InteractionToolArguments {
    static let maximumJSONBytes = 128_000

    static func object(_ arguments: String, allowed: Set<String>) throws -> [String: Any] {
        guard arguments.utf8.count <= maximumJSONBytes,
              let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: allowed) else {
            throw AIError.message("工具参数必须是大小受限的 JSON 对象，且不能含未知字段。")
        }
        return object
    }

    static func boolean(_ value: Any?, default fallback: Bool) throws -> Bool {
        guard let value else { return fallback }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw AIError.message("工具开关参数必须为布尔值。")
        }
        return number.boolValue
    }

    static func commandID(_ value: Any?, required: Bool) throws -> UUID? {
        guard let value else {
            if required { throw AIError.message("必须指定有效的 command_id。") }
            return nil
        }
        guard let text = value as? String else { throw AIError.message("command_id 必须为字符串。") }
        if text.isEmpty && !required { return nil }
        guard text.count == 36, let id = UUID(uuidString: text) else { throw AIError.message("command_id 必须为有效的命令 UUID。") }
        return id
    }

    static func isSingleLineValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }
}

enum InteractionTools {
    static let ask = "ask_user"
    static let wait = "wait_command"
    static let names: Set<String> = [ask, wait]

    static func waitCommandID(_ call: AIToolCall) throws -> UUID {
        guard call.name == wait else { throw AIError.message("不是有效的命令等待工具。") }
        let object = try InteractionToolArguments.object(call.arguments, allowed: ["command_id"])
        guard let id = try InteractionToolArguments.commandID(object["command_id"], required: true) else {
            throw AIError.message("必须指定有效的 command_id。")
        }
        return id
    }

    static func description(_ name: String) -> String {
        name == ask
            ? "向用户提出一个问题，可提供选项或自定义输入。command_id 为空时答案仅返回助手；指定运行中命令的 ID 时，经用户确认的单行答案直接发给原命令。禁止用来询问密码、密钥或其他秘密。"
            : "有限等待原交互命令，返回其当前输出、是否仍运行以及结束时的退出码。只接受 execute_command 返回的 command_id，不发送输入。"
    }

    static func schema(_ name: String) -> [String: Any] {
        if name == wait {
            return ["type": "object", "properties": ["command_id": ["type": "string", "description": "execute_command 返回的运行中命令 UUID"]], "required": ["command_id"], "additionalProperties": false]
        }
        return [
            "type": "object",
            "properties": [
                "question": ["type": "string", "minLength": 1, "maxLength": 2000],
                "options": ["type": "array", "maxItems": 8, "items": [
                    "type": "object", "properties": [
                        "label": ["type": "string", "minLength": 1, "maxLength": 120],
                        "value": ["type": "string", "maxLength": 2000, "description": "实际答案；用于终端时为空表示直接按 Enter，不能含换行或控制字符"]
                    ], "required": ["label", "value"], "additionalProperties": false
                ]],
                "allow_custom_input": ["type": "boolean", "description": "是否允许用户自己输入答案"],
                "command_id": ["type": "string", "description": "普通提问用空字符串；向原运行命令提交答案时填写其 command_id"]
            ],
            // Required in the wire schema for Responses strict mode; the local parser also accepts older omitted defaults.
            "required": ["question", "options", "allow_custom_input", "command_id"], "additionalProperties": false
        ]
    }

    static let questionInstructions = """
    【向用户提问】
    需要用户选择方案、补充信息或确认普通输入时，用 ask_user 提出一个简短问题，提供清楚的选项并按需允许自定义输入；等待用户回答后再继续，不替用户选择。command_id 为空字符串时，答案只返回给你，不会发送到终端。
    不要把 ask_user 与 execute_command 放在同一批工具调用中；先取得答案，再决定下一步。禁止通过 ask_user 索取密码、验证码、API Key 或其他秘密。涉及秘密或敏感认证时请用户直接在原生终端中操作，不收集、不复述，也不把秘密写入工具参数。
    """
    static let commandInstructions = """
    【交互命令】
    只有本轮提供 execute_command 时才可启动新命令；未提供时只能继续等待已经启动的命令。只要新命令可能询问普通选项或等待 stdin，就必须 execute_command(interactive: true)。这会尽快返回 command_id 和实际输出，不能把“还在运行”视为失败或已完成。非交互命令使用 interactive: false。
    先检查命令的真实输出，只有已经明确显示需要用户输入的提示、且本轮提供 ask_user 时，才调用 ask_user 并填写原命令的 command_id。未提供 ask_user 时请用户直接在原生终端操作，不要构造答案。选项的 value 是发送给原命令的一行答案，不是新 Shell 命令；空字符串表示仅按 Enter。不要编造提示，不要因暂时没有输出、耗时较长或静默运行就断定需要输入。
    命令尚未完成且没有输入提示时，用 wait_command(command_id) 有限等待并检查新快照，直到获得退出码。回答选项之后也要继续等待、读取原命令的后续输出。始终操作同一条原命令，不要重新执行它来提交答案；不提供任意 stdin 或自动猜选项的工具。
    ask_user 返回 manual_input 表示用户已从命令输入入口继续，旧问题已经解决，答案内容不会重放给你；先用 wait_command 读取新输出，不要重复提交旧答案。command_finished 表示提问期间原命令已结束或失去输入资格，同样只检查原句柄的最终结果，不重新执行命令。
    密码、验证码、私钥等秘密不能通过 ask_user 或工具参数提交；遇到敏感认证、全屏程序或无法安全处理的交互，请用户直接使用原生终端处理。
    """
}
