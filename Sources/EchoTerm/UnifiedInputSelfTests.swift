#if DEBUG
import Foundation

@MainActor enum UnifiedInputSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-input-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture-tool")
        try "#!/bin/sh\nprintf fixture-command".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try "plain".write(to: root.appendingPathComponent("not-executable"), atomically: true, encoding: .utf8)
        try "space".write(to: root.appendingPathComponent("hello world.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let catalog = ShellCommandCatalog(names: ["git", "printf", "echo", "cd", "pwd"], paths: ["/usr/bin", "/bin"])
        for command in ["git status", "FOO=bar git diff", "'git' status", "./fixture-tool", executable.path, "NAME=value", "echo x | cat", "if true; then echo x; fi", "[[ -f x ]]", "foo() { echo x; }", "2>/tmp/echo-test", "$SHELL -c true"] {
            check(catalog.assess(command, directory: root.path).isCommand, "Input routes shell syntax / executable: \(command)")
        }
        for question in ["解释一下这个错误", "帮我检查当前目录", "gti status", "./not-executable", "./folder", "what should I do next?"] {
            check(!catalog.assess(question, directory: root.path).isCommand, "Unknown command routes to Echo without running: \(question)")
        }
        let quoted = ShellWords.parse("FOO=1 '/tmp/a b' x\\ y")
        check(quoted.count == 3 && quoted[1].value == "/tmp/a b" && quoted[2].value == "x y", "Classifier understands assignments, quotes and escaped spaces")
        let completion = catalog.completions(for: "gi", directory: root.path, history: ["git status", "git diff", "git status"])
        check(completion.first == "git status" && completion.contains("git") && Set(completion).count == completion.count, "Completion combines recent history and executable names without duplicates")
        check(catalog.completions(for: "cat hel", directory: root.path, history: []).contains("cat hello\\ world.txt"), "File completion escapes spaces instead of introducing another argument")
        check(catalog.completions(for: "cat 'hel", directory: root.path, history: []).contains("cat 'hello world.txt'"), "File completion preserves and closes a quoted prefix")
        check(catalog.completions(for: "cd fol", directory: root.path, history: []).contains("cd folder/"), "Directory completion retains the slash for continuing a path")
        let marker = root.appendingPathComponent("must-not-exist")
        _ = catalog.assess("$(touch \(marker.path))", directory: root.path)
        _ = catalog.completions(for: "cat $(touch \(marker.path))", directory: root.path, history: [])
        check(!FileManager.default.fileExists(atPath: marker.path), "Classification and completion never evaluate command substitutions")

        let suite = "EchoTerm.Unified.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        providers.configurations = [.init(id: "unified-fixture", name: "fixture", endpoint: "http://localhost/v1", model: "fixture", apiProtocol: .chatCompletions)]
        providers.selectedID = "unified-fixture"
        preferences.quickIntents = false
        for shell in ["/bin/zsh", "/bin/bash"] {
            let session = TerminalSession(directory: root.path, loadShellConfig: false, shellPath: shell)
            session.usesBlockEditor = true; session.start(); defer { session.close() }
            try await wait { session.ready && session.catalogReady }
            session.draft = "export PATH=\(ShellWords.quote(root.path)):$PATH; alias fixture_alias='printf alias'; fixture_func() { printf function; }"
            session.execute(); try await wait { !session.running && session.commandCatalog.names.contains("fixture_func") }
            check(session.commandCatalog.names.contains("fixture_alias") && session.commandCatalog.names.contains("cd") && session.commandCatalog.names.contains("fixture-tool"), "\(shell) catalog reflects live PATH, builtins, aliases and functions")
            check(!session.commandCatalog.names.contains("not-executable") && !session.commandCatalog.names.contains("folder"), "\(shell) PATH catalog excludes nonexecutable files and directories")
            var requests = 0
            let assistant = AssistantStore(providers: providers, preferences: preferences) { _, update in
                requests += 1
                update(.init(text: "## 分析\n\n正在处理", phase: "正在回答…"))
                try await Task.sleep(nanoseconds: 100_000_000)
                return .init(text: "## 完成\n\n**结论**\n\n```sh\npwd\n```\n\n- 第一项")
            }
            session.draft = "fixture_alias"; check(assistant.submitInput(session: session), "\(shell) automatic route submits a known alias")
            try await wait { !session.running }
            check(session.blocks.last?.output.contains("alias") == true && requests == 0, "\(shell) known commands execute in the existing PTY without a chat request")
            session.draft = "解释一下这个错误"; assistant.submitInput(session: session)
            let aiID = session.blocks.last?.id
            check(session.blocks.last?.isAI == true && !session.running && session.draft.isEmpty, "\(shell) natural language immediately creates an inline AI block")
            session.draft = "保留这个草稿"
            check(!assistant.submitInput(session: session) && session.draft == "保留这个草稿", "\(shell) a busy assistant preserves the next question")
            session.draft = "printf must-wait"
            check(!assistant.canStartBlock(in: session) && !assistant.submitInput(session: session, forced: .shell) && !session.running && session.draft == "printf must-wait", "\(shell) a streaming answer prevents a new forced command without losing its draft")
            session.draft = ""
            try await wait { !assistant.thinking.contains(session.id) }
            check(session.blocks.first { $0.id == aiID }?.output.contains("## 完成") == true && requests == 1, "\(shell) streaming and final responses update the original AI block")
            session.draft = "sleep 0.3; printf own-output"; assistant.submitInput(session: session)
            let commandID = session.runningBlockID
            let beforeQuestion = session.blocks.count
            let accepted = assistant.ask("边运行边解释", session: session)
            check(!accepted && !assistant.canStartBlock(in: session) && session.blocks.count == beforeQuestion, "\(shell) a running command cannot be followed by a premature AI block")
            try await wait { !session.running && !assistant.thinking.contains(session.id) }
            check(session.blocks.last?.id == commandID && session.blocks.last?.output.contains("own-output") == true && assistant.canStartBlock(in: session), "\(shell) the next input becomes available only after the command completes")
            session.draft = "fixture-invalid-command"; assistant.submitInput(session: session, forced: .shell)
            try await wait { !session.running }
            check(session.blocks.last?.isAI == false && session.blocks.last?.exitCode == 127, "\(shell) forced terminal route preserves normal command-not-found diagnostics")
            session.draft = "pwd"; assistant.submitInput(session: session, forced: .assistant)
            try await wait { !assistant.thinking.contains(session.id) }
            check(session.blocks.last?.isAI == true && session.blocks.last?.command == "pwd", "\(shell) forced AI route can ask about an otherwise valid command")
            session.history(-1)
            check(session.draft == "fixture-invalid-command", "\(shell) terminal history excludes AI questions")
            session.draft = ""
        }
        preferences.quickIntents = true
        let session = TerminalSession(directory: root.path, loadShellConfig: false)
        defer { session.close() }
        let assistant = AssistantStore(providers: providers, preferences: preferences) { request, _ in
            return .init(text: request.purpose == .intent ? InteractionSelfTests.fixture : "历史意图的回答")
        }
        session.blocks = [.init(command: "pwd", directory: root.path)]
        let old = session.blocks[0].id
        assistant.didExecute("pwd", session: session)
        try await wait { assistant.intentPreviews[session.id]?.loading == false }
        session.blocks.append(.init(command: "ls", directory: root.path))
        assistant.didExecute("ls", session: session)
        try await wait { assistant.intentPreviews[session.id]?.loading == false }
        check(assistant.blockIntents[old]?.options.count == 2 && assistant.blockIntents.count == 2, "Quick options remain attached to earlier command blocks")
        assistant.chooseIntent(assistant.blockIntents[old]!.options[0], session: session, blockID: old)
        try await wait { !assistant.thinking.contains(session.id) }
        check(session.blocks.last?.isAI == true && assistant.messages(for: session).first?.text.contains("对应命令：pwd") == true, "Clicking an old intent creates a new AI block with its original command context")
        check(assistant.presentation == nil, "Inline responses and quick suggestions do not reopen a floating assistant")

        let pieces = MarkdownBlocks.parse("# 标题\n\n**重点**和`代码`\n\n- 第一项\n\n> 引用\n\n```sh\npwd\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |")
        check(pieces.contains(.heading(1, "标题")) && pieces.contains(.code("sh", "pwd")) && pieces.contains(.item("•", "第一项")) && pieces.contains(.quote("引用")), "Markdown separates headings, fenced code, lists and quotes into native views")
        check(pieces.contains(.table([["A", "B"], ["1", "2"]])), "Markdown tables preserve headers and rows")
        check(MarkdownBlocks.parse("```sh\nprintf partial") == [.code("sh", "printf partial")], "Streaming an unfinished code fence remains readable")
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw AIError.message("Unified input fixture timeout")
    }
}
#endif
