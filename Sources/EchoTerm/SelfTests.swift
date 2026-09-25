#if DEBUG
import Foundation
import AppKit

/// Debug-only runner for machines with Command Line Tools but no XCTest framework.
@MainActor enum SelfTests {
    static func run() async -> Bool {
        var failures = 0, count = 0
        func check(_ condition: Bool, _ message: String) {
            count += 1
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        do {
            let command = "echo 中文; printf 'hello'", cwd = "/tmp/带 空格;目录"
            let marker = "\u{1b}]777;EchoTerm;t;B;\(Data(command.utf8).base64EncodedString())\u{7}你好\r\n\u{1b}]777;EchoTerm;t;D;42;\(Data(cwd.utf8).base64EncodedString())\u{7}"
            let bytes = Array(marker.utf8)
            var boundariesOK = true
            for split in 0...bytes.count {
                var parser = ShellStreamParser(token: "t")
                let events = parser.feed(Array(bytes.prefix(split))) + parser.feed(Array(bytes.dropFirst(split)))
                let output = events.flatMap { event -> [UInt8] in if case .output(let bytes) = event { return bytes }; return [] }
                boundariesOK = boundariesOK && events.contains(.began(command)) && events.contains(.prompt(42, cwd)) && String(decoding: output, as: UTF8.self) == "你好\r\n"
            }
            check(boundariesOK, "PTY markers + UTF-8 across all \(bytes.count + 1) packet boundaries")
            var parser = ShellStreamParser(token: "private")
            let foreign = Array("\u{1b}]777;EchoTerm;wrong;D;0;Lw==\u{7}\u{1b}[31mred\u{1b}[0m".utf8)
            let preserved = parser.feed(foreign).flatMap { event -> [UInt8] in if case .output(let bytes) = event { return bytes }; return [] }
            check(preserved == foreign, "Foreign OSC + ANSI pass through unchanged")
            let args = #"{"command":"git status","explanation":"检查状态","risk":"read"}"#
            let fixtures: [(APIProtocol, [String: Any])] = [
                (.responses, ["output": [["type": "function_call", "name": "recommend_command", "arguments": args]]]),
                (.chatCompletions, ["choices": [["message": ["tool_calls": [["function": ["name": "recommend_command", "arguments": args]]]]]]]),
                (.anthropic, ["content": [["type": "tool_use", "name": "recommend_command", "input": ["command": "git status", "explanation": "检查状态", "risk": "read"]]]])
            ]
            for (api, body) in fixtures {
                let config = ProviderConfiguration(id: "test", name: "test", endpoint: "https://example.com/v1/", model: "test", apiProtocol: api)
                let request = try AIClient.request(config: config, key: "test-key", messages: [["role": "user", "content": "hello"]], context: "context")
                let reply = try AIClient.parse(JSONSerialization.data(withJSONObject: body), apiProtocol: api)
                check(request.url?.absoluteString == "https://example.com/v1/" + api.path && reply.suggestions.first?.command == "git status", "\(api.rawValue) request + structured tool response")
            }
            var config = ProviderConfiguration.presets[0]; config.model = "test"; config.endpoint = "http://example.com/v1"
            var refused = false
            do { _ = try AIClient.request(config: config, key: "secret", messages: [], context: "") } catch { refused = true }
            check(refused, "Reject remote plaintext HTTP before transmitting a key")
            config.endpoint = "http://localhost:11434/v1"
            check((try? AIClient.request(config: config, key: "", messages: [], context: "")) != nil, "Allow local OpenAI-compatible endpoints")
            config.endpoint = "http://[::1]:11434/v1"
            check((try? AIClient.request(config: config, key: "", messages: [], context: "")) != nil, "Allow local IPv6 endpoints")
            check(!ContextRedactor.redact("API_KEY=supersecret Bearer abc.def password=hunter2").contains("supersecret"), "Context secret redaction")
            let a = TerminalSession(loadShellConfig: false), b = TerminalSession(loadShellConfig: false), c = TerminalSession(loadShellConfig: false)
            let root = PaneNode.leaf(a).splitting(a.id, vertical: true, newSession: b).splitting(b.id, vertical: false, newSession: c)
            check(root.sessions.count == 3 && root.removing(b.id)?.sessions.map(\.id) == [a.id, c.id], "Nested split and removal preserve sibling sessions")
            let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
            defer { session.close() }
            session.start()
            try await wait { session.ready }
            check(session.ready, "Real zsh PTY initialization")
            try await execute("export ECHOTERM_TEST_VALUE=retained; cd /; printf '你好\\n'; false", session: session)
            check(session.blocks.last?.exitCode == 1 && session.directory == "/", "Exit status + persistent working directory")
            check(session.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "你好", "Clean Unicode output without prompt or NUL artifacts")
            try await execute("printf '%s\\n' \"$ECHOTERM_TEST_VALUE\"", session: session)
            check(session.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "retained", "Environment persists between command blocks")
            try await execute("printf '\\033[31mred\\033[0m\\n'", session: session)
            check(session.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "red", "ANSI output normalized for block snapshot")
            try await execute("echo )", session: session)
            check(session.blocks.last?.exitCode != 0 && session.blocks.last?.output.contains("parse error") == true, "Syntax error captured even without preexec")
            session.draft = "sleep 30"; session.execute()
            try await Task.sleep(nanoseconds: 300_000_000)
            session.interrupt(); try await wait { !session.running }
            check(session.blocks.last?.exitCode == 130, "Ctrl-C interrupts foreground process")
            try await execute("printf 'still alive\\n'", session: session)
            check(session.blocks.last?.output.contains("still alive") == true, "Shell remains usable after interrupt")
            try await execute("printf 'screen\\n'; printf '\\033[?1049hTUI\\033[?1049l'", session: session)
            check(session.blocks.last?.exitCode == 0 && session.blocks.last?.output.contains("screen") == true, "Alternate screen enter/exit retains normal output")
            try await execute("for n in {1..6000}; do print -r -- line-$n; done", session: session)
            check(session.blocks.last?.output.contains("line-6000") == true && session.blocks.last?.output.contains("line-1\n") == false, "Large output keeps bounded scrollback tail")
            let defaults = UserDefaults(suiteName: "app.echoterm.selftest.\(UUID().uuidString)")!
            let preferences = Preferences(defaults: defaults), providers = ProviderStore()
            preferences.quickIntents = false // Never contact a real configured provider during tests.
            let assistant = AssistantStore(providers: providers, preferences: preferences)
            let suggestion = CommandSuggestion(command: "pwd", explanation: "where", risk: "read")
            assistant.conversations[session.id] = [.init(role: "assistant", text: "", suggestions: [suggestion])]
            assistant.use(suggestion, session: session)
            check(session.draft == "pwd" && !session.running, "AI adoption stages a draft without executing")
            assistant.didExecute("pwd", session: session)
            check(assistant.messages(for: session).last?.suggestions.first?.state == "已执行", "Adoption feedback records execution")
            let descriptor = session.terminal.process.childfd
            session.draft = "exit 7"; session.execute(); try await wait { session.exited }
            check(session.exited && !session.running && session.blocks.last?.exitCode == 7, "Shell termination decodes final process exit status")
            try await Task.sleep(nanoseconds: 200_000_000)
            check(fcntl(descriptor, F_GETFD) == -1 && errno == EBADF, "PTY descriptor closes after shell exit")
            let closing = TerminalSession(directory: "/tmp", loadShellConfig: false)
            closing.start(); try await wait { closing.ready }
            closing.draft = "sleep 30"; closing.execute()
            try await Task.sleep(nanoseconds: 150_000_000)
            let pid = closing.terminal.process.shellPid
            closing.close(); try await wait { !closing.terminal.process.running }
            check(kill(pid, 0) == -1 && errno == ESRCH, "Closing a running pane terminates and reaps its shell")
            check(!preferences.sidebarPinned && !Workspace().assistantVisible, "Navigation unpinned and AI bubble closed by default")
            let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-prompts-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: fixture) }
            for (file, contents) in [
                ".zshenv": "export ECHO_STARTUP=env\n",
                ".zprofile": "ECHO_STARTUP+=,profile\n",
                ".zshrc": "ECHO_STARTUP+=,rc\nPROMPT='MY-ZSH %~ ❯ '\nRPROMPT='RIGHT'\n",
                ".zlogin": "ECHO_STARTUP+=,login\n",
                ".bash_profile": "export ECHO_STARTUP=bash-profile\nPS1='MY-BASH \\w > '\nPROMPT_COMMAND='ECHO_PROMPTS=$(( ${ECHO_PROMPTS:-0} + 1 ))'\n"
            ] { try contents.write(to: fixture.appendingPathComponent(file), atomically: true, encoding: .utf8) }
            for shell in ["/bin/zsh", "/bin/bash"] {
                let native = TerminalSession(directory: "/tmp", shellPath: shell, environmentOverrides: ["HOME": fixture.path, "ZDOTDIR": fixture.path, "HISTFILE": "/dev/null"])
                defer { native.close() }
                native.start(); try await wait { native.ready }
                try await Task.sleep(nanoseconds: 120_000_000)
                let screen = String(decoding: native.terminal.getTerminal().getBufferAsData(), as: UTF8.self)
                check(screen.contains(shell.hasSuffix("zsh") ? "MY-ZSH" : "MY-BASH"), "\(shell) preserves custom native PS1")
                try await nativeCommand("printf '%s\\n' \"$ECHO_STARTUP\"; false", session: native)
                check(native.blocks.last?.output.contains(shell.hasSuffix("zsh") ? "env,profile,rc,login" : "bash-profile") == true && native.blocks.last?.exitCode == 1, "\(shell) startup order and native input block exit status")
                try await nativeCommand("cd /; printf 'native-output\\n'", session: native)
                check(native.directory == "/" && native.blocks.last?.output.contains("native-output") == true, "\(shell) native input retains working directory and output")
                let rapidCount = native.blocks.count
                for character in "printf 'rapid-one\\n'\rprintf 'rapid-two\\n'\r" { native.terminal.send(txt: String(character)) }
                try await wait { native.blocks.count >= rapidCount + 2 && !native.running }
                check(native.blocks[native.blocks.count - 2].output.contains("rapid-one") && native.blocks.last?.output.contains("rapid-two") == true, "\(shell) rapid individual key writes preserve command order")
                let before = native.blocks.count
                let staged = native.insert("printf 'staged-only\\n'")
                try await Task.sleep(nanoseconds: 200_000_000)
                check(staged && native.blocks.count == before && !native.running, "\(shell) AI inserts into native editor without executing")
                native.terminal.send(txt: "\r")
                try await wait { native.blocks.count > before && !native.running }
                check(native.blocks.last?.command == "printf 'staged-only\\n'" && native.blocks.last?.output.contains("staged-only") == true, "\(shell) Return executes staged native editor text")
                if shell.hasSuffix("bash") {
                    try await nativeCommand("printf '%s\\n' \"$ECHO_PROMPTS\"", session: native)
                    check(Int(native.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 >= 4, "Existing Bash PROMPT_COMMAND remains active")
                    check(!native.insert("printf one\nprintf two"), "Legacy Bash refuses unsafe multiline keystroke insertion")
                }
            }
            let blockSession = TerminalSession(directory: "/tmp", loadShellConfig: false)
            blockSession.usesBlockEditor = true
            defer { blockSession.close() }
            blockSession.start(); try await wait { blockSession.ready }
            let multiline = "printf 'first\\n'\nprintf 'second\\n'"
            check(blockSession.insert(multiline) && blockSession.draft == multiline && blockSession.blocks.isEmpty, "Block editor stages multiline recommendations without touching the PTY")
            blockSession.execute(); try await wait { !blockSession.running }
            check(blockSession.blocks.count == 1 && blockSession.blocks.last?.output.contains("first\nsecond") == true && blockSession.selectedBlockID == nil, "Inline multiline input becomes one block and returns to the next prompt")
            blockSession.draft = "printf 'live-output\\n'; sleep 30"; blockSession.execute()
            try await wait { blockSession.liveOutput.contains("live-output") }
            check(blockSession.running && blockSession.blocks.last?.exitCode == nil, "Block output streams while the process is still running")
            blockSession.interrupt(); try await wait { !blockSession.running }
            check(blockSession.blocks.last?.exitCode == 130 && blockSession.liveOutput.isEmpty, "Stopping a live block archives output and clears its live state")
            blockSession.draft = "read -r reply; printf 'got:%s\\n' \"$reply\""; blockSession.execute()
            try await Task.sleep(nanoseconds: 100_000_000)
            blockSession.sendInput("你好")
            try await wait { !blockSession.running }
            check(blockSession.blocks.last?.output.contains("got:你好") == true, "A running block accepts interactive stdin")
            let bashBlocks = TerminalSession(directory: "/tmp", loadShellConfig: false, shellPath: "/bin/bash")
            bashBlocks.usesBlockEditor = true
            defer { bashBlocks.close() }
            bashBlocks.start(); try await wait { bashBlocks.ready }
            _ = bashBlocks.insert("export ECHO_BLOCK=yes\ncd /\nprintf 'bash-multiline\\n'\nfalse")
            bashBlocks.execute(); try await wait { !bashBlocks.running }
            check(bashBlocks.blocks.count == 1 && bashBlocks.blocks.last?.exitCode == 1 && bashBlocks.directory == "/", "Bash block editor executes multiline input as one block with the final exit status")
            try await execute("printf '%s\\n' \"$ECHO_BLOCK\"", session: bashBlocks)
            check(bashBlocks.blocks.last?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes", "Block execution retains shell variables across submissions")
            let flight = SlimeFlight(from: CGPoint(x: 80, y: 200), to: CGPoint(x: 240, y: 400), started: 10, roll: true)
            let middle = flight.sample(at: 10.36), end = flight.sample(at: 11), reduced = flight.sample(at: 10.2, reduceMotion: true)
            check(middle.point.y < 300 && middle.squash.height > 1 && end.point == CGPoint(x: 240, y: 400), "Companion hop follows an arc, stretches and lands on the target block")
            check(reduced.point == flight.to && reduced.rotation == 0 && reduced.squash.width == 1, "Reduce Motion removes hopping, rotation and deformation")
            try await AISelfTests.run(check: check)
            try await AISelfTests.network(check: check)
            try await InteractionSelfTests.run(check: check)
            try await UnifiedInputSelfTests.run(check: check)
            try await TabFlowSelfTests.run(check: check)
            try await InteractiveTerminalSelfTests.run(check: check)
            EchoVisualSelfTests.run(check: check)
            try await UsageSelfTests.run(check: check)
            try PerformanceSelfTests.run(check: check)
            try await BlockToolSelfTests.run(check: check)
        } catch { failures += 1; print("FAIL unexpected error: \(error)") }
        print("\nEchoTerm: \(count - failures)/\(count) checks passed; \(failures) failures")
        return failures == 0
    }
    private static func execute(_ command: String, session: TerminalSession) async throws {
        session.draft = command; session.execute(); try await wait { !session.running }
    }
    private static func nativeCommand(_ command: String, session: TerminalSession) async throws {
        let count = session.blocks.count
        session.terminal.send(txt: command + "\r")
        try await wait { session.blocks.count > count && !session.running }
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        throw AIError.message("Timed out waiting for shell")
    }
}
#endif
