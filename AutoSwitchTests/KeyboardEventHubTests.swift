import CoreGraphics
import XCTest
@testable import AutoSwitch

@MainActor
final class KeyboardEventHubTests: XCTestCase {
    func testRetriesInstallWhenPermissionBecomesAvailable() {
        var trusted = false
        var installAttempts = 0
        let hub = KeyboardEventHub(
            permissionsCheck: { trusted },
            eventTapInstallerOverride: {
                installAttempts += 1
                return true
            }
        )

        hub.start()
        XCTAssertEqual(installAttempts, 0, "must not install before Accessibility is granted")

        trusted = true
        hub.ensureTapRunning()
        XCTAssertEqual(installAttempts, 1)

        hub.ensureTapRunning()
        XCTAssertEqual(installAttempts, 1, "already installed; should not reinstall")
        hub.stop()
    }

    func testRetriesAfterTapInstallFailure() {
        var installAttempts = 0
        let hub = KeyboardEventHub(
            permissionsCheck: { true },
            eventTapInstallerOverride: {
                installAttempts += 1
                return installAttempts >= 2
            }
        )

        hub.start()
        XCTAssertEqual(installAttempts, 1)

        hub.ensureTapRunning()
        XCTAssertEqual(installAttempts, 2)

        hub.ensureTapRunning()
        XCTAssertEqual(installAttempts, 2, "succeeded on the retry; should stop retrying")
        hub.stop()
    }

    func testFansKeyDownToEveryRegisteredHandler() {
        let hub = KeyboardEventHub(
            permissionsCheck: { true },
            eventTapInstallerOverride: { true }
        )
        var keycodes: [Int64] = []
        var characters: [String] = []
        hub.addKeyDownHandler { keycodes.append($0.keycode) }
        hub.addKeyDownHandler { characters.append($0.characters) }
        hub.start()

        hub.dispatchKeyDown(KeyboardEventHub.KeyDown(keycode: 44, characters: "/"))

        XCTAssertEqual(keycodes, [44])
        XCTAssertEqual(characters, ["/"])
        hub.stop()
    }

    func testFansFlagsChangedToHandlers() {
        let hub = KeyboardEventHub(
            permissionsCheck: { true },
            eventTapInstallerOverride: { true }
        )
        var seen: [Int64] = []
        hub.addFlagsChangedHandler { seen.append($0.keycode) }
        hub.start()

        hub.dispatchFlagsChanged(KeyboardEventHub.FlagsChanged(keycode: 56, flags: .maskShift))

        XCTAssertEqual(seen, [56])
        hub.stop()
    }
}
