import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// The single system-wide keyboard event tap shared by every keystroke-driven
/// feature (slash trigger, transient English, shell-prompt detection burst).
///
/// Previously each of those features installed its own listen-only
/// `cgSessionEventTap`, so every keystroke was delivered to 2–3 taps and each
/// feature carried a duplicate install / re-enable / 5s health-check path. That
/// multiplied per-keystroke main-actor hops and widened the surface for "a tap
/// got disabled and a key leaked through in the wrong language".
///
/// The hub owns exactly one tap (`keyDown | flagsChanged`, listen-only) and fans
/// decoded events out to registered handlers on the main actor. Subscribers do
/// their own feature gating; the hub only manages the tap lifecycle.
@MainActor
final class KeyboardEventHub {
    struct KeyDown {
        let keycode: Int64
        let characters: String
    }

    struct FlagsChanged {
        let keycode: Int64
        let flags: CGEventFlags
    }

    private let logger = Logger(subsystem: "dev.autoswitch", category: "keyboard-hub")
    private let permissionsCheck: () -> Bool
    private let eventTapInstallerOverride: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: Timer?
    private var installedByOverride = false
    private var didStart = false
    private var lastInstallFailureReason: String?

    private var keyDownHandlers: [(KeyDown) -> Void] = []
    private var flagsChangedHandlers: [(FlagsChanged) -> Void] = []

    init(
        permissionsCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        eventTapInstallerOverride: (() -> Bool)? = nil
    ) {
        self.permissionsCheck = permissionsCheck
        self.eventTapInstallerOverride = eventTapInstallerOverride
    }

    /// Register a handler for every keyDown. Handlers run on the main actor in
    /// registration order. Intended to be called once per subscriber at startup.
    func addKeyDownHandler(_ handler: @escaping (KeyDown) -> Void) {
        keyDownHandlers.append(handler)
    }

    /// Register a handler for modifier (flags) changes — e.g. bare-Shift taps.
    func addFlagsChangedHandler(_ handler: @escaping (FlagsChanged) -> Void) {
        flagsChangedHandlers.append(handler)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        ensureTapRunning()
        installHealthTimer()
    }

    func stop() {
        clearTap(disable: true)
        installedByOverride = false
        healthTimer?.invalidate()
        healthTimer = nil
        didStart = false
    }

    /// Idempotently make sure the tap exists and is enabled. Safe to call from
    /// the health timer or after the Accessibility grant flips on.
    func ensureTapRunning() {
        guard didStart else { return }
        guard permissionsCheck() else {
            logInstallFailureOnce("AX not granted; keyboard hub will retry later")
            return
        }

        if let tap = eventTap {
            guard CFMachPortIsValid(tap) else {
                logger.info("keyboard hub tap invalid; reinstalling")
                clearTap(disable: false)
                installTap()
                return
            }
            if !CGEvent.tapIsEnabled(tap: tap) {
                logger.info("re-enabling keyboard hub tap from health check")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        if installedByOverride {
            return
        }

        installTap()
    }

    // MARK: - Callback entry points (main actor)
    // `internal` rather than `fileprivate` so tests can drive fan-out directly
    // (the real `@convention(c)` tap callback can't be invoked from a unit test).

    func dispatchKeyDown(_ event: KeyDown) {
        for handler in keyDownHandlers {
            handler(event)
        }
    }

    func dispatchFlagsChanged(_ event: FlagsChanged) {
        for handler in flagsChangedHandlers {
            handler(event)
        }
    }

    fileprivate func reenableTapIfNeeded() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            logger.info("re-enabling keyboard hub tap after disable event")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Tap lifecycle

    private func installTap() {
        if let eventTapInstallerOverride {
            if eventTapInstallerOverride() {
                installedByOverride = true
                lastInstallFailureReason = nil
                logger.info("keyboard hub started (override)")
            } else {
                logInstallFailureOnce("CGEvent.tapCreate failed; keyboard hub disabled")
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
            callback: keyboardEventHubCallback,
            userInfo: refcon
        ) else {
            logInstallFailureOnce("CGEvent.tapCreate failed; keyboard hub disabled")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastInstallFailureReason = nil
        logger.info("keyboard hub started")
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

// The CGEventTap callback must be a `@convention(c)` function. It decodes the
// (Sendable) primitives off the event on the tap thread, then hops to the main
// actor to fan them out — mirroring how the per-feature taps used to dispatch.
private let keyboardEventHubCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let hub = Unmanaged<KeyboardEventHub>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            Task { @MainActor in
                hub.reenableTapIfNeeded()
            }
        }
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown:
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        let characters = String(utf16CodeUnits: buffer, count: length)
        DispatchQueue.main.async {
            Task { @MainActor in
                hub.dispatchKeyDown(KeyboardEventHub.KeyDown(keycode: keycode, characters: characters))
            }
        }
    case .flagsChanged:
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        DispatchQueue.main.async {
            Task { @MainActor in
                hub.dispatchFlagsChanged(KeyboardEventHub.FlagsChanged(keycode: keycode, flags: flags))
            }
        }
    default:
        break
    }

    return Unmanaged.passUnretained(event)
}
