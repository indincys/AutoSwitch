import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

/// Listens for `/` keydown to enter a transient "force English" state, then for
/// the next space / tab / return / enter to restore whichever input source was
/// active before. Useful for slash commands in Claude Code, Codex CLI, and
/// similar tools where you usually want to type the command in English even
/// when the surrounding context is Chinese.
@MainActor
final class SlashTriggerMonitor {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "slash-trigger")
    private let isEnabledProvider: () -> Bool
    private let permissionsCheck: () -> Bool
    private let inputSourceController: InputSourceControlling

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didStart = false

    private var savedSourceID: String?
    private var inSlashMode = false

    init(
        isEnabledProvider: @escaping () -> Bool,
        permissionsCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        inputSourceController: InputSourceControlling
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.permissionsCheck = permissionsCheck
        self.inputSourceController = inputSourceController
    }

    func start() {
        guard !didStart else { return }
        guard permissionsCheck() else {
            logger.info("AX not granted; slash trigger will retry later")
            return
        }
        installTap()
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
        didStart = false
    }

    private func installTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: slashTriggerEventCallback,
            userInfo: refcon
        ) else {
            logger.error("CGEvent.tapCreate failed; slash trigger disabled")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        didStart = true
        logger.info("slash trigger monitor started")
    }

    fileprivate func reenableTapIfNeeded() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            logger.info("re-enabling event tap after disable event")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handleKey(keycode: Int64, typed: String) {
        guard isEnabledProvider() else {
            if inSlashMode { restoreIME() }
            return
        }

        // Terminator keycodes: space (49), tab (48), return (36), keypad enter (76)
        if keycode == 49 || keycode == 48 || keycode == 36 || keycode == 76 {
            if inSlashMode {
                restoreIME()
            }
            return
        }

        if typed == "/" {
            enterSlashMode()
        }
    }

    private func enterSlashMode() {
        if inSlashMode { return }
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
        _ = inputSourceController.selectInputSource(id: asciiID)
    }

    private func restoreIME() {
        defer {
            inSlashMode = false
            savedSourceID = nil
        }
        guard let id = savedSourceID, id != inputSourceController.currentInputSourceIDValue else {
            return
        }
        logger.info("slash trigger: ↩ \(id, privacy: .public)")
        _ = inputSourceController.selectInputSource(id: id)
    }

    private func asciiFallbackID() -> String? {
        inputSourceController.availableInputSources.first(where: {
            $0.kind == .ascii && $0.isEnabled && $0.isSelectCapable
        })?.id
    }
}

// CGEventTap callback must be a `@convention(c)` function, so it lives at file
// scope and dispatches to the main actor for any state interaction.
private let slashTriggerEventCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<SlashTriggerMonitor>.fromOpaque(refcon).takeUnretainedValue()

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

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    var length: Int = 0
    var buffer = [UniChar](repeating: 0, count: 4)
    event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
    let typed = String(utf16CodeUnits: buffer, count: length)

    DispatchQueue.main.async {
        Task { @MainActor in
            monitor.handleKey(keycode: keycode, typed: typed)
        }
    }

    return Unmanaged.passUnretained(event)
}
