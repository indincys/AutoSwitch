import Foundation
import os.log

/// Reacts to `/` keydown to enter a transient "force English" state, then to the
/// next space / tab / return / enter to restore whichever input source was active
/// before. Useful for slash commands in Claude Code, Codex CLI, and similar tools
/// where you usually want to type the command in English even when the
/// surrounding context is Chinese.
///
/// "Is the caret at the start of a line?" is judged by `lineStartProbe`, which
/// reads the focused element's real caret/text via Accessibility
/// (``CaretContextProbe``). This is IME-proof: counting keystrokes cannot track
/// the caret column once a CJK IME is composing/committing, so deleting Chinese
/// and retyping `/` used to leave the trigger stuck. When the probe can't read the
/// element (e.g. a terminal that exposes no editable-text caret) it returns `nil`
/// and we fall back to a simple keystroke flag.
///
/// Keystrokes are delivered by the shared ``KeyboardEventHub``;
/// `handleKey(keycode:typed:)` is the entry point.
@MainActor
final class SlashTriggerMonitor {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "slash-trigger")
    private let isEnabledProvider: () -> Bool
    private let inputSourceController: InputSourceControlling
    private let lineStartProbe: @MainActor () -> Bool?
    private let reactivationDelayNanoseconds: UInt64
    var onTemporaryOverrideChanged: ((_ isActive: Bool) -> Void)?

    private var didStart = false
    private var savedSourceID: String?
    private var inSlashMode = false
    private var reactivationTask: Task<Void, Never>?
    private var temporaryOverrideActive = false
    /// Best-effort line-start flag, used only when `lineStartProbe` returns nil.
    private var fallbackAtLineStart = true

    // Key codes (ANSI): Return / keypad Enter, Tab, Space, Delete (Backspace).
    private static let returnKeyCodes: Set<Int64> = [36, 76]
    private static let tabSpaceKeyCodes: Set<Int64> = [48, 49]
    private static let backspaceKeyCode: Int64 = 51

    init(
        isEnabledProvider: @escaping () -> Bool,
        inputSourceController: InputSourceControlling,
        lineStartProbe: @escaping @MainActor () -> Bool? = { CaretContextProbe.atLineStart() },
        reactivationDelayNanoseconds: UInt64 = 80_000_000
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.inputSourceController = inputSourceController
        self.lineStartProbe = lineStartProbe
        self.reactivationDelayNanoseconds = reactivationDelayNanoseconds
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        logger.info("slash trigger monitor started")
    }

    func stop() {
        reactivationTask?.cancel()
        reactivationTask = nil
        setTemporaryOverrideActive(false)
        inSlashMode = false
        savedSourceID = nil
        fallbackAtLineStart = true
        didStart = false
    }

    func handleKey(keycode: Int64, typed: String) {
        guard isEnabledProvider() else {
            if inSlashMode { restoreIME() }
            return
        }

        if Self.returnKeyCodes.contains(keycode) {
            // Return / keypad enter: terminator, and a fresh line begins (in chat
            // inputs Enter also submits and clears the field).
            if inSlashMode { restoreIME() }
            fallbackAtLineStart = true
            return
        }

        if Self.tabSpaceKeyCodes.contains(keycode) {
            // Tab / space: terminator, but the caret stays on the same line.
            if inSlashMode { restoreIME() }
            fallbackAtLineStart = false
            return
        }

        if keycode == Self.backspaceKeyCode {
            // Deleting re-arms the line-start fallback so that clearing a line back
            // to empty lets `/` arm again. This only matters where the AX probe
            // can't read the caret (terminals, AX-blind apps); AX apps are governed
            // by the probe regardless, so a partial mid-line delete there still
            // reads as "content before caret" and does not arm.
            fallbackAtLineStart = true
            return
        }

        if typed == "/" {
            // Prefer the real caret context (IME-proof); fall back to the
            // keystroke flag only when AX can't tell us.
            let atLineStart = lineStartProbe() ?? fallbackAtLineStart
            if atLineStart {
                enterSlashMode()
            }
        }

        if !typed.isEmpty {
            // Any printable key means we're no longer at the start of the line
            // (used only by the fallback path).
            fallbackAtLineStart = false
        }
    }

    /// Treat the next keystroke as the start of a fresh line. Driven by
    /// focus / app-activation decisions (an event callback, never a poll) so
    /// switching into an empty field and immediately typing `/` still arms.
    func noteContextReset() {
        fallbackAtLineStart = true
        if inSlashMode {
            // The editing context changed out from under us; abandon transient
            // English without restoring — the focus rule already chose the input
            // source for the new context.
            inSlashMode = false
            savedSourceID = nil
        }
        reactivationTask?.cancel()
        reactivationTask = nil
        setTemporaryOverrideActive(false)
    }

    private func enterSlashMode() {
        if inSlashMode { return }
        reactivationTask?.cancel()
        reactivationTask = nil
        inSlashMode = true
        savedSourceID = inputSourceController.currentInputSourceIDValue
        guard let asciiID = asciiFallbackID() else {
            logger.info("slash trigger: no ASCII source available")
            return
        }
        if savedSourceID == asciiID {
            // Already English — nothing to do, but stay in slash mode so the
            // terminator path knows the savedSourceID for symmetry.
            return
        }
        logger.info("slash trigger: → \(asciiID, privacy: .public) (saved=\(self.savedSourceID ?? "nil", privacy: .public))")
        setTemporaryOverrideActive(true)
        if !inputSourceController.selectInputSource(id: asciiID) {
            setTemporaryOverrideActive(false)
        }
    }

    private func restoreIME() {
        guard let id = savedSourceID else {
            inSlashMode = false
            setTemporaryOverrideActive(false)
            return
        }
        inSlashMode = false
        savedSourceID = nil
        if InputSourceActivationStrategy.canReactivateInputMode(
            targetID: id,
            inputSourceController: inputSourceController
        ) {
            reactivateInputMethod(targetID: id)
            return
        }
        if id != inputSourceController.currentInputSourceIDValue {
            logger.info("slash trigger: ↩ \(id, privacy: .public)")
            _ = inputSourceController.selectInputSource(id: id)
        }
        setTemporaryOverrideActive(false)
    }

    private func setTemporaryOverrideActive(_ isActive: Bool) {
        guard temporaryOverrideActive != isActive else {
            return
        }
        temporaryOverrideActive = isActive
        onTemporaryOverrideChanged?(isActive)
    }

    private func asciiFallbackID() -> String? {
        inputSourceController.availableInputSources.first(where: {
            $0.kind == .ascii && $0.isEnabled && $0.isSelectCapable
        })?.id
    }

    private func reactivateInputMethod(targetID: String) {
        logger.info("slash trigger: ↩ \(targetID, privacy: .public) via input-mode reactivation")
        reactivationTask?.cancel()
        reactivationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await InputSourceActivationStrategy.activate(
                targetID: targetID,
                inputSourceController: self.inputSourceController,
                delayNanoseconds: self.reactivationDelayNanoseconds
            )
            self.reactivationTask = nil
            self.setTemporaryOverrideActive(false)
        }
    }
}
