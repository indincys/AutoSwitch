import AppKit
import ApplicationServices
import Foundation
import os.log

final class SpotlightPanelMonitor: NSObject {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "spotlight-monitor")
    private let bundleIDsProvider: () -> [String]
    private let eventHandler: (FocusEvent) -> Void
    private var didStart = false
    private var observerContexts: [String: ObserverContext] = [:]
    private var visibilityTimer: Timer?
    private var visibleBundleIDs: Set<String> = []
    private let notificationCenter = NSWorkspace.shared.notificationCenter

    init(
        bundleIDsProvider: @escaping () -> [String],
        eventHandler: @escaping (FocusEvent) -> Void
    ) {
        self.bundleIDsProvider = bundleIDsProvider
        self.eventHandler = eventHandler
        super.init()
    }

    deinit {
        visibilityTimer?.invalidate()
        teardownObservers()
        notificationCenter.removeObserver(self)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        logger.info("starting spotlight monitor")
        refreshObservers()
        startVisibilityPolling()
        reconcileVisibility(reason: "startup")

        let notifications: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        for name in notifications {
            notificationCenter.addObserver(
                self,
                selector: #selector(handleRefreshNotification(_:)),
                name: name,
                object: nil
            )
        }
    }

    @objc private func handleRefreshNotification(_ notification: Notification) {
        refreshObservers()
        reconcileVisibility(reason: "workspace change")
    }

    func refreshObservers() {
        let bundleIDs = bundleIDsProvider()
        logger.info("refreshing spotlight observers for \(bundleIDs.count, privacy: .public) bundle ids")
        teardownObservers()

        for bundleID in bundleIDs {
            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                logger.info("spotlight bundle not running: \(bundleID, privacy: .public)")
                continue
            }

            guard let observer = createObserver(for: runningApp.processIdentifier, bundleID: bundleID) else {
                continue
            }

            logger.info("registered spotlight observer for \(bundleID, privacy: .public)")
            observerContexts[bundleID] = observer
        }
    }

    private func startVisibilityPolling() {
        guard visibilityTimer == nil else { return }
        visibilityTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(handleVisibilityTimer(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func handleVisibilityTimer(_ timer: Timer) {
        reconcileVisibility(reason: "poll")
    }

    private func reconcileVisibility(reason: String) {
        let nextVisibleBundleIDs = currentVisibleBundleIDs()
        let diff = VisibilityDiff.resolve(previous: visibleBundleIDs, current: nextVisibleBundleIDs)

        guard diff.hasChanges else {
            return
        }

        visibleBundleIDs = nextVisibleBundleIDs

        for bundleID in diff.appeared.sorted() {
            logger.info("panel visible via CGWindow for \(bundleID, privacy: .public) reason=\(reason, privacy: .public)")
            eventHandler(.panelShown(bundleID: bundleID))
        }

        for bundleID in diff.disappeared.sorted() {
            logger.info("panel hidden via CGWindow for \(bundleID, privacy: .public) reason=\(reason, privacy: .public)")
            eventHandler(.panelHidden(bundleID: bundleID))
        }
    }

    private func currentVisibleBundleIDs() -> Set<String> {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        var bundleIDs = Set<String>()

        for bundleID in bundleIDsProvider() {
            guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                continue
            }

            let pid = runningApp.processIdentifier
            guard windows.contains(where: { window in
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber else {
                    return false
                }
                guard ownerPID.int32Value == pid else {
                    return false
                }
                let isOnscreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
                let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0
                return isOnscreen && alpha > 0
            }) else {
                continue
            }

            bundleIDs.insert(bundleID)
        }

        return bundleIDs
    }

    private func teardownObservers() {
        for context in observerContexts.values {
            if let source = context.runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            context.releaseRefcon()
        }
        observerContexts.removeAll()
    }

    private func createObserver(for pid: pid_t, bundleID: String) -> ObserverContext? {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            if name == kAXWindowCreatedNotification as String || name == kAXMainWindowChangedNotification as String {
                context.handler(.panelShown(bundleID: context.bundleID))
            } else if name == kAXUIElementDestroyedNotification as String {
                context.handler(.panelHidden(bundleID: context.bundleID))
            }
        }

        let error = AXObserverCreate(pid, callback, &observer)
        guard error == .success, let observer else {
            logger.error("failed to create AX observer for \(bundleID, privacy: .public)")
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        let context = ObserverContext(bundleID: bundleID, observer: observer, handler: eventHandler)
        let refcon = Unmanaged.passRetained(context).toOpaque()
        context.refcon = refcon
        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXMainWindowChangedNotification
        ]

        for notification in notifications {
            let status = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if status != .success {
                logger.error("failed to add AX notification for \(bundleID, privacy: .public)")
            } else {
                logger.info("added \(notification as String, privacy: .public) for \(bundleID, privacy: .public)")
            }
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        return context
    }

    private final class ObserverContext {
        let bundleID: String
        let observer: AXObserver
        let handler: (FocusEvent) -> Void
        var refcon: UnsafeMutableRawPointer?

        init(bundleID: String, observer: AXObserver, handler: @escaping (FocusEvent) -> Void) {
            self.bundleID = bundleID
            self.observer = observer
            self.handler = handler
        }

        var runLoopSource: CFRunLoopSource? {
            AXObserverGetRunLoopSource(observer)
        }

        func releaseRefcon() {
            guard let refcon else { return }
            Unmanaged<ObserverContext>.fromOpaque(refcon).release()
            self.refcon = nil
        }
    }
}
