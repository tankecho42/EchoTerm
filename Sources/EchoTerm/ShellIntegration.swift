import Foundation
import AppKit
import SwiftTerm

/// A byte-oriented parser: UTF-8 and OSC frames may span arbitrary PTY reads.
struct ShellStreamParser {
    enum Event: Equatable { case output([UInt8]), began(String), prompt(Int, String) }
    let token: String
    private var pending: [UInt8] = []
    init(token: String) { self.token = token }
    mutating func feed(_ bytes: [UInt8]) -> [Event] {
        pending += bytes
        let prefix = Array("\u{1B}]777;EchoTerm;\(token);".utf8)
        var result: [Event] = []
        while !pending.isEmpty {
            if pending.starts(with: prefix) {
                guard let end = pending.firstIndex(of: 7) else {
                    if pending.count > 131072 { result.append(.output([pending.removeFirst()])); continue }
                    break
                }
                let message = String(decoding: pending[prefix.count..<end], as: UTF8.self)
                pending.removeFirst(end + 1)
                let fields = message.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                func decode(_ value: String) -> String { Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
                if fields.count == 2, fields[0] == "B" { result.append(.began(decode(fields[1]))) }
                else if fields.count == 3, fields[0] == "D", let status = Int(fields[1]) { result.append(.prompt(status, decode(fields[2]))) }
            } else if pending.count < prefix.count && prefix.starts(with: pending) {
                break
            } else {
                // Forward complete runs, retaining a possible partial marker at the end.
                var count = 1
                while count < pending.count && pending[count] != 27 { count += 1 }
                result.append(.output(Array(pending.prefix(count))))
                pending.removeFirst(count)
            }
        }
        return result
    }
}

final class BlockTerminalView: TerminalView, TerminalViewDelegate {
    let process = PTYProcess()
    private var installedTheme: TerminalTheme?
    func applyPalette(_ theme: TerminalTheme) {
        guard installedTheme != theme else { return }
        installedTheme = theme
        installColors(theme.ansiColors.map { hex in
            SwiftTerm.Color(red: UInt16((hex >> 16) & 255) * 257, green: UInt16((hex >> 8) & 255) * 257, blue: UInt16(hex & 255) * 257)
        })
    }
    private func connect() {
        terminalDelegate = self
        process.onData = { [weak self] bytes in self?.dataReceived(slice: bytes[...]) }
        process.onExit = { [weak self] code in self?.onExit?(code) }
    }
    var streamParser = ShellStreamParser(token: "")
    var onEvent: ((ShellStreamParser.Event) -> Void)?
    var onExit: ((Int32?) -> Void)?
    var onFocus: (() -> Void)?
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onNativeInput: (() -> Void)?
    var onNativeFocusRequested: (() -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var keyboardFocusAllowed = false
    var nativeInputAllowed = false
    private var focusPending = false
    private var nativeInputDepth = 0
    private var protocolInputDepth = 0
    private var eventMonitor: Any?
    private func withNativeInput(_ operation: () -> Void) {
        guard nativeInputAllowed, let window, window.isKeyWindow, window.firstResponder === self else { return }
        nativeInputDepth += 1
        defer { nativeInputDepth -= 1 }
        operation()
    }
    /// The local event monitor and GUI tests share this path. Returning true
    /// means AppKit must not deliver the same key a second time.
    @discardableResult func dispatchNativeKeyDown(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, event.window === window,
              window.firstResponder === self else { return false }
        // Resolve registered app shortcuts exactly once. Unmatched Command
        // combinations still need the same native-input gate and provenance.
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        guard nativeInputAllowed, window.isKeyWindow else { return true }
        withNativeInput { self.keyDown(with: event) }
        return true
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        withNativeInput { super.insertText(string, replacementRange: replacementRange) }
    }
    override func paste(_ sender: Any) { withNativeInput { super.paste(sender) } }
    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            if event.type == .keyDown { return self.dispatchNativeKeyDown(event) ? nil : event }
            if let content = window.contentView {
                // hitTest takes its point in the receiver's superview coordinates.
                // Checking the topmost target also respects SwiftUI overlays.
                let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
                if let hit = content.hitTest(point), hit === self || hit.isDescendant(of: self) {
                    self.onNativeFocusRequested?()
                }
            }
            return event
        }
    }
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        protocolInputDepth += 1
        defer { protocolInputDepth -= 1 }
        super.send(source: source, data: data)
    }
    func requestKeyboardFocus() {
        guard keyboardFocusAllowed, !focusPending else { return }
        focusPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusPending = false
            guard self.keyboardFocusAllowed, let window = self.window,
                  window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }
    override init(frame: CGRect) { super.init(frame: frame); connect(); installEventMonitor() }
    required init?(coder: NSCoder) { super.init(coder: coder); connect(); installEventMonitor() }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    func dataReceived(slice: ArraySlice<UInt8>) {
        for event in streamParser.feed(Array(slice)) {
            if case .output(let bytes) = event { feed(byteArray: bytes[...]) }
            onEvent?(event)
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if nativeInputDepth > 0 && !nativeInputAllowed { return }
        if window?.firstResponder === self { onFocus?() }
        if nativeInputDepth > 0, protocolInputDepth == 0, !data.isEmpty { onNativeInput?() }
        onInput?(data); process.send(data: data)
    }
    func getWindowSize() -> winsize {
        winsize(ws_row: UInt16(max(1, getTerminal().rows)), ws_col: UInt16(max(1, getTerminal().cols)), ws_xpixel: UInt16(max(0, frame.width)), ws_ypixel: UInt16(max(0, frame.height)))
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(getTerminal().cols, getTerminal().rows)
        guard process.running else { return }
        var size = getWindowSize()
        _ = ioctl(process.childfd, TIOCSWINSZ, &size)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

enum ShellKind: String { case zsh, bash }

enum ShellChoice: String, CaseIterable, Identifiable {
    case system = "系统默认", zsh = "Zsh", bash = "Bash"
    var id: String { rawValue }
    var executable: String {
        switch self {
        case .zsh: return "/bin/zsh"
        case .bash: return "/bin/bash"
        case .system:
            if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell {
                let shell = String(cString: path)
                if ["zsh", "bash"].contains(URL(fileURLWithPath: shell).lastPathComponent), FileManager.default.isExecutableFile(atPath: shell) { return shell }
            }
            return "/bin/zsh"
        }
    }
}

enum ShellBootstrap {
    static func create(token: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Preserve startup order and restore the user's ZDOTDIR after installing hooks.
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            var wrapper = """
            if [[ "$ECHOTERM_LOAD_CONFIG" == 1 ]]; then
              ZDOTDIR="$ECHOTERM_USER_ZDOTDIR"
              [[ -r "$ZDOTDIR/\(file)" ]] && source "$ZDOTDIR/\(file)"
              ECHOTERM_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
            fi
            export ZDOTDIR="$ECHOTERM_BOOTSTRAP"

            """
            if file == ".zlogin" {
                wrapper += #"""
                if [[ "$ECHOTERM_HAD_ZDOTDIR" == 1 || "$ECHOTERM_USER_ZDOTDIR" != "$HOME" ]]; then
                  export ZDOTDIR="$ECHOTERM_USER_ZDOTDIR"
                else
                  unset ZDOTDIR
                fi
                function _echoterm_preexec() {
                  local encoded=$(builtin print -rn -- "$1" | /usr/bin/base64 | /usr/bin/tr -d '\n')
                  builtin printf '\e]777;EchoTerm;%s;B;%s\a' "$ECHOTERM_TOKEN" "$encoded"
                }
                function _echoterm_precmd() {
                  local result=$?
                  builtin print -r -- "$PATH" > "$ECHOTERM_BOOTSTRAP/path"
                  builtin print -rl -- ${(k)builtins} ${(k)functions} ${(k)aliases} > "$ECHOTERM_BOOTSTRAP/names"
                  local encoded=$(builtin print -rn -- "$PWD" | /usr/bin/base64 | /usr/bin/tr -d '\n')
                  builtin printf '\e]777;EchoTerm;%s;D;%s;%s\a' "$ECHOTERM_TOKEN" "$result" "$encoded"
                }
                preexec_functions=(_echoterm_preexec ${preexec_functions:#_echoterm_preexec})
                precmd_functions=(_echoterm_precmd ${precmd_functions:#_echoterm_precmd})
                function _echoterm_insert() {
                  BUFFER=$(<"$ECHOTERM_INSERT_FILE")
                  CURSOR=${#BUFFER}
                }
                zle -N _echoterm_insert
                bindkey '\e[99~' _echoterm_insert
                bindkey -M viins '\e[99~' _echoterm_insert
                bindkey -M vicmd '\e[99~' _echoterm_insert
                """#
            }
            try wrapper.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let bash = #"""
        # Interactive bash startup, without changing PS1, PS2 or the user's files.
        if [[ "$ECHOTERM_LOAD_CONFIG" == 1 ]]; then
          [[ -r /etc/profile ]] && source /etc/profile
          _echoterm_profile_loaded=0
          for _echoterm_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [[ -r "$_echoterm_profile" ]]; then
              source "$_echoterm_profile"
              _echoterm_profile_loaded=1
              break
            fi
          done
          if [[ "$_echoterm_profile_loaded" == 0 && -r "$HOME/.bashrc" ]]; then source "$HOME/.bashrc"; fi
        fi
        _echoterm_armed=0
        _echoterm_previous_debug=$(trap -p DEBUG)
        if [[ -n "$_echoterm_previous_debug" ]]; then
          _echoterm_previous_debug=${_echoterm_previous_debug#trap -- }
          _echoterm_previous_debug=${_echoterm_previous_debug% DEBUG}
          eval "_echoterm_previous_debug=$_echoterm_previous_debug"
        fi
        _echoterm_debug() {
          local previous=$1 next=$2 line encoded
          if [[ "$_echoterm_armed" == 1 && "$next" != _echoterm_prompt && "$next" != _echoterm_arm && "${BASH_SUBSHELL:-0}" == 0 ]]; then
            _echoterm_armed=0
            line=$(HISTTIMEFORMAT= builtin history 1)
            if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+(.*)$ ]]; then line=${BASH_REMATCH[1]}; else line=$next; fi
            encoded=$(builtin printf '%s' "$line" | /usr/bin/base64 | /usr/bin/tr -d '\n')
            builtin printf '\e]777;EchoTerm;%s;B;%s\a' "$ECHOTERM_TOKEN" "$encoded"
          fi
          return "$previous"
        }
        _echoterm_prompt() {
          _echoterm_result=$?
          _echoterm_armed=0
          builtin printf '%s\n' "$PATH" > "$ECHOTERM_BOOTSTRAP/path"
          builtin compgen -A builtin -A function -A alias > "$ECHOTERM_BOOTSTRAP/names"
          local encoded=$(builtin printf '%s' "$PWD" | /usr/bin/base64 | /usr/bin/tr -d '\n')
          builtin printf '\e]777;EchoTerm;%s;D;%s;%s\a' "$ECHOTERM_TOKEN" "$_echoterm_result" "$encoded"
          return "$_echoterm_result"
        }
        _echoterm_arm() { _echoterm_armed=1; return "${_echoterm_result:-0}"; }
        if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a '* ]]; then
          PROMPT_COMMAND=(_echoterm_prompt "${PROMPT_COMMAND[@]}" _echoterm_arm)
        else
          PROMPT_COMMAND="_echoterm_prompt;${PROMPT_COMMAND:+$PROMPT_COMMAND;}_echoterm_arm"
        fi
        trap '_echoterm_debug "$?" "$BASH_COMMAND"; if [[ -n "$_echoterm_previous_debug" ]]; then eval "$_echoterm_previous_debug"; fi' DEBUG
        if (( BASH_VERSINFO[0] >= 4 )); then
          _echoterm_insert() { READLINE_LINE=$(<"$ECHOTERM_INSERT_FILE"); READLINE_POINT=${#READLINE_LINE}; }
          bind -x '"\e[99~":_echoterm_insert'
        fi
        """#
        try bash.write(to: directory.appendingPathComponent("bashrc"), atomically: true, encoding: .utf8)
        return directory
    }
}
