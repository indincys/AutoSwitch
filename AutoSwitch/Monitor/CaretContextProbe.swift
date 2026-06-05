import AppKit
import ApplicationServices
import Foundation
import os.log

/// Decides, via Accessibility, whether the caret sits at the start of its line in
/// the currently focused text element.
///
/// The slash trigger uses this instead of counting keystrokes. Keystroke counting
/// cannot track the caret column once an IME is involved: typing CJK emits many
/// keyDowns (pinyin letters + candidate selection) for a couple of committed
/// characters, and backspacing deletes whole characters — so a keystroke counter
/// drifts and never returns to "line start". Reading the actual text/caret is
/// stateless and IME-proof.
///
/// Chromium/Electron apps (Claude Desktop, Codex, VS Code, …) do not expose their
/// AX tree — and therefore no focused element — until asked. When the focused
/// element is missing we set `AXManualAccessibility`/`AXEnhancedUserInterface` on
/// that app (once per pid, the same mechanism the prompt detector uses for
/// Electron terminals). The tree builds asynchronously, so the triggering probe
/// still falls back, but subsequent `/` presses read the real caret.
@MainActor
enum CaretContextProbe {
    private static let logger = Logger(subsystem: "dev.autoswitch", category: "caret-probe")
    private static var manualAXRequestedPIDs: Set<pid_t> = []

    private static let manualAccessibilityAttr = "AXManualAccessibility"
    private static let enhancedUserInterfaceAttr = "AXEnhancedUserInterface"

    /// - Returns: `true` if the caret is at the start of its line, `false` if there
    ///   is non-slash content before it on the line, or `nil` when the focused
    ///   element doesn't expose caret/value info (the caller should fall back).
    static func atLineStart() -> Bool? {
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           PromptDetectionTargetBundles.contains(bundle) {
            // Terminals expose an AXTextArea whose selectedTextRange does not track
            // the TUI's logical caret (ghostty reports caret 0 everywhere), so the
            // read would falsely say "line start". Defer to the keystroke fallback.
            logger.info("probe: terminal \(bundle, privacy: .public) → nil (caret unreliable, use fallback)")
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var focusedRaw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRaw)
        guard status == .success, let focusedRaw, CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
            // No focused element — most likely a Chromium/Electron app that hasn't
            // exposed its AX tree. Ask it to (once per pid); the tree builds async,
            // so fall back this time and let the next press read the caret.
            requestManualAccessibilityForFrontmostApp()
            return nil
        }
        return lineStart(of: focusedRaw as! AXUIElement)
    }

    private static func lineStart(of focused: AXUIElement) -> Bool? {
        let role = copyString(focused, kAXRoleAttribute) ?? "?"
        guard let caret = copyCaretLocation(focused) else {
            logger.info("probe: role=\(role, privacy: .public) no selectedTextRange → nil")
            return nil
        }
        if caret <= 0 {
            logger.info("probe: role=\(role, privacy: .public) caret=0 → lineStart=true")
            return true
        }
        guard let value = copyString(focused, kAXValueAttribute) else {
            logger.info("probe: role=\(role, privacy: .public) caret=\(caret, privacy: .public) no value → nil")
            return nil
        }

        let ns = value as NSString
        let clamped = min(max(caret, 0), ns.length)
        let head = ns.substring(to: clamped) as NSString
        let lastNewline = head.range(of: "\n", options: .backwards)
        let lineStart = lastNewline.location == NSNotFound ? 0 : lastNewline.location + 1
        var linePrefix = head.substring(from: lineStart)
        // Tolerate a just-inserted leading slash: the listen-only tap may run after
        // the app already inserted the "/" the user pressed.
        if linePrefix == "/" { linePrefix = "" }
        let result = linePrefix.isEmpty
        logger.info("probe: role=\(role, privacy: .public) caret=\(caret, privacy: .public) prefixLen=\(linePrefix.count, privacy: .public) → lineStart=\(result, privacy: .public)")
        return result
    }

    private static func requestManualAccessibilityForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            logger.info("probe: no focused element, no frontmost app → nil")
            return
        }
        let pid = app.processIdentifier
        guard !manualAXRequestedPIDs.contains(pid) else {
            logger.info("probe: no focused element for \(app.bundleIdentifier ?? "nil", privacy: .public) (AX already requested) → nil")
            return
        }
        manualAXRequestedPIDs.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(appElement, manualAccessibilityAttr as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttr as CFString, kCFBooleanTrue)
        logger.info("probe: enabled manual AX for \(app.bundleIdentifier ?? "nil", privacy: .public) pid=\(pid, privacy: .public) → nil (retry next press)")
    }

    private static func copyCaretLocation(_ element: AXUIElement) -> Int? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw,
              CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue((raw as! AXValue), .cfRange, &range) else { return nil }
        return range.location
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let str = raw as? String else {
            return nil
        }
        return str
    }
}
