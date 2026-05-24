import AppKit
import Foundation

struct LaunchContext: Equatable {
    let launchedAsLoginItem: Bool
    let isDefaultLaunch: Bool?

    var shouldShowSettingsWindowOnLaunch: Bool {
        !launchedAsLoginItem
    }

    var shouldSignalExistingInstanceToOpenSettings: Bool {
        !launchedAsLoginItem
    }

    init(launchedAsLoginItem: Bool, isDefaultLaunch: Bool? = nil) {
        self.launchedAsLoginItem = launchedAsLoginItem
        self.isDefaultLaunch = isDefaultLaunch
    }

    @MainActor
    init(
        notification: Notification,
        appleEvent: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent
    ) {
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue
        self.init(
            launchedAsLoginItem: Self.isLoginItemLaunch(appleEvent: appleEvent),
            isDefaultLaunch: isDefaultLaunch
        )
    }

    static func isLoginItemLaunch(appleEvent: NSAppleEventDescriptor?) -> Bool {
        if appleEvent?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil {
            return true
        }

        return appleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
