import CoreGraphics
import XCTest
@testable import AutoSwitch

final class SwitchSchedulerTests: XCTestCase {
    final class StubController: InputSourceControlling {
        var availableInputSources: [InputSource] = []
        var currentInputSourceIDValue: String? = nil
        var selected: [String] = []
        var onUserInitiatedChange: ((_ previousID: String?, _ currentID: String?) -> Void)?

        func startObservingSystemSourceChanges() {}
        func refreshInputSources() {}
        func selectInputSource(id: String) -> Bool {
            selected.append(id)
            currentInputSourceIDValue = id
            return true
        }
        func inputSource(with id: String) -> InputSource? { availableInputSources.first { $0.id == id } }
    }

    @MainActor
    func testSchedulerAppliesLatestDecision() async {
        let controller = StubController()
        let scheduler = SwitchScheduler(inputSourceController: controller)
        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "test", sourceBundleID: nil, isPanelContext: false))
        scheduler.schedule(SwitchDecision(targetInputSourceID: "zh", reason: "latest", sourceBundleID: nil, isPanelContext: false))
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(controller.selected.last, "zh")
    }

    @MainActor
    func testSchedulerSkipsWhenTargetAlreadySelected() async {
        let controller = StubController()
        controller.currentInputSourceIDValue = "abc"
        let scheduler = SwitchScheduler(inputSourceController: controller)

        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "test", sourceBundleID: nil, isPanelContext: false))
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertTrue(controller.selected.isEmpty)
    }

    @MainActor
    func testSchedulerCoalescesDuplicatePendingTarget() async {
        let controller = StubController()
        let scheduler = SwitchScheduler(inputSourceController: controller)

        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "first", sourceBundleID: nil, isPanelContext: false))
        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "duplicate", sourceBundleID: "com.apple.Terminal", isPanelContext: false))
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(controller.selected, ["abc"])
    }
}

final class KeyTapMonitorRecoveryTests: XCTestCase {
    private final class StubController: InputSourceControlling {
        var availableInputSources: [InputSource] = []
        var currentInputSourceIDValue: String?
        var selected: [String] = []
        var onUserInitiatedChange: ((_ previousID: String?, _ currentID: String?) -> Void)?

        func startObservingSystemSourceChanges() {}
        func refreshInputSources() {}
        func selectInputSource(id: String) -> Bool {
            selected.append(id)
            currentInputSourceIDValue = id
            return true
        }
        func inputSource(with id: String) -> InputSource? {
            availableInputSources.first { $0.id == id }
        }
    }

    private func makeSource(id: String, kind: InputSourceKind) -> InputSource {
        InputSource(
            id: id,
            localizedName: id,
            category: "keyboard",
            languages: [],
            kind: kind,
            isEnabled: true,
            isSelectCapable: true
        )
    }

    @MainActor
    func testSlashTriggerRetriesWhenPermissionBecomesAvailable() {
        let controller = StubController()
        var trusted = false
        var installAttempts = 0
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            permissionsCheck: { trusted },
            inputSourceController: controller,
            eventTapInstallerOverride: {
                installAttempts += 1
                return true
            }
        )

        monitor.start()
        XCTAssertEqual(installAttempts, 0)

        trusted = true
        monitor.ensureTapRunning()
        XCTAssertEqual(installAttempts, 1)

        monitor.ensureTapRunning()
        XCTAssertEqual(installAttempts, 1)
        monitor.stop()
    }

    @MainActor
    func testSlashTriggerRetriesAfterTapInstallFailure() {
        let controller = StubController()
        var installAttempts = 0
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: {
                installAttempts += 1
                return installAttempts >= 2
            }
        )

        monitor.start()
        XCTAssertEqual(installAttempts, 1)

        monitor.ensureTapRunning()
        XCTAssertEqual(installAttempts, 2)

        monitor.ensureTapRunning()
        XCTAssertEqual(installAttempts, 2)
        monitor.stop()
    }

    @MainActor
    func testTransientEnglishRetriesAfterTapInstallFailure() {
        let controller = StubController()
        var installAttempts = 0
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: {
                installAttempts += 1
                return installAttempts >= 2
            }
        )

        monitor.start()
        XCTAssertEqual(installAttempts, 1)

        monitor.ensureTapRunning()
        XCTAssertEqual(installAttempts, 2)

        monitor.ensureTapRunning()
        XCTAssertEqual(installAttempts, 2)
        monitor.stop()
    }

    @MainActor
    func testBareShiftFromChineseSwitchesToAsciiThenRestoresOnIdle() {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "wechat"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: { true }
        )

        monitor.start()
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])
        XCTAssertEqual(controller.currentInputSourceIDValue, "abc")

        monitor.fireIdleTimeoutForTesting()

        XCTAssertEqual(controller.selected, ["abc", "wechat"])
        XCTAssertEqual(controller.currentInputSourceIDValue, "wechat")
        monitor.stop()
    }

    @MainActor
    func testShiftModifiedKeyDoesNotSwitchSources() {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "wechat"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: { true }
        )

        monitor.start()
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleKeyDownEvent()
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        monitor.fireIdleTimeoutForTesting()

        XCTAssertTrue(controller.selected.isEmpty)
        monitor.stop()
    }

    @MainActor
    func testSecondBareShiftRestoresPreviousChineseAndCancelsIdle() {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "wechat"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: { true }
        )

        monitor.start()
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc", "wechat"])

        monitor.fireIdleTimeoutForTesting()

        XCTAssertEqual(controller.selected, ["abc", "wechat"])
        monitor.stop()
    }

    @MainActor
    func testFocusDecisionClearsShiftTransientSoSchedulerCanApplyTarget() {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "wechat"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: { true }
        )

        monitor.start()
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleFocusDecision(SwitchDecision(targetInputSourceID: "wechat", reason: "app rule", sourceBundleID: "app", isPanelContext: false))
        monitor.fireIdleTimeoutForTesting()

        XCTAssertEqual(controller.selected, ["abc"])
        monitor.stop()
    }

    @MainActor
    func testBareShiftFromAsciiOutsideTransientUsesRememberedChineseSource() {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "wechat"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: { true }
        )

        monitor.start()
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleFocusDecision(SwitchDecision(targetInputSourceID: "abc", reason: "app rule", sourceBundleID: "app", isPanelContext: false))
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])

        XCTAssertEqual(controller.selected, ["abc", "wechat"])
        monitor.stop()
    }

    @MainActor
    func testFocusDecisionRemembersChineseTargetForLaterShiftFromAscii() {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "abc"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            permissionsCheck: { true },
            inputSourceController: controller,
            eventTapInstallerOverride: { true }
        )

        monitor.start()
        monitor.handleFocusDecision(SwitchDecision(targetInputSourceID: "wechat", reason: "app rule", sourceBundleID: "app", isPanelContext: false))
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])

        XCTAssertEqual(controller.selected, ["wechat"])
        monitor.stop()
    }
}
