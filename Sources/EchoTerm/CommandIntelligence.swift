import Foundation

enum InputRoute: String, CaseIterable, Identifiable {
    case automatic, shell, assistant
    var id: String { rawValue }
    var title: String { switch self { case .automatic: return "自动识别"; case .shell: return "终端命令"; case .assistant: return "询问 Echo" } }
}

struct ShellWord {
    var value: String
    var range: NSRange
    var dynamic: Bool
}

/// Lexes words without ever evaluating input, expanding substitutions, or launching a shell.
enum ShellWords {
    static func parse(_ input: String, firstExecutableOnly: Bool = false) -> [ShellWord] {
        let chars = Array(input.utf16)
        var words: [ShellWord] = [], i = 0
        while i < chars.count {
            while i < chars.count && (chars[i] == 32 || chars[i] == 9 || chars[i] == 10) { i += 1 }
            guard i < chars.count else { break }
            let start = i
            var value: [UInt16] = [], quote: UInt16 = 0, dynamic = false
            while i < chars.count {
                let c = chars[i]
                if quote == 0 && (c == 32 || c == 9 || c == 10) { break }
                if c == 92 && quote != 39 && i + 1 < chars.count { i += 1; value.append(chars[i]); i += 1; continue }
                if (c == 39 || c == 34) && (quote == 0 || quote == c) { quote = quote == 0 ? c : 0; i += 1; continue }
                if quote != 39 && (c == 36 || c == 96) { dynamic = true }
                if quote == 0 && [UInt16(124), 59, 38, 60, 62, 40, 41].contains(c) {
                    if i == start { value.append(c); i += 1 }
                    break
                }
                value.append(c); i += 1
            }
            let word = ShellWord(value: String(decoding: value, as: UTF16.self), range: NSRange(location: start, length: i - start), dynamic: dynamic)
            words.append(word)
            if firstExecutableOnly && !isAssignment(word.value) { break }
        }
        return words
    }
    static func isAssignment(_ word: String) -> Bool {
        word.range(of: #"^[A-Za-z_][A-Za-z_0-9]*="#, options: .regularExpression) != nil
    }
    static func executable(in input: String) -> ShellWord? { parse(input, firstExecutableOnly: true).first { !isAssignment($0.value) } }
    static func quote(_ word: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./~-:@%+=,")
        if word.unicodeScalars.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct CommandAssessment: Equatable {
    var isCommand: Bool
    var dynamic = false
    var range: NSRange?
}

struct ShellCommandCatalog {
    var names: Set<String> = []
    var paths: [String] = []
    private static let syntax: Set<String> = ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "select", "repeat", "foreach", "time", "!", "{", "(", ">", "<", "[[", "]]", "coproc", "noglob", "nocorrect"]
    static func load(namesURL: URL?, pathURL: URL?, directory: String) -> Self {
        let path = pathURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { $0.trimmingCharacters(in: .newlines) }
            ?? ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let paths = path.components(separatedBy: ":").map { entry in
            if entry.isEmpty { return directory }
            return entry.hasPrefix("/") ? entry : URL(fileURLWithPath: directory).appendingPathComponent(entry).path
        }
        var names = Set((namesURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "").components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("_echoterm") })
        for path in Set(paths) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                let file = URL(fileURLWithPath: path).appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory), !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: file) { names.insert(name) }
            }
        }
        return .init(names: names, paths: paths)
    }
    func assess(_ input: String, directory: String) -> CommandAssessment {
        if input.range(of: #"^\s*(?:[A-Za-z_][A-Za-z_0-9]*\s*\(\s*\)|[0-9]*[<>])"#, options: .regularExpression) != nil { return .init(isCommand: true, dynamic: true) }
        guard let word = ShellWords.executable(in: input) else { return .init(isCommand: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        if word.dynamic { return .init(isCommand: true, dynamic: true, range: word.range) }
        if word.value.hasPrefix("#") || Self.syntax.contains(word.value) { return .init(isCommand: true, dynamic: true, range: word.range) }
        var found = names.contains(word.value)
        if word.value.contains("/") {
            let expanded = (word.value as NSString).expandingTildeInPath
            let file = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: directory).appendingPathComponent(expanded).path
            var isDirectory: ObjCBool = false
            found = FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory) && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: file)
        }
        return .init(isCommand: found, range: word.range)
    }
    /// Input history arrives oldest-first. Keep each complete command's most
    /// recent occurrence; matching is literal and never evaluates shell text.
    static func historyCompletions(for input: String, history: [String]) -> [String] {
        guard input.utf8.count <= 4_000, !input.contains("\n") else { return [] }
        var seen: Set<String> = []
        return history.reversed().filter {
            !$0.isEmpty && !$0.contains("\n") && $0 != input && $0.hasPrefix(input) && seen.insert($0).inserted
        }
    }
    func completions(for input: String, directory: String, history: [String]) -> [String] {
        guard !input.isEmpty, !input.contains("\n") else { return [] }
        var candidates: [String] = [], seen: Set<String> = []
        func add(_ value: String) { if value != input && value.hasPrefix(input) && seen.insert(value).inserted { candidates.append(value) } }
        Self.historyCompletions(for: input, history: history).forEach(add)
        let words = ShellWords.parse(input)
        let trailing = input.last?.isWhitespace == true
        let last = trailing ? ShellWord(value: "", range: NSRange(location: (input as NSString).length, length: 0), dynamic: false) : words.last
        guard let word = last, !word.dynamic else { return Array(candidates.prefix(20)) }
        let first = ShellWords.executable(in: input)
        let isExecutable = first?.range == word.range
        let prefix = (input as NSString).substring(to: word.range.location)
        if isExecutable && !word.value.contains("/") {
            names.filter { $0.hasPrefix(word.value) }.sorted().prefix(40).forEach { add(prefix + $0) }
        }
        // Argument/path completion uses directory listings only; no eval or shell interpolation.
        if !isExecutable || word.value.contains("/") || word.value.hasPrefix("~") {
            let slash = word.value.lastIndex(of: "/")
            let folderPart = slash.map { String(word.value[...$0]) } ?? ""
            let leaf = slash.map { String(word.value[word.value.index(after: $0)...]) } ?? word.value
            let expanded = (folderPart as NSString).expandingTildeInPath
            let folder = expanded.hasPrefix("/") ? expanded : URL(fileURLWithPath: directory).appendingPathComponent(expanded).path
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() where name.hasPrefix(leaf) && (!name.hasPrefix(".") || leaf.hasPrefix(".")) {
                let file = URL(fileURLWithPath: folder).appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory) else { continue }
                if isExecutable && !isDirectory.boolValue && !FileManager.default.isExecutableFile(atPath: file) { continue }
                let value = folderPart + name + (isDirectory.boolValue ? "/" : "")
                let raw = (input as NSString).substring(from: word.range.location)
                // Preserve an opening quote/escaped prefix so the remainder can be drawn as ghost text.
                let quoted: String
                if raw.hasPrefix("\"") && !raw.dropFirst().contains("\"") { quoted = "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "`", with: "\\`") + "\"" }
                else if raw.hasPrefix("'") && !raw.dropFirst().contains("'") && !value.contains("'") { quoted = "'" + value + "'" }
                else { quoted = value.map { " \\()[]{}&;|<>$`\"'!?*".contains($0) ? "\\" + String($0) : String($0) }.joined() }
                add(prefix + quoted)
            }
        }
        return Array(candidates.prefix(20))
    }
}
