import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// Safety-net for places shell-prompt detection can't reach (Codex / Claude
/// Desktop's embedded terminals, custom shells, etc.).
///
/// When the user manually switches to an ASCII source — typically by tapping
/// Shift to toggle their Chinese IME — start an idle timer. Any subsequent
/// keystroke resets the timer; if it expires, automatically restore whatever
/// non-ASCII source was active before. The user can also tap Shift / pick a
/// different source themselves to exit immediately.
@MainActor
final class TransientEnglishMonitor {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "transient-english")
    private let isEnabledProvider: () -> Bool
    private let idleSecondsProvider: () -> Int
    private let permissionsCheck: () -> Bool
    private let inputSourceController: InputSourceControlling

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didStart = false

    private var inTransientMode = false
    private var previousSourceID: String?
    private var idleTimer: Timer?

    init(
        isEnabledProvider: @escaping () -> Bool,
        idleSecondsProvider: @escaping () -> Int,
        permissionsCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        inputSourceController: InputSourceControlling
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.idleSecondsProvider = idleSecondsProvider
        self.permissionsCheck = permissionsCheck
        self.inputSourceController = inputSourceController
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
        if permissionsCheck() {
            installTap()
        } else {
            logger.info("AX not granted; key-activity tap not installed (timer-only mode)")
        }
        logger.info("transient english monitor started")
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        idleTimer?.invalidate()
        idleTimer = nil
        didStart = false
    }

    fileprivate func reenableTapIfNeeded() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handleKeyActivity() {
        guard inTransientMode else { return }
        scheduleIdleTimer()
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
        enterTransientMode(savedPreviousID: previousID)
    }

    private func enterTransientMode(savedPreviousID: String) {
        inTransientMode = true
        previousSourceID = savedPreviousID
        scheduleIdleTimer()
        logger.info(
            "transient english: entered, saved=\(savedPreviousID, privacy: .public), idle=\(self.idleSecondsProvider())s"
        )
    }

    private func exitTransientMode(restore: Bool, reason: String) {
        idleTimer?.invalidate()
        idleTimer = nil
        let saved = previousSourceID
        let wasIn = inTransientMode
        inTransientMode = false
        previousSourceID = nil
        if wasIn {
            logger.info("transient english: exited (\(reason, privacy: .public)) restore=\(restore, privacy: .public)")
        }
        if restore, let saved {
            _ = inputSourceController.selectInputSource(id: saved)
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

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: transientEnglishKeyTapCallback,
            userInfo: refcon
        ) else {
            logger.error("CGEvent.tapCreate failed for transient english tap")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    DispatchQueue.main.async {
        Task { @MainActor in
            monitor.handleKeyActivity()
        }
    }

    return Unmanaged.passUnretained(event)
}
