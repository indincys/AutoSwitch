import AppKit
import ApplicationServices
import Foundation
import os.log

enum PromptDetectionTargetBundles {
    static let defaultBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "co.zeit.hyper",
        "app.hyper.is",
        "com.github.Eugeny.tabby",
        "com.raphamorim.rio"
    ]

    static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return defaultBundleIDs.contains(bundleID)
    }
}

/// Detects shell / TUI prompts in terminal apps so the rule engine can force
/// English (shell prompt) or Chinese (AI-CLI TUI input box).
///
/// Keystrokes that should re-arm the detection burst are delivered by the shared
/// ``KeyboardEventHub`` via `handleKeyActivity()` — this type no longer owns a
/// keyboard tap. It still owns the per-app AX observer and the burst-poll timer,
/// and delegates all AX tree reading to ``AXTextReader``.
@MainActor
final class FocusedElementMonitor {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "focused-element")
    private let isEnabledProvider: () -> Bool
    private let permissionsCheck: () -> Bool
    private let targetBundleIDsProvider: () -> Set<String>
    private let eventHandler: (FocusEvent) -> Void
    private let pollInterval: TimeInterval
    private let pollBurstDuration: TimeInterval
    private let textReader = AXTextReader()

    private var pollTimer: Timer?
    private var pollDeadline: Date?
    private var axObserver: AXObserver?
    private var axRunLoopSource: CFRunLoopSource?
    private var didStart = false
    private var activeBundleID: String?
    private var activePID: pid_t?
    private var lastReportedShell: Bool?
    private var lastReportedTUI: Bool?
    private var lastReportedBundleID: String?
    private var lastDiagnosticBundleID: String?
    private var lastDiagnosticAt: Date?
    private var enhancedUITriedPIDs: Set<pid_t> = []

    /// Undocumented but well-known accessibility attribute names. Setting these
    /// to YES on an Electron/Chromium app element triggers it to populate its
    /// AX tree (without this, focused-element queries return -25212
    /// attributeUnsupported). macOS sets these automatically when VoiceOver is
    /// active; we replicate that for our own AX-text reads. Note this puts the
    /// target app into the same "enhanced accessibility" mode VoiceOver uses, so
    /// it is applied at most once per pid and only when the app refused a normal
    /// focused-element read.
    private static let enhancedUserInterfaceAttr = "AXEnhancedUserInterface"
    private static let manualAccessibilityAttr = "AXManualAccessibility"

    init(
        isEnabledProvider: @escaping () -> Bool,
        permissionsCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        targetBundleIDsProvider: @escaping () -> Set<String> = { PromptDetectionTargetBundles.defaultBundleIDs },
        eventHandler: @escaping (FocusEvent) -> Void,
        pollInterval: TimeInterval = 0.3,
        pollBurstDuration: TimeInterval = 6.0
    ) {
        self.isEnabledProvider = isEnabledProvider
        self.permissionsCheck = permissionsCheck
        self.targetBundleIDsProvider = targetBundleIDsProvider
        self.eventHandler = eventHandler
        self.pollInterval = pollInterval
        self.pollBurstDuration = pollBurstDuration
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        logger.info("starting focused element monitor (burst-poll=\(self.pollInterval, privacy: .public)s)")
        refreshActiveApplication(reason: "startup")
    }

    func stop() {
        stopActiveMonitoring(clearDetections: true)
        didStart = false
    }

    /// Force an immediate detection pass. Useful right after config changes.
    func reevaluate() {
        refreshActiveApplication(reason: "reevaluate")
    }

    func handleAppActivation(bundleID: String?) {
        guard didStart else { return }
        if let bundleID, !isTargetBundle(bundleID) {
            stopActiveMonitoring(clearDetections: true)
            return
        }
        refreshActiveApplication(reason: "app activation")
    }

    /// Called by the shared keyboard hub on every keyDown. No-ops unless a prompt
    /// target is the active app, so non-terminal typing costs only this guard.
    func handleKeyActivity() {
        guard activeBundleID != nil else { return }
        guard currentFrontmostApp().map({ isTargetBundle($0.bundleIdentifier) }) == true else {
            stopActiveMonitoring(clearDetections: true)
            return
        }
        triggerDetectionBurst(reason: "key activity")
    }

    private func refreshActiveApplication(reason: String) {
        guard didStart else { return }
        guard isEnabledProvider() else {
            stopActiveMonitoring(clearDetections: true)
            return
        }
        guard permissionsCheck() else {
            logDiagnosticIfNeeded(bundleID: nil, kind: "AX-not-trusted", text: "")
            stopActiveMonitoring(clearDetections: true)
            return
        }
        guard let app = currentFrontmostApp(), let bundleID = app.bundleIdentifier else {
            stopActiveMonitoring(clearDetections: true)
            logDiagnosticIfNeeded(bundleID: nil, kind: "no-frontmost-app", text: "")
            return
        }
        guard isTargetBundle(bundleID), !FrontmostApplicationResolver.shouldIgnore(bundleID: bundleID) else {
            stopActiveMonitoring(clearDetections: true)
            logDiagnosticIfNeeded(bundleID: bundleID, kind: "not-prompt-target", text: "")
            return
        }

        if activePID != app.processIdentifier || activeBundleID != bundleID {
            installAXObserver(for: app.processIdentifier, bundleID: bundleID)
            activePID = app.processIdentifier
            activeBundleID = bundleID
        }
        triggerDetectionBurst(reason: reason)
    }

    private func triggerDetectionBurst(reason: String) {
        pollDeadline = Date().addingTimeInterval(pollBurstDuration)
        tick(reason: reason)
        installPollTimerIfNeeded()
    }

    private func installPollTimerIfNeeded() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePollTimer()
            }
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handlePollTimer() {
        if let pollDeadline, Date() <= pollDeadline {
            tick(reason: "burst poll")
            return
        }
        pollTimer?.invalidate()
        pollTimer = nil
        pollDeadline = nil
    }

    private func tick(reason: String) {
        guard isEnabledProvider() else {
            stopActiveMonitoring(clearDetections: true)
            return
        }
        guard permissionsCheck() else {
            logDiagnosticIfNeeded(bundleID: nil, kind: "AX-not-trusted", text: "")
            stopActiveMonitoring(clearDetections: true)
            return
        }

        guard let app = currentFrontmostApp() else {
            stopActiveMonitoring(clearDetections: true)
            logDiagnosticIfNeeded(bundleID: nil, kind: "no-frontmost-app", text: "")
            return
        }
        let bundleID = app.bundleIdentifier
        if !isTargetBundle(bundleID) {
            stopActiveMonitoring(clearDetections: true)
            logDiagnosticIfNeeded(bundleID: bundleID, kind: "not-prompt-target", text: "")
            return
        }
        if let bundleID, FrontmostApplicationResolver.shouldIgnore(bundleID: bundleID) {
            stopActiveMonitoring(clearDetections: true)
            logDiagnosticIfNeeded(bundleID: bundleID, kind: "ignored", text: "")
            return
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRaw: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        )
        guard focusedStatus == .success, let focusedRaw else {
            // Electron/Chromium hack (best-effort, harmless when ignored).
            if focusedStatus == .attributeUnsupported || focusedStatus == .cannotComplete {
                tryEnableEnhancedAXForElectron(pid: app.processIdentifier, bundleID: bundleID)
            }
            // Fallback: focused element is unknown — try walking the focused/main
            // window's subtree and look for shell prompts anywhere visible. This
            // covers Electron-style terminal apps that expose AXMainWindow even
            // when they refuse to report AXFocusedUIElement.
            let fallbackText = textReader.readWindowFallbackText(appElement: appElement)
            if !fallbackText.isEmpty {
                let shell = ShellPromptDetector.detect(in: fallbackText, scanAllLines: true)
                let tui = ShellPromptDetector.detectTUIPrompt(in: fallbackText, scanAllLines: true)
                logDiagnosticIfNeeded(
                    bundleID: bundleID,
                    kind: "\(reason) window-fallback len=\(fallbackText.count) shell=\(shell) tui=\(tui)",
                    text: fallbackText
                )
                reportDetections(shell: shell, tui: tui, bundleID: bundleID)
                return
            }
            clearAllReportedDetections(bundleID: bundleID)
            logDiagnosticIfNeeded(
                bundleID: bundleID,
                kind: "\(reason) ax-no-focused-element status=\(focusedStatus.rawValue) no-window-fallback",
                text: ""
            )
            return
        }

        let focused = focusedRaw as! AXUIElement
        let text = textReader.readSearchableText(from: focused)
        let kind: String
        if text.isEmpty {
            kind = "empty (role=\(textReader.describeRole(focused)))"
        } else {
            kind = "ok role=\(textReader.describeRole(focused))"
        }
        logDiagnosticIfNeeded(bundleID: bundleID, kind: "\(reason) \(kind)", text: text)
        let shell = ShellPromptDetector.detect(in: text)
        let tui = ShellPromptDetector.detectTUIPrompt(in: text)
        reportDetections(shell: shell, tui: tui, bundleID: bundleID)
    }

    private func isTargetBundle(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return targetBundleIDsProvider().contains(bundleID)
    }

    private func currentFrontmostApp() -> NSRunningApplication? {
        NSWorkspace.shared.frontmostApplication
    }

    private func stopActiveMonitoring(clearDetections: Bool) {
        pollTimer?.invalidate()
        pollTimer = nil
        pollDeadline = nil
        removeAXObserver()
        activeBundleID = nil
        activePID = nil
        if clearDetections {
            clearAllReportedDetections()
        }
    }

    private func installAXObserver(for pid: pid_t, bundleID: String) {
        removeAXObserver()

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let monitor = Unmanaged<FocusedElementMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let reason = "AX \(notification as String)"
            DispatchQueue.main.async {
                Task { @MainActor in
                    monitor.triggerDetectionBurst(reason: reason)
                }
            }
        }

        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let observer else {
            logger.error("failed to create AX focused element observer for \(bundleID, privacy: .public)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications = [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXSelectedTextChangedNotification,
            kAXValueChangedNotification
        ]

        for notification in notifications {
            let status = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if status == .success {
                logger.info("added \(notification as String, privacy: .public) for prompt target \(bundleID, privacy: .public)")
            }
        }

        let source = AXObserverGetRunLoopSource(observer)
        axObserver = observer
        axRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private func removeAXObserver() {
        if let source = axRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        axRunLoopSource = nil
        axObserver = nil
    }

    private func logDiagnosticIfNeeded(bundleID: String?, kind: String, text: String) {
        let now = Date()
        let bundleChanged = bundleID != lastDiagnosticBundleID
        let timeElapsed = lastDiagnosticAt.map { now.timeIntervalSince($0) } ?? .infinity
        guard bundleChanged || timeElapsed >= 3.0 else { return }
        lastDiagnosticBundleID = bundleID
        lastDiagnosticAt = now
        let snippet = text.suffix(140)
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: "\t", with: "→")
        logger.info(
            "ax focus diag bundle=\(bundleID ?? "nil", privacy: .public) kind=\(kind, privacy: .public) len=\(text.count, privacy: .public) tail=\"\(snippet, privacy: .public)\""
        )
    }

    private func tryEnableEnhancedAXForElectron(pid: pid_t, bundleID: String?) {
        guard !enhancedUITriedPIDs.contains(pid) else { return }
        enhancedUITriedPIDs.insert(pid)
        let appElement = AXUIElementCreateApplication(pid)
        let enhancedStatus = AXUIElementSetAttributeValue(
            appElement,
            Self.enhancedUserInterfaceAttr as CFString,
            kCFBooleanTrue
        )
        let manualStatus = AXUIElementSetAttributeValue(
            appElement,
            Self.manualAccessibilityAttr as CFString,
            kCFBooleanTrue
        )
        logger.info(
            "enabled enhanced AX for pid=\(pid, privacy: .public) bundle=\(bundleID ?? "nil", privacy: .public) enhancedUI=\(enhancedStatus.rawValue) manualAX=\(manualStatus.rawValue)"
        )
    }

    private func clearAllReportedDetections(bundleID: String? = nil) {
        let target = bundleID ?? lastReportedBundleID
        if lastReportedShell == true {
            lastReportedShell = false
            eventHandler(.shellPromptStateChanged(bundleID: target, detected: false))
        }
        if lastReportedTUI == true {
            lastReportedTUI = false
            eventHandler(.tuiPromptStateChanged(bundleID: target, detected: false))
        }
        lastReportedBundleID = nil
    }

    private func reportDetections(shell: Bool, tui: Bool, bundleID: String?) {
        var bundleChanged = false
        if bundleID != lastReportedBundleID {
            bundleChanged = true
            lastReportedBundleID = bundleID
        }
        if bundleChanged || shell != lastReportedShell {
            lastReportedShell = shell
            logger.info("shell prompt detection bundle=\(bundleID ?? "nil", privacy: .public) detected=\(shell, privacy: .public)")
            eventHandler(.shellPromptStateChanged(bundleID: bundleID, detected: shell))
        }
        if bundleChanged || tui != lastReportedTUI {
            lastReportedTUI = tui
            logger.info("tui prompt detection bundle=\(bundleID ?? "nil", privacy: .public) detected=\(tui, privacy: .public)")
            eventHandler(.tuiPromptStateChanged(bundleID: bundleID, detected: tui))
        }
    }
}
