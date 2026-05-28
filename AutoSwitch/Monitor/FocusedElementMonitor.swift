import AppKit
import ApplicationServices
import CoreGraphics
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

@MainActor
final class FocusedElementMonitor {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "focused-element")
    private let isEnabledProvider: () -> Bool
    private let permissionsCheck: () -> Bool
    private let targetBundleIDsProvider: () -> Set<String>
    private let eventHandler: (FocusEvent) -> Void
    private let pollInterval: TimeInterval
    private let pollBurstDuration: TimeInterval

    private var pollTimer: Timer?
    private var pollDeadline: Date?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
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
    private var lastInstallFailureReason: String?

    /// Undocumented but well-known accessibility attribute names. Setting these
    /// to YES on an Electron/Chromium app element triggers it to populate its
    /// AX tree (without this, focused-element queries return -25212
    /// attributeUnsupported). macOS sets these automatically when VoiceOver is
    /// active; we replicate that for our own AX-text reads.
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
        stopKeyTap(disable: true)
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

    fileprivate func handleKeyActivity() {
        guard activeBundleID != nil else { return }
        guard currentFrontmostApp().map({ isTargetBundle($0.bundleIdentifier) }) == true else {
            stopActiveMonitoring(clearDetections: true)
            return
        }
        triggerDetectionBurst(reason: "key activity")
    }

    fileprivate func reenableKeyTapIfNeeded() {
        guard let eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: eventTap) {
            logger.info("re-enabling focused element key tap")
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
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

        ensureKeyTapRunning()
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
            let fallbackText = collectWindowFallbackText(appElement: appElement, bundleID: bundleID)
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
        let text = readSearchableText(from: focused)
        let kind: String
        if text.isEmpty {
            kind = "empty (role=\(describeRole(focused)))"
        } else {
            kind = "ok role=\(describeRole(focused))"
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
        stopKeyTap(disable: true)
        activeBundleID = nil
        activePID = nil
        if clearDetections {
            clearAllReportedDetections()
        }
    }

    private func ensureKeyTapRunning() {
        guard eventTap == nil else {
            if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: focusedElementKeyTapCallback,
            userInfo: refcon
        ) else {
            logInstallFailureOnce("CGEvent.tapCreate failed for focused element key tap")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lastInstallFailureReason = nil
    }

    private func stopKeyTap(disable: Bool) {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if disable, let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
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

    private func logInstallFailureOnce(_ reason: String) {
        guard lastInstallFailureReason != reason else { return }
        lastInstallFailureReason = reason
        logger.info("\(reason, privacy: .public)")
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

    /// When the app element refuses to report its focused element (common in
    /// Electron apps that opt out of AX focus tracking), try walking the main
    /// window's subtree to collect visible text.
    private func collectWindowFallbackText(appElement: AXUIElement, bundleID: String?) -> String {
        var pieces: [String] = []
        // Try focused window first, fall back to main window.
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(appElement, attr as CFString, &raw)
            guard status == .success, let raw else { continue }
            let window = raw as! AXUIElement
            collectText(from: window, depth: 0, maxDepth: 6, pieces: &pieces, totalBudget: 16384)
            if joinedLength(pieces) >= 16 { break }
        }
        return pieces.joined(separator: "\n")
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

    private func describeRole(_ element: AXUIElement) -> String {
        let role = stringAttribute(element, kAXRoleAttribute) ?? "?"
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        let identifier = stringAttribute(element, kAXIdentifierAttribute)
        var parts = [role]
        if let subrole, !subrole.isEmpty { parts.append("sub=\(subrole)") }
        if let identifier, !identifier.isEmpty { parts.append("id=\(identifier)") }
        return parts.joined(separator: "/")
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

    /// Collect text from the focused element and a shallow set of descendants
    /// (some apps split prompt text into children rather than putting it on the
    /// focused element's AXValue). When focus is on a leaf like a canvas with
    /// no AXValue (Electron-style terminals), walk up to the parent so that
    /// sibling DOM/widget nodes that *do* expose text can contribute.
    private func readSearchableText(from element: AXUIElement) -> String {
        var pieces: [String] = []
        collectText(from: element, depth: 0, maxDepth: 3, pieces: &pieces, totalBudget: 4096)
        if joinedLength(pieces) < 16, let parentEl = parentElement(of: element) {
            collectText(from: parentEl, depth: 0, maxDepth: 3, pieces: &pieces, totalBudget: 8192)
            if joinedLength(pieces) < 16, let grandparentEl = parentElement(of: parentEl) {
                collectText(from: grandparentEl, depth: 0, maxDepth: 3, pieces: &pieces, totalBudget: 8192)
            }
        }
        return pieces.joined(separator: "\n")
    }

    private func joinedLength(_ pieces: [String]) -> Int {
        pieces.reduce(0) { $0 + $1.count }
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw)
        guard status == .success, let raw else { return nil }
        return (raw as! AXUIElement)
    }

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        pieces: inout [String],
        totalBudget: Int
    ) {
        let currentLength = pieces.reduce(0) { $0 + $1.count }
        guard currentLength < totalBudget else { return }

        if let value = stringAttribute(element, kAXValueAttribute) {
            pieces.append(value)
        }
        if let placeholder = stringAttribute(element, kAXPlaceholderValueAttribute) {
            pieces.append(placeholder)
        }

        guard depth < maxDepth else { return }

        if let children = arrayAttribute(element, kAXChildrenAttribute) {
            for child in children.prefix(16) {
                collectText(
                    from: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    pieces: &pieces,
                    totalBudget: totalBudget
                )
            }
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let raw else { return nil }
        if let str = raw as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    private func arrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
        guard status == .success, let raw else { return nil }
        return raw as? [AXUIElement]
    }
}

private let focusedElementKeyTapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<FocusedElementMonitor>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            Task { @MainActor in
                monitor.reenableKeyTapIfNeeded()
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
