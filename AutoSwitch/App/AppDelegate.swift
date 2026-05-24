import AppKit
import Foundation
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var didStart = false
    private let logger = Logger(subsystem: "dev.autoswitch", category: "app")

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("didFinishLaunching")
        let state = AppState.shared
        let launchContext = LaunchContext(notification: notification)

        if state.isTestEnvironment {
            logger.info("skipping launch in test environment")
            return
        }

        state.singleInstanceCoordinator.installObserver()

        guard state.singleInstanceCoordinator.acquireLockOrSignalExistingInstance(
            openSettingsInExistingInstance: launchContext.shouldSignalExistingInstanceToOpenSettings
        ) else {
            logger.info("existing instance signaled; terminating")
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        if !didStart {
            didStart = true
            logger.info("starting app state")
            state.start()
        }

        if launchContext.shouldShowSettingsWindowOnLaunch {
            logger.info("showing settings window")
            state.showSettingsWindow()
        } else {
            logger.info("launched as login item; keeping settings window hidden")
        }
    }

    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.info("reopen requested")
        AppState.shared.showSettingsWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
