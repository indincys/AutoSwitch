import CoreGraphics
import Foundation
import os.log

/// Safety-net for places shell-prompt detection can't reach (Codex / Claude
/// Desktop's embedded terminals, custom shells, etc.).
///
/// When the user temporarily switches from a non-ASCII source to an ASCII source,
/// start an idle timer. Any subsequent keystroke resets the timer; if it expires,
/// automatically restore whatever non-ASCII source was active before. Bare Shift
/// can also drive that system input-source toggle directly when third-party IME
/// internal Shift toggles are disabled.
///
/// Keystrokes and modifier changes are delivered by the shared
/// ``KeyboardEventHub`` (this type no longer owns an event tap):
/// `handleKeyDownEvent()` and `handleFlagsChanged(keyCode:flags:)` are the entry
/// points.
@MainActor
final class TransientEnglishMonitor {
    private enum TransientMode {
        case sourceSwitch
    }

    private let logger = Logger(subsystem: "dev.autoswitch", category: "transient-english")
    private let isEnabledProvider: () -> Bool
    private let idleSecondsProvider: () -> Int
    private let inputSourceController: InputSourceControlling
    private let reactivationDelayNanoseconds: UInt64

    private var didStart = false
    private var transientMode: TransientMode?
    private var previousSourceID: String?
    private var lastNonASCIIInputSourceID: String?
    private var idleTimer: Timer?
    private var reactivationTask: Task<Void, Never>?
    private var shiftTapCandidateKeyCode: Int64?
    private var shiftTapCandidateSawKeyDown = false

    private var inTransientMode: Bool {
        transientMode != nil
    }

    private static let shiftKeyCodes: Set<Int64> = [56, 60]

    init(
        isEnabledProvider: @escaping () -> Bool,
        idleSecondsProvider: @escaping () -> Int,
        inputSourceController: InputSourceControlling,
        reactivationDelayNanoseconds: UInt64 = InputSourceActivationStrategy.defaultReactivationDelayNanoseconds
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.idleSecondsProvider = idleSecondsProvider
        self.inputSourceController = inputSourceController
        self.reactivationDelayNanoseconds = reactivationDelayNanoseconds
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        // Hook into the controller's user-initiated change events.
        inputSourceController.onUserInitiatedChange = { [weak self] prev, current in
            Task { @MainActor in
                self?.handleUserInitiatedChange(previousID: prev, currentID: current)
            }
        }
        rememberCurrentNonASCIIInputSource()
        logger.info("transient english monitor started")
    }

    func stop() {
        reactivationTask?.cancel()
        reactivationTask = nil
        idleTimer?.invalidate()
        idleTimer = nil
        didStart = false
        clearShiftTapCandidate()
    }

    func handleKeyDownEvent() {
        if shiftTapCandidateKeyCode != nil {
            shiftTapCandidateSawKeyDown = true
        }
        handleKeyActivity()
    }

    private func handleKeyActivity() {
        guard inTransientMode else { return }
        scheduleIdleTimer()
    }

    func handleFlagsChanged(keyCode: Int64, flags: CGEventFlags) {
        guard Self.shiftKeyCodes.contains(keyCode) else { return }

        guard isEnabledProvider() else {
            clearShiftTapCandidate()
            if inTransientMode {
                exitTransientMode(restore: false, reason: "feature disabled")
            }
            return
        }

        let isShiftDown = flags.contains(.maskShift)
        if isShiftDown {
            guard flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty,
                  let currentID = inputSourceController.currentInputSourceIDValue,
                  let current = inputSourceController.inputSource(with: currentID) else {
                clearShiftTapCandidate()
                return
            }
            if current.kind == .ascii, preferredNonASCIIInputSourceID() == nil {
                clearShiftTapCandidate()
                return
            }
            shiftTapCandidateKeyCode = keyCode
            shiftTapCandidateSawKeyDown = false
            return
        }

        guard shiftTapCandidateKeyCode == keyCode else {
            clearShiftTapCandidate()
            return
        }

        let sawKeyDown = shiftTapCandidateSawKeyDown
        clearShiftTapCandidate()
        guard !sawKeyDown else { return }
        handleBareShiftTap()
    }

    func handleFocusDecision(_ decision: SwitchDecision) {
        guard isEnabledProvider() else {
            if inTransientMode {
                exitTransientMode(restore: false, reason: "feature disabled")
            }
            return
        }
        if let target = inputSourceController.inputSource(with: decision.targetInputSourceID),
           target.kind != .ascii {
            lastNonASCIIInputSourceID = decision.targetInputSourceID
        }
        guard inTransientMode else { return }
        exitTransientMode(restore: false, reason: "focus decision \(decision.targetInputSourceID)")
    }

    private func handleUserInitiatedChange(previousID: String?, currentID: String?) {
        guard isEnabledProvider() else {
            if inTransientMode {
                exitTransientMode(restore: false, reason: "feature disabled")
            }
            return
        }

        guard let currentID,
              let current = inputSourceController.inputSource(with: currentID) else {
            return
        }
        if current.kind != .ascii {
            lastNonASCIIInputSourceID = currentID
        }

        if inTransientMode {
            // Already in transient mode — any user-initiated change means they
            // want to take control. Drop the timer and don't auto-restore.
            exitTransientMode(restore: false, reason: "user manual switch to \(currentID)")
            return
        }

        // Not in transient mode. Detect "manual switch from non-ascii to ascii".
        guard current.kind == .ascii else { return }
        guard let previousID,
              let previous = inputSourceController.inputSource(with: previousID),
              previous.kind != .ascii else {
            return
        }
        enterTransientMode(savedPreviousID: previousID, mode: .sourceSwitch)
    }

    private func handleBareShiftTap() {
        guard let currentID = inputSourceController.currentInputSourceIDValue,
              let current = inputSourceController.inputSource(with: currentID) else {
            return
        }

        if current.kind == .ascii {
            if inTransientMode {
                exitTransientMode(restore: true, reason: "user shift toggled back")
                return
            }
            if let targetID = preferredNonASCIIInputSourceID(),
               activateNonASCIIInputSource(targetID, reason: "bare Shift") {
                logger.info("transient english: bare Shift restoring non-ascii source \(targetID, privacy: .public)")
            }
            return
        }

        guard !inTransientMode else { return }
        guard let asciiID = preferredASCIIInputSourceID(excluding: currentID) else {
            logger.error("transient english: no ascii input source available for bare Shift")
            return
        }
        guard inputSourceController.selectInputSource(id: asciiID) else {
            return
        }
        lastNonASCIIInputSourceID = currentID
        enterTransientMode(savedPreviousID: currentID, mode: .sourceSwitch)
    }

    private func enterTransientMode(savedPreviousID: String, mode: TransientMode) {
        transientMode = mode
        previousSourceID = savedPreviousID
        scheduleIdleTimer()
        logger.info(
            "transient english: entered mode=\(String(describing: mode), privacy: .public), saved=\(savedPreviousID, privacy: .public), idle=\(self.idleSecondsProvider())s"
        )
    }

    private func exitTransientMode(restore: Bool, reason: String) {
        idleTimer?.invalidate()
        idleTimer = nil
        let saved = previousSourceID
        let mode = transientMode
        let wasIn = inTransientMode
        transientMode = nil
        previousSourceID = nil
        clearShiftTapCandidate()
        if wasIn {
            logger.info("transient english: exited (\(reason, privacy: .public)) restore=\(restore, privacy: .public)")
        }
        if restore, let saved, let mode {
            restoreSavedSource(id: saved, mode: mode)
        }
    }

    private func scheduleIdleTimer() {
        idleTimer?.invalidate()
        let seconds = max(1, idleSecondsProvider())
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.handleIdleTimeout()
            }
        }
        idleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleIdleTimeout() {
        guard inTransientMode else { return }
        exitTransientMode(restore: true, reason: "idle timeout")
    }

    func fireIdleTimeoutForTesting() {
        handleIdleTimeout()
    }

    private func restoreSavedSource(id: String, mode: TransientMode) {
        switch mode {
        case .sourceSwitch:
            _ = activateNonASCIIInputSource(id, reason: "restore")
        }
    }

    private func activateNonASCIIInputSource(_ targetID: String, reason: String) -> Bool {
        guard let target = inputSourceController.inputSource(with: targetID),
              target.kind != .ascii,
              target.isEnabled,
              target.isSelectCapable else {
            return false
        }

        if InputSourceActivationStrategy.canReactivateInputMode(
            targetID: targetID,
            inputSourceController: inputSourceController
        ) {
            reactivationTask?.cancel()
            reactivationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let didActivate = await InputSourceActivationStrategy.activate(
                    targetID: targetID,
                    inputSourceController: self.inputSourceController,
                    delayNanoseconds: self.reactivationDelayNanoseconds
                )
                self.reactivationTask = nil
                if didActivate {
                    self.lastNonASCIIInputSourceID = targetID
                    self.logger.info("transient english: \(reason, privacy: .public) reactivated non-ascii source \(targetID, privacy: .public)")
                } else {
                    self.logger.error("transient english: \(reason, privacy: .public) failed to reactivate \(targetID, privacy: .public)")
                }
            }
            return true
        }

        if inputSourceController.selectInputSource(id: targetID) {
            lastNonASCIIInputSourceID = targetID
            return true
        }
        return false
    }

    private func clearShiftTapCandidate() {
        shiftTapCandidateKeyCode = nil
        shiftTapCandidateSawKeyDown = false
    }

    private func rememberCurrentNonASCIIInputSource() {
        guard let currentID = inputSourceController.currentInputSourceIDValue,
              let current = inputSourceController.inputSource(with: currentID),
              current.kind != .ascii else {
            return
        }
        lastNonASCIIInputSourceID = currentID
    }

    private func preferredASCIIInputSourceID(excluding excludedID: String?) -> String? {
        inputSourceController.availableInputSources.first {
            $0.id != excludedID && $0.kind == .ascii && $0.isEnabled && $0.isSelectCapable
        }?.id
    }

    private func preferredNonASCIIInputSourceID() -> String? {
        if let lastNonASCIIInputSourceID,
           let source = inputSourceController.inputSource(with: lastNonASCIIInputSourceID),
           source.kind != .ascii,
           source.isEnabled,
           source.isSelectCapable {
            return lastNonASCIIInputSourceID
        }
        return inputSourceController.availableInputSources.first {
            $0.kind != .ascii && $0.isEnabled && $0.isSelectCapable
        }?.id
    }
}
