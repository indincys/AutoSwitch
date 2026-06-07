import AppKit
import Combine
import SwiftUI
import Foundation
import os.log

@MainActor
private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    weak var owner: AppState?

    init(owner: AppState) {
        self.owner = owner
    }

    func windowWillClose(_ notification: Notification) {
        owner?.clearSettingsWindow()
    }
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private let logger = Logger(subsystem: "dev.autoswitch", category: "app-state")
    private static let settingsWindowStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    static let settingsWindowDefaultFrameSize = NSSize(width: 900, height: 640)
    static let settingsWindowMinimumFrameSize = NSSize(width: 760, height: 520)
    static let settingsWindowDefaultContentSize = NSWindow.contentRect(
        forFrameRect: NSRect(origin: .zero, size: settingsWindowDefaultFrameSize),
        styleMask: settingsWindowStyleMask
    ).size
    static let settingsWindowMinimumContentSize = NSWindow.contentRect(
        forFrameRect: NSRect(origin: .zero, size: settingsWindowMinimumFrameSize),
        styleMask: settingsWindowStyleMask
    ).size
    private static let settingsWindowVisibleFrameInset = NSSize(width: 80, height: 96)

    static func settingsWindowFrameSize(constrainedTo visibleFrame: NSRect?) -> NSSize {
        guard let visibleFrame else {
            return settingsWindowDefaultFrameSize
        }

        let maxWidth = max(settingsWindowMinimumFrameSize.width, visibleFrame.width - settingsWindowVisibleFrameInset.width)
        let maxHeight = max(settingsWindowMinimumFrameSize.height, visibleFrame.height - settingsWindowVisibleFrameInset.height)

        return NSSize(
            width: min(settingsWindowDefaultFrameSize.width, maxWidth),
            height: min(settingsWindowDefaultFrameSize.height, maxHeight)
        )
    }

    static func settingsWindowFrame(forWindowFrameSize frameSize: NSSize, constrainedTo visibleFrame: NSRect?) -> NSRect {
        guard let visibleFrame else {
            return NSRect(origin: .zero, size: frameSize)
        }

        var origin = NSPoint(
            x: visibleFrame.midX - frameSize.width / 2,
            y: visibleFrame.midY - frameSize.height / 2
        )
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - frameSize.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - frameSize.height))
        origin.x = origin.x.rounded()
        origin.y = origin.y.rounded()

        return NSRect(origin: origin, size: frameSize)
    }

    static func applySettingsWindowSizing(to window: NSWindow, constrainedTo visibleFrame: NSRect? = nil) {
        window.contentMinSize = settingsWindowMinimumContentSize
        window.minSize = settingsWindowMinimumFrameSize
        let frameSize = settingsWindowFrameSize(constrainedTo: visibleFrame)
        window.setFrame(
            settingsWindowFrame(forWindowFrameSize: frameSize, constrainedTo: visibleFrame),
            display: false
        )
    }

    static func applySettingsWindowContentSizing(to window: NSWindow, constrainedTo visibleFrame: NSRect? = nil) {
        applySettingsWindowSizing(to: window, constrainedTo: visibleFrame)
    }

    let configStore = ConfigStore()
    let inputSourceController = InputSourceController()
    let permissionsManager = PermissionsManager()
    let loginItemManager = LoginItemManager()
    let updaterController = UpdaterController()
    let keyboardEventHub = KeyboardEventHub()

    var isTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
    }

    lazy var scheduler = SwitchScheduler(inputSourceController: inputSourceController)
    lazy var focusCoordinator = FocusCoordinator(
        configStore: configStore,
        inputSourceController: inputSourceController,
        scheduler: scheduler
    )

    lazy var singleInstanceCoordinator = SingleInstanceCoordinator { [weak self] in
        self?.activateApp()
    }

    lazy var appActivationMonitor = AppActivationMonitor { [weak self] bundleID in
        self?.focusedElementMonitor.handleAppActivation(bundleID: bundleID)
        self?.focusCoordinator.handleAppActivation(bundleID: bundleID)
        // Re-arm the slash trigger's line-start fallback on a real app switch only.
        // (Driving this from every rule decision re-armed it on each shell/TUI
        // detection in terminals, so a mid-line `/` falsely triggered.)
        self?.slashTriggerMonitor.noteContextReset()
    }

    lazy var lockScreenMonitor = LockScreenMonitor { [weak self] event in
        self?.focusCoordinator.handleSystemEvent(event)
    }

    lazy var spotlightPanelMonitor = SpotlightPanelMonitor(
        bundleIDsProvider: { [weak self] in
            self?.configStore.config.spotlightBundleIDs ?? BuiltinSpotlightBundles.defaultBundleIDs
        },
        eventHandler: { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.focusCoordinator.handleSystemEvent(event)
            }
        }
    )

    lazy var focusedElementMonitor = FocusedElementMonitor(
        isEnabledProvider: { [weak self] in
            self?.configStore.config.shellPromptDetectionEnabled ?? true
        },
        eventHandler: { [weak self] event in
            self?.focusCoordinator.handleSystemEvent(event)
        }
    )

    lazy var slashTriggerMonitor = SlashTriggerMonitor(
        isEnabledProvider: { [weak self] in
            self?.configStore.config.slashTriggerEnabled ?? true
        },
        inputSourceController: inputSourceController
    )

    lazy var transientEnglishMonitor = TransientEnglishMonitor(
        isEnabledProvider: { [weak self] in
            self?.configStore.config.transientEnglishEnabled ?? true
        },
        idleSecondsProvider: { [weak self] in
            self?.configStore.config.transientEnglishIdleSeconds ?? 10
        },
        inputSourceController: inputSourceController
    )

    lazy var statusBarController = StatusBarController(appState: self)

    private var forwardingTokens: [AnyCancellable] = []
    private var settingsWindow: NSWindow?
    private var settingsWindowDelegate: SettingsWindowDelegate?

    private init() {
        bindForwarding()
        configStore.onChange = { [weak self] in
            guard let self else { return }
            self.focusCoordinator.reconcileCurrentFocus(reason: "config changed")
            self.spotlightPanelMonitor.refreshObservers()
            self.focusedElementMonitor.reevaluate()
            if !isTestEnvironment {
                self.statusBarController.updateVisibility()
            }
        }
    }

    private func bindForwarding() {
        forwardingTokens = [
            configStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            inputSourceController.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            permissionsManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            loginItemManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            updaterController.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        ]
    }

    func start() {
        guard !isTestEnvironment else {
            inputSourceController.refreshInputSources()
            permissionsManager.refresh()
            loginItemManager.refresh()
            return
        }

        inputSourceController.startObservingSystemSourceChanges()
        inputSourceController.refreshInputSources()
        permissionsManager.refresh()
        loginItemManager.refresh()
        updaterController.startUpdater()

        focusCoordinator.onDecisionResolved = { [weak self] decision in
            self?.transientEnglishMonitor.handleFocusDecision(decision)
        }
        appActivationMonitor.start()
        lockScreenMonitor.start()
        spotlightPanelMonitor.start()
        focusedElementMonitor.start()
        slashTriggerMonitor.onTemporaryOverrideChanged = { [weak self] isActive in
            if isActive {
                self?.scheduler.suspendAutomaticSwitching(reason: "slash trigger")
            } else {
                self?.scheduler.resumeAutomaticSwitching(reason: "slash trigger")
            }
        }
        slashTriggerMonitor.start()
        transientEnglishMonitor.start()

        // Single shared keyboard tap fans every keystroke out to the three
        // keystroke-driven features, replacing the per-feature taps they used to
        // each install. Wire handlers before starting the hub.
        keyboardEventHub.addKeyDownHandler { [weak self] event in
            guard let self else { return }
            self.slashTriggerMonitor.handleKey(keycode: event.keycode, typed: event.characters)
            self.transientEnglishMonitor.handleKeyDownEvent()
            self.focusedElementMonitor.handleKeyActivity()
        }
        keyboardEventHub.addFlagsChangedHandler { [weak self] event in
            self?.transientEnglishMonitor.handleFlagsChanged(keyCode: event.keycode, flags: event.flags)
        }
        keyboardEventHub.start()

        if configStore.config.showMenuBarIcon {
            statusBarController.start()
        }
        focusCoordinator.reconcileCurrentFocus(reason: "startup")
    }

    func activateApp() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        if !isTestEnvironment {
            NSApp.setActivationPolicy(.regular)
        }
        if let window = settingsWindow {
            logger.info("reusing settings window")
            showAndCorrectSettingsWindow(window, resetContentSize: false)
            return
        }

        logger.info("creating settings window")
        let hostingController = NSHostingController(
            rootView: SettingsScene().environmentObject(self)
        )
        hostingController.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.settingsWindowDefaultContentSize),
            styleMask: Self.settingsWindowStyleMask,
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "AutoSwitch 设置"
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.managed]
        window.isRestorable = false
        window.tabbingMode = .disallowed
        let delegate = SettingsWindowDelegate(owner: self)
        settingsWindowDelegate = delegate
        window.delegate = delegate
        settingsWindow = window
        showAndCorrectSettingsWindow(window, resetContentSize: true)
    }

    private func prepareSettingsWindowForDisplay(_ window: NSWindow, resetContentSize: Bool) {
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        window.contentMinSize = Self.settingsWindowMinimumContentSize
        window.minSize = Self.settingsWindowMinimumFrameSize
        let targetFrameSize = Self.settingsWindowFrameSize(constrainedTo: screenFrame)
        let frameIsTooSmall = window.frame.width < targetFrameSize.width || window.frame.height < targetFrameSize.height
        if resetContentSize || frameIsTooSmall {
            Self.applySettingsWindowSizing(to: window, constrainedTo: screenFrame)
            return
        }

        let frame = window.frame
        var correctedFrame = frame
        if let screenFrame {
            if !window.isVisible {
                correctedFrame.origin.x = screenFrame.midX - correctedFrame.width / 2
                correctedFrame.origin.y = screenFrame.midY - correctedFrame.height / 2
            }
            if correctedFrame.maxX > screenFrame.maxX {
                correctedFrame.origin.x = screenFrame.maxX - correctedFrame.width
            }
            if correctedFrame.minX < screenFrame.minX {
                correctedFrame.origin.x = screenFrame.minX
            }
            if correctedFrame.maxY > screenFrame.maxY {
                correctedFrame.origin.y = screenFrame.maxY - correctedFrame.height
            }
            if correctedFrame.minY < screenFrame.minY {
                correctedFrame.origin.y = screenFrame.minY
            }
            correctedFrame = correctedFrame.integral
        }
        window.setFrameOrigin(correctedFrame.origin)
    }

    private func showAndCorrectSettingsWindow(_ window: NSWindow, resetContentSize: Bool) {
        prepareSettingsWindowForDisplay(window, resetContentSize: resetContentSize)
        activate(window)
        DispatchQueue.main.async {
            self.prepareSettingsWindowForDisplay(window, resetContentSize: false)
            self.activate(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.prepareSettingsWindowForDisplay(window, resetContentSize: false)
                self.activate(window)
                let contentViewSize = window.contentView?.bounds.size ?? .zero
                self.logger.info(
                    "settings window visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(String(describing: window.frame), privacy: .public) contentLayout=\(String(describing: window.contentLayoutRect), privacy: .public) contentViewSize=\(String(describing: contentViewSize), privacy: .public)"
                )
            }
        }
    }

    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: false)
        window.makeKeyAndOrderFront(nil)
    }

    fileprivate func clearSettingsWindow() {
        settingsWindow = nil
        settingsWindowDelegate = nil
        guard !isTestEnvironment else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
