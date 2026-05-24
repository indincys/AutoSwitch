import AppKit
import XCTest
@testable import AutoSwitch

final class LaunchContextTests: XCTestCase {
    @MainActor
    func testLoginItemLaunchKeepsSettingsWindowHidden() {
        let context = LaunchContext(
            notification: launchNotification(),
            appleEvent: openApplicationEvent(loginItemMarker: .propertyData)
        )

        XCTAssertTrue(context.launchedAsLoginItem)
        XCTAssertFalse(context.shouldShowSettingsWindowOnLaunch)
        XCTAssertFalse(context.shouldSignalExistingInstanceToOpenSettings)
    }

    @MainActor
    func testManualLaunchShowsSettingsWindow() {
        let context = LaunchContext(
            notification: launchNotification(),
            appleEvent: openApplicationEvent(loginItemMarker: .none)
        )

        XCTAssertFalse(context.launchedAsLoginItem)
        XCTAssertTrue(context.shouldShowSettingsWindowOnLaunch)
        XCTAssertTrue(context.shouldSignalExistingInstanceToOpenSettings)
    }

    func testLoginItemLaunchSupportsDirectMarker() {
        XCTAssertTrue(
            LaunchContext.isLoginItemLaunch(
                appleEvent: openApplicationEvent(loginItemMarker: .directKeyword)
            )
        )
    }

    @MainActor
    func testLaunchNotificationCapturesDefaultLaunchFlag() {
        let context = LaunchContext(
            notification: launchNotification(isDefaultLaunch: true),
            appleEvent: nil
        )

        XCTAssertEqual(context.isDefaultLaunch, true)
    }

    private func launchNotification(isDefaultLaunch: Bool? = nil) -> Notification {
        var userInfo: [AnyHashable: Any] = [:]
        if let isDefaultLaunch {
            userInfo[NSApplication.launchIsDefaultUserInfoKey] = NSNumber(value: isDefaultLaunch)
        }
        return Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    private enum LoginItemMarker {
        case none
        case propertyData
        case directKeyword
    }

    private func openApplicationEvent(loginItemMarker: LoginItemMarker) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )

        switch loginItemMarker {
        case .none:
            break
        case .propertyData:
            event.setParam(
                NSAppleEventDescriptor(typeCode: keyAELaunchedAsLogInItem),
                forKeyword: keyAEPropData
            )
        case .directKeyword:
            event.setParam(
                NSAppleEventDescriptor(boolean: true),
                forKeyword: keyAELaunchedAsLogInItem
            )
        }

        return event
    }
}
