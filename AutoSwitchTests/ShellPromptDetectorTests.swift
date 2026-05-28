import XCTest
@testable import AutoSwitch

final class ShellPromptDetectorTests: XCTestCase {
    func testPromptDetectionTargetsAreTerminalScoped() {
        XCTAssertTrue(PromptDetectionTargetBundles.contains("com.apple.Terminal"))
        XCTAssertTrue(PromptDetectionTargetBundles.contains("com.mitchellh.ghostty"))
        XCTAssertFalse(PromptDetectionTargetBundles.contains("com.apple.finder"))
        XCTAssertFalse(PromptDetectionTargetBundles.contains(nil))
    }

    // MARK: - Real-world prompts from screenshots

    func testBashVersionPrompt() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "bash-5.3$ "))
        XCTAssertTrue(ShellPromptDetector.detect(in: "bash-5.3$"))
    }

    func testHostPathUserPromptFromTerminalApp() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "indincyss-MacBook-Pro:~ indincys$ "))
        XCTAssertTrue(ShellPromptDetector.detect(in: "indincyss-MacBook-Pro:~ indincys$"))
    }

    func testHostPathUserPromptFromCodexDesktop() {
        XCTAssertTrue(
            ShellPromptDetector.detect(
                in: "indincyss-MacBook-Pro:elated-driscoll-4f31fd indincys$ "
            )
        )
    }

    func testPromptWithPreviousOutput() {
        let buffer = """
        Last login: Wed May 27 09:05:33 on ttys005
        indincyss-MacBook-Pro:~ indincys$ ls
        AutoSwitch  README.md
        indincyss-MacBook-Pro:~ indincys$
        """
        XCTAssertTrue(ShellPromptDetector.detect(in: buffer))
    }

    // MARK: - Typing after prompt should stay detected

    func testHostPathPromptWithTypedCommand() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "indincyss-MacBook-Pro:~ indincys$ ls -la"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "indincyss-MacBook-Pro:~ indincys$ git commit -m \"foo\""))
    }

    func testBashVersionPromptWithTypedCommand() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "bash-5.3$ git status"))
    }

    func testPromptWithPartialChineseInputAfter() {
        // User accidentally typed in Chinese while in shell context — line still starts with prompt.
        XCTAssertTrue(ShellPromptDetector.detect(in: "bash-5.3$ 你好"))
    }

    func testMultilineBufferWithCommandTypedOnCurrentLine() {
        let buffer = """
        Last login: ...
        indincyss-MacBook-Pro:~ indincys$ ls -la
        file1.txt
        indincyss-MacBook-Pro:~ indincys$ git status
        """
        XCTAssertTrue(ShellPromptDetector.detect(in: buffer))
    }

    func testTUITakesOverClearsDetection() {
        // After running `claude`, the TUI takes over — last line is its input box, not a shell prompt.
        let buffer = """
        indincyss-MacBook-Pro:~ indincys$ claude
        ╭───────────────────────────╮
        │ > 请帮我修个 bug          │
        ╰───────────────────────────╯
        """
        XCTAssertFalse(ShellPromptDetector.detect(in: buffer))
    }

    // MARK: - Variants

    func testUserAtHostPrompt() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "user@server:/var/log# "))
        XCTAssertTrue(ShellPromptDetector.detect(in: "root@db-prod:~$"))
    }

    func testBracketUserHostPrompt() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "[root@server log]# "))
    }

    func testUserAtHostPathPrompt() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "indincys@mac ~/repo % git status"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "root@server /var/log # tail syslog"))
    }

    func testPathPrompt() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "~/repo $ make test"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "/var/log # tail system.log"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "project/subdir % git status"))
    }

    func testPlainShellPromptRequiresTrailingSpace() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "$ ls"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "% git status"))
        XCTAssertFalse(ShellPromptDetector.detect(in: "$"))
        XCTAssertFalse(ShellPromptDetector.detect(in: "$100"))
    }

    func testCommonGlyphPrompts() {
        XCTAssertTrue(ShellPromptDetector.detect(in: "❯ git status"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "➜ repo git:(main)"))
        XCTAssertTrue(ShellPromptDetector.detect(in: "λ cabal build"))
    }

    func testClaudeCodeTUIPromptDoesNotFalsePositive() {
        // Real Claude Code TUI input line — must NOT trigger English (shell) mode.
        XCTAssertFalse(ShellPromptDetector.detect(in: "› "))
        XCTAssertFalse(ShellPromptDetector.detect(in: "› hello"))
        XCTAssertFalse(ShellPromptDetector.detect(in: "› 请帮我修复"))
        XCTAssertFalse(ShellPromptDetector.detect(in: "│ › 请帮我修复"))
        XCTAssertFalse(ShellPromptDetector.detect(in: "> hello"))
    }

    // MARK: - TUI prompt detection (Chinese override)

    func testTUIPromptBare() {
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: "› "))
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: "›"))
    }

    func testTUIPromptWithTyping() {
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: "› hello"))
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: "› 请帮我修复"))
    }

    func testTUIPromptWithBoxDrawing() {
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: "│ › "))
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: "│  › 你好"))
    }

    func testTUIPromptInRealTUIBuffer() {
        let buffer = """
        ╭───────────────────────────╮
        │ › 请帮我修个 bug          │
        ╰───────────────────────────╯
        """
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: buffer))
    }

    func testTUIPromptDoesNotMatchShellPrompt() {
        XCTAssertFalse(ShellPromptDetector.detectTUIPrompt(in: "bash-5.3$ "))
        XCTAssertFalse(ShellPromptDetector.detectTUIPrompt(in: "indincyss-MacBook-Pro:~ indincys$ ls"))
    }

    func testTUIPromptDoesNotMatchGreaterThan() {
        // Plain > is too ambiguous to claim as TUI prompt; only › is recognized.
        XCTAssertFalse(ShellPromptDetector.detectTUIPrompt(in: "> hello"))
        XCTAssertFalse(ShellPromptDetector.detectTUIPrompt(in: "> "))
    }

    func testTUIPromptMatchesEvenWhenNotLastLine() {
        // TUI input boxes typically have a closing box-drawing border AFTER the
        // › input line, so we deliberately scan all lines for TUI matches.
        let buffer = """
        › current input
        ──────────────
        """
        XCTAssertTrue(ShellPromptDetector.detectTUIPrompt(in: buffer))
    }

    // MARK: - Negative cases (must not false-positive)

    func testEmptyString() {
        XCTAssertFalse(ShellPromptDetector.detect(in: ""))
    }

    func testPlainPrompt() {
        XCTAssertFalse(ShellPromptDetector.detect(in: "请帮我修一下这个 bug"))
    }

    func testPlainEnglishSentence() {
        XCTAssertFalse(ShellPromptDetector.detect(in: "Hello, world"))
    }

    func testDollarSignNotAtEnd() {
        XCTAssertFalse(ShellPromptDetector.detect(in: "It costs $100 USD"))
    }

    func testStandaloneDollarSign() {
        XCTAssertFalse(ShellPromptDetector.detect(in: "$"))
    }

    func testPercentageInSentence() {
        XCTAssertFalse(ShellPromptDetector.detect(in: "The discount is 50%"))
    }

    func testClaudeCodeTUIInputBox() {
        // Claude Code's input box typically has a "> " hint plus the user's draft.
        // Should NOT trigger English mode.
        let buffer = """
        ⏿ Assistant: 我来帮你检查这个 bug。

        > 请帮我跑一下测试
        """
        XCTAssertFalse(ShellPromptDetector.detect(in: buffer))
    }

    func testPromptInMiddleNotEnd() {
        // Output from a shell containing a prompt mid-buffer, but the cursor
        // is not at a prompt (the trailing line is a chat draft).
        let buffer = """
        $ ls
        file.txt

        要求后续变更
        """
        XCTAssertFalse(ShellPromptDetector.detect(in: buffer))
    }

    // MARK: - Long buffers

    func testLongBufferStillDetectsTrailingPrompt() {
        let prefix = String(repeating: "junk line\n", count: 500)
        XCTAssertTrue(ShellPromptDetector.detect(in: prefix + "bash-5.3$ "))
    }

    func testLongBufferIgnoresPromptOutsideTailWindow() {
        // A prompt buried deep at the start should be ignored once it's outside
        // the trailing window, and trailing content is non-prompt.
        let buffer = "bash-5.3$ ls\n" + String(repeating: "junk line content here\n", count: 200) + "随便写点中文"
        XCTAssertFalse(ShellPromptDetector.detect(in: buffer))
    }
}
