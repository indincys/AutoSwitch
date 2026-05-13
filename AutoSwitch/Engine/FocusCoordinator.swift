import AppKit
import CoreGraphics
import Foundation
import os.log

@MainActor
final class FocusCoordinator {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "coordinator")
    private let configStore: ConfigStore
    private let inputSourceController: InputSourceControlling
    private let scheduler: SwitchScheduler
    private let frontmostBundleIDProvider: () -> String?
    private let ruleEngine = RuleEngine()
    private var lastRegularActivationBundleID: String?

    init(
        configStore: ConfigStore,
        inputSourceController: InputSourceControlling,
        scheduler: SwitchScheduler,
        frontmostBundleIDProvider: @escaping () -> String? = {
            FrontmostApplicationResolver.currentBundleID()
        }
    ) {
        self.configStore = configStore
        self.inputSourceController = inputSourceController
        self.scheduler = scheduler
        self.frontmostBundleIDProvider = frontmostBundleIDProvider
    }

    func handleAppActivation(bundleID: String?) {
        logger.info("app activation: \(bundleID ?? "nil", privacy: .public)")
        if let bundleID, FrontmostApplicationResolver.shouldIgnore(bundleID: bundleID) {
            logger.info("ignoring non-content app activation: \(bundleID, privacy: .public)")
            return
        }
        if let bundleID, bundleID == lastRegularActivationBundleID {
            logger.info("ignoring duplicate app activation: \(bundleID, privacy: .public)")
            return
        }
        lastRegularActivationBundleID = bundleID
        scheduleResolution(bundleID: bundleID, isPanelContext: false, reason: "app activation")
    }

    func handleSystemEvent(_ event: FocusEvent) {
        switch event {
        case .appActivated(let bundleID):
            handleAppActivation(bundleID: bundleID)
        case .panelShown(let bundleID):
            logger.info("panel shown: \(bundleID, privacy: .public)")
            scheduleResolution(bundleID: bundleID, isPanelContext: true, reason: "panel shown")
        case .panelHidden:
            logger.info("panel hidden")
            reconcileCurrentFocus(reason: "panel hidden")
        case .screenWoke, .sessionActive:
            logger.info("system wake/session active")
            reconcileCurrentFocus(reason: "system event")
        }
    }

    func reconcileCurrentFocus(reason: String) {
        let bundleID = frontmostBundleIDProvider()
        logger.info("reconcile focus (\(reason, privacy: .public)): \(bundleID ?? "nil", privacy: .public)")
        lastRegularActivationBundleID = bundleID
        scheduleResolution(bundleID: bundleID, isPanelContext: false, reason: reason)
    }

    private func scheduleResolution(bundleID: String?, isPanelContext: Bool, reason: String) {
        let decision = ruleEngine.resolve(
            bundleID: bundleID,
            isPanelContext: isPanelContext,
            config: configStore.config,
            availableInputSources: inputSourceController.availableInputSources
        )

        guard let decision else {
            logger.info("no rule decision for reason \(reason, privacy: .public)")
            return
        }

        scheduler.schedule(decision)
    }
}

enum FrontmostApplicationResolver {
    private static let ignoredBundleIDs: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "dev.autoswitch.AutoSwitch"
    ]

    static func currentBundleID() -> String? {
        preferredBundleID(
            workspaceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            visibleWindowBundleIDs: visibleWindowBundleIDs()
        )
    }

    static func preferredBundleID(workspaceBundleID: String?, visibleWindowBundleIDs: [String]) -> String? {
        if let workspaceBundleID, isUsable(bundleID: workspaceBundleID) {
            return workspaceBundleID
        }

        return visibleWindowBundleIDs.first(where: isUsable(bundleID:))
    }

    private static func visibleWindowBundleIDs() -> [String] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        return windows.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0 else {
                return nil
            }
            guard let isOnscreen = window[kCGWindowIsOnscreen as String] as? NSNumber, isOnscreen.boolValue else {
                return nil
            }
            guard let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0 else {
                return nil
            }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber,
                  let height = bounds["Height"] as? NSNumber,
                  width.doubleValue >= 64,
                  height.doubleValue >= 64 else {
                return nil
            }
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }
            let pid = ownerPID.int32Value
            guard pid != currentPID else {
                return nil
            }
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
    }

    static func shouldIgnore(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return true }
        if ignoredBundleIDs.contains(bundleID) {
            return true
        }
        if let currentBundleID = Bundle.main.bundleIdentifier, currentBundleID == bundleID {
            return true
        }
        return false
    }

    private static func isUsable(bundleID: String) -> Bool {
        !shouldIgnore(bundleID: bundleID)
    }
}
