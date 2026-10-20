#if DEBUG
import Foundation

/// Pure session fixtures: no shell, PTY, provider, application window or input
/// injection is started by these history-navigation checks.
@MainActor enum HistoryNavigationSelfTests {
    static func run(check: (Bool, String) -> Void) {
        ordinaryHistory(check: check)
        prefixAndRestore(check: check)
        editedDrafts(check: check)
        unicodeAndNoMatches(check: check)
        submissionAndClear(check: check)
    }

    private static func session(_ commands: [String]) -> TerminalSession {
        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        session.blocks = commands.map { command in
            var block = CommandBlock(command: command, directory: "/tmp")
            block.exitCode = 0
            return block
        }
        return session
    }

    private static func ordinaryHistory(check: (Bool, String) -> Void) {
        let session = session(["oldest", "middle", "latest"])
        defer { session.close() }
        session.history(1)
        check(session.draft.isEmpty, "Down without active history navigation preserves an empty draft")
        session.history(-1)
        check(session.draft == "latest", "Empty-draft Up recalls the newest ordinary command")
        session.history(-1); session.history(-1); session.history(-1)
        check(session.draft == "oldest", "History Up stops at the oldest command without wrapping")
        session.history(1); session.history(1)
        check(session.draft == "latest", "History Down moves forward through the same command timeline")
        session.history(1); session.history(1)
        check(session.draft.isEmpty, "Down beyond the newest command restores the original empty draft and then remains there")

        let duplicates = self.session(["repeat", "between", "repeat"])
        defer { duplicates.close() }
        var demo = CommandBlock(command: "demo must not recall", directory: "/tmp"); demo.isDemo = true
        let ai = CommandBlock(command: "AI question must not recall", directory: "/tmp", assistantReplyID: UUID())
        duplicates.blocks += [demo, ai]
        duplicates.history(-1)
        let newest = duplicates.draft
        duplicates.history(-1)
        let middle = duplicates.draft
        duplicates.history(-1)
        check([newest, middle, duplicates.draft] == ["repeat", "between", "repeat"],
              "History retains duplicate commands in time order while excluding demo and AI blocks")
    }

    private static func prefixAndRestore(check: (Bool, String) -> Void) {
        let session = session(["git log", "pwd", "git status", "git stash", "echo unrelated"])
        defer { session.close() }
        session.draft = "git "
        session.history(1); session.history(0)
        check(session.draft == "git ", "Down or a zero direction cannot clear a partly written command before navigation")
        session.history(-1)
        check(session.draft == "git stash", "Prefix history starts at the newest matching command, skipping unrelated commands")
        session.history(-1); session.history(-1); session.history(-1)
        check(session.draft == "git log", "Recalled text does not replace the frozen original prefix while moving backward")
        session.history(1); session.history(1)
        check(session.draft == "git stash", "Down visits only the commands matching the first-Up prefix")
        session.history(1)
        check(session.draft == "git ", "Moving beyond the newest prefix match restores the original partial draft exactly")
        session.history(-1)
        check(session.draft == "git stash", "Restored draft starts a fresh prefix navigation on the next Up")
        let recalled = session.draft
        session.draft = recalled
        session.history(-1)
        check(session.draft == "git status", "A same-value binding write does not reset active history navigation")
    }

    private static func editedDrafts(check: (Bool, String) -> Void) {
        let session = session(["git log", "git status", "echo first", "echo second"])
        defer { session.close() }
        session.draft = "git"
        session.history(-1)
        session.draft = "echo "
        session.history(1)
        check(session.draft == "echo ", "Editing a recalled command ends navigation; a following Down keeps the edited draft")
        session.history(-1); session.history(-1)
        check(session.draft == "echo first", "The first Up after a manual edit freezes the new prefix rather than the previous query")
        session.draft = "git l"
        session.history(-1); session.history(1)
        check(session.draft == "git l", "A second manual edit becomes its own exact restoration draft")
        session.draft = ""
        session.history(-1)
        check(session.draft == "echo second", "Manually clearing a recalled draft resets prefix matching to the full command history")
    }

    private static func unicodeAndNoMatches(check: (Bool, String) -> Void) {
        let session = session(["echo old", "打印 中文🙂一", "echo newest", "打印 中文🙂二", "  spaced one", "  spaced two"])
        defer { session.close() }
        session.draft = "打印 中文🙂"
        session.history(-1); session.history(-1)
        check(session.draft == "打印 中文🙂一", "Unicode and emoji prefixes navigate whole commands without byte-index slicing")
        session.history(1); session.history(1)
        check(session.draft == "打印 中文🙂", "Unicode prefix navigation restores the original draft without normalization or trimming")
        session.draft = "  spaced "
        session.history(-1); session.history(1)
        check(session.draft == "  spaced ", "History matching and restoration preserve leading and trailing whitespace")
        session.draft = "unmatched 中文"
        session.history(-1); session.history(1)
        check(session.draft == "unmatched 中文", "A prefix without matches leaves the draft intact for both Up and Down")
        session.draft = "Echo"
        session.history(-1)
        check(session.draft == "Echo", "Prefix matching respects command case")
        let empty = self.session([])
        defer { empty.close() }
        empty.draft = "retained draft"; empty.history(-1); empty.history(1)
        check(empty.draft == "retained draft", "An empty command history never overwrites a draft")
    }

    private static func submissionAndClear(check: (Bool, String) -> Void) {
        let session = session(["git log", "git status", "echo later"])
        defer { session.close() }
        session.draft = "git"
        session.history(-1)
        check(session.execute() == nil, "A not-ready session rejects submission without starting a process")
        session.history(-1)
        check(session.draft == "git log", "Rejected submission preserves the active prefix-navigation position")
        session.ready = true
        let submitted = session.execute()
        check(submitted != nil && session.draft.isEmpty && !session.terminal.process.running,
              "Successful session submission resets navigation without requiring a PTY in this fixture")
        // Only the pure model state is completed here; no shell was launched.
        session.running = false
        if let index = session.blocks.indices.last { session.blocks[index].exitCode = 0; session.blocks[index].finishedAt = Date() }
        session.history(-1); session.history(1)
        check(session.draft.isEmpty, "After submission, history restores the new empty draft rather than an old frozen prefix")

        session.draft = "git"
        session.history(-1)
        session.clear()
        session.history(-1)
        check(session.draft == "git log", "Clearing recorded history discards its frozen navigation without changing the current draft")
        session.history(1)
        check(session.draft == "git log", "Down after clearing does not resurrect the previous pre-navigation draft")
    }
}
#endif
