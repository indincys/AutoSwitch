import Foundation

struct ShellPromptDetector {
    /// True when the line containing the cursor (= the trailing line of `text`)
    /// starts with a recognized **shell** prompt (host:path user$, bash-X.Y$,
    /// etc.). Allowing arbitrary content after the prompt means typing a
    /// command keeps the detection active until something fundamentally
    /// changes the line (e.g. a TUI takes over).
    ///
    /// `scanAllLines: true` matches *any* line in the buffer — reserved for
    /// fallback scenarios where the cursor position is unknown.
    static func detect(in text: String, scanAllLines: Bool = false) -> Bool {
        matches(in: text, scanAllLines: scanAllLines, regexes: cachedShellRegexes)
    }

    /// True when *any* line in the trailing window starts with a recognized
    /// **TUI** prompt — currently just Claude Code's `›` input marker,
    /// optionally preceded by a box-drawing pipe. Used to force Chinese mode
    /// when the user is typing prompts to an AI CLI tool.
    ///
    /// Unlike shell-prompt detection, this defaults to scanning all lines
    /// because TUI input boxes typically render with a closing box-drawing
    /// border *after* the `› ` input line (so the cursor's line is not the
    /// trailing line of the AX text).
    static func detectTUIPrompt(in text: String, scanAllLines: Bool = true) -> Bool {
        matches(in: text, scanAllLines: scanAllLines, regexes: cachedTUIRegexes)
    }

    static let shellPatterns: [String] = [
        // host:path user$ at line start, e.g. "indincyss-MacBook-Pro:~ indincys$ ls"
        #"^[^\s\n:]+:[^\s\n]*\s+[^\s\n]+[$#%](?:$|\s)"#,
        // user@host:path$ at line start, e.g. "root@server:/var/log# "
        #"^[^\s@\n]+@[^\s:\n]+:[^\s\n]*[$#%](?:$|\s)"#,
        // [user@host dir]$ at line start
        #"^\[[^\]\n]+@[^\]\n]+\s+[^\]\n]+\][$#%](?:$|\s)"#,
        // bash-5.3$, zsh-5.9# style at line start
        #"^(?:bash|zsh|sh|dash|ksh|fish|ash)-?\d+(?:\.\d+)*[$#](?:$|\s)"#
        // Pure prompt glyphs (^[❯➜λ➤...]) are intentionally excluded — Claude
        // Code TUI uses › and would false-positive into shell-prompt → English
        // mode. Glyph-based TUI prompts are handled by `tuiPatterns` instead.
    ]

    /// TUI prompts that mean "this is an AI CLI input box, use Chinese". Kept
    /// deliberately narrow (just `›` with optional box-drawing) to avoid
    /// colliding with starship/oh-my-zsh shells that use ❯/➜.
    static let tuiPatterns: [String] = [
        // Claude Code TUI input box: › optionally preceded by box-drawing pipe
        // or whitespace. Followed by space or end of line.
        #"^[\s│┃║]*›(?:$|\s)"#
    ]

    // MARK: - Internal

    private static let tailWindow = 1024

    private static let cachedShellRegexes: [NSRegularExpression] = shellPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [])
    }

    private static let cachedTUIRegexes: [NSRegularExpression] = tuiPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [])
    }

    private static func matches(in text: String, scanAllLines: Bool, regexes: [NSRegularExpression]) -> Bool {
        guard !text.isEmpty else { return false }

        if scanAllLines {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.isEmpty { continue }
                if anyMatches(line: String(line), regexes: regexes) { return true }
            }
            return false
        }

        let tail = text.count > tailWindow ? String(text.suffix(tailWindow)) : text

        let lastLine: String
        if let newlineRange = tail.range(of: "\n", options: .backwards) {
            lastLine = String(tail[newlineRange.upperBound...])
        } else {
            lastLine = tail
        }

        guard !lastLine.isEmpty else { return false }
        return anyMatches(line: lastLine, regexes: regexes)
    }

    private static func anyMatches(line: String, regexes: [NSRegularExpression]) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for regex in regexes {
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
}
