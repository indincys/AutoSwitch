import AppKit
import ApplicationServices
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
@MainActor
final class TransientEnglishMonitor {
    private enum TransientMode {
        case sourceSwitch
    }

    private let logger = Logger(subsystem: "dev.autoswitch", category: "transient-english")
    private let isEnabledProvider: () -> Bool
    private let idleSecondsProvider: () -> Int
    private let permissionsCheck: () -> Bool
    private let inputSourceController: InputSourceControlling
    private let eventTapInstallerOverride: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var installedByOverride = false
    private var didStart = false

    private var transientMode: TransientMode?
    private var previousSourceID: String?
    private var lastNonASCIIInputSourceID: String?
    private var idleTimer: Timer?
    private var lastInstallFailureReason: String?
    private var shiftTapCandidateKeyCode: Int64?
    private var shiftTapCandidateSawKeyDown = false

    private var inTransientMode: Bool {
        transientMode != nil
    }

    private static let shiftKeyCodes: Set<Int64> = [56, 60]

    init(
        isEnabledProvider: @escaping () -> Bool,
        idleSecondsProvider: @escaping () -> Int,
        permissionsCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        inputSourceController: InputSourceControlling,
        eventTapInstallerOverride: (() -> Bool)? = nil
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.idleSecondsProvider = idleSecondsProvider
        self.permissionsCheck = permissionsCheck
        self.inputSourceController = inputSourceController
        self.eventTapInstallerOverride = eventTapInstallerOverride
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
        ensureTapRunning()
        installHealthTimer()
        logger.info("transient english monitor started")
    }

    func stop() {
        clearTap(disable: true)
        installedByOverride = false
        healthTimer?.invalidate()
        healthTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        didStart = false
        clearShiftTapCandidate()
    }

    private func clearTap(disable: Bool) {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if disable, let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func ensureTapRunning() {
        guard didStart else { return }
        guard permissionsCheck() else {
            logInstallFailureOnce("AX not granted; key-activity tap will retry (timer-only mode)")
            return
        }

        if let tap = eventTap {
            guard CFMachPortIsValid(tap) else {
                logger.info("key-activity tap invalid; reinstalling")
                clearTap(disable: false)
                installTap()
                return
            }
            if !CGEvent.tapIsEnabled(tap: tap) {
                logger.info("re-enabling key-activity tap from health check")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        if installedByOverride {
            return
        }

        installTap()
    }

    fileprivate func reenableTapIfNeeded() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
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
               inputSourceController.selectInputSource(id: targetID) {
                lastNonASCIIInputSourceID = targetID
                logger.info("transient english: bare Shift selected non-ascii source \(targetID, privacy: .public)")
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
            if inputSourceController.selectInputSource(id: id) {
                lastNonASCIIInputSourceID = id
            }
        }
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

    private func installTap() {
        if let eventTapInstallerOverride {
            if eventTapInstallerOverride() {
                installedByOverride = true
                lastInstallFailureReason = nil
            } else {
                logInstallFailureOnce("CGEvent.tapCreate failed for transient english tap")
            }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: transientEnglishKeyTapCallback,
            userInfo: refcon
        ) else {
            logInstallFailureOnce("CGEvent.tapCreate failed for transient english tap")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastInstallFailureReason = nil
    }

    private func installHealthTimer() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureTapRunning()
            }
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func logInstallFailureOnce(_ reason: String) {
        guard lastInstallFailureReason != reason else { return }
        lastInstallFailureReason = reason
        logger.info("\(reason, privacy: .public)")
    }
}

private let transientEnglishKeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<TransientEnglishMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            Task { @MainActor in
                monitor.reenableTapIfNeeded()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown || type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    DispatchQueue.main.async {
        Task { @MainActor in
            if type == .keyDown {
                monitor.handleKeyDownEvent()
            } else {
                monitor.handleFlagsChanged(keyCode: keyCode, flags: flags)
            }
        }
    }

    return Unmanaged.passUnretained(event)
}
