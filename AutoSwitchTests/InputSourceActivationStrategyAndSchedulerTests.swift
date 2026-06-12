import XCTest
@testable import AutoSwitch

final class InputSourceActivationStrategyTests: XCTestCase {
    final class StubController: InputSourceControlling {
        var availableInputSources: [InputSource] = []
        var currentInputSourceIDValue: String?
        var selected: [String] = []
        var onUserInitiatedChange: ((_ previousID: String?, _ currentID: String?) -> Void)?

        func startObservingSystemSourceChanges() {}

        func refreshInputSources() {}

        func selectInputSource(id: String) -> Bool {
            selected.append(id)
            currentInputSourceIDValue = id
            return availableInputSources.contains { $0.id == id }
        }

        func inputSource(with id: String) -> InputSource? {
            availableInputSources.first { $0.id == id }
        }
    }

    private func source(_ id: String, kind: InputSourceKind) -> InputSource {
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
    func testCanReactivateChineseOnlyWhenBridgeExists() {
        let controller = StubController()
        controller.availableInputSources = [
            source("zh.target", kind: .chinese),
            source("zh.bridge", kind: .chinese),
            source("abc", kind: .ascii)
        ]
        XCTAssertTrue(InputSourceActivationStrategy.canReactivateInputMode(
            targetID: "zh.target",
            inputSourceController: controller
        ))

        controller.availableInputSources = [source("zh.target", kind: .chinese), source("abc", kind: .ascii)]
        XCTAssertFalse(InputSourceActivationStrategy.canReactivateInputMode(
            targetID: "zh.target",
            inputSourceController: controller
        ))
    }

    @MainActor
    func testCanReactivateIgnoresNonChineseTargets() {
        let controller = StubController()
        controller.availableInputSources = [source("abc", kind: .ascii)]
        XCTAssertFalse(InputSourceActivationStrategy.canReactivateInputMode(
            targetID: "abc",
            inputSourceController: controller
        ))
    }

    @MainActor
    func testActivateBridgesViaAlternateChineseSourceBeforeTarget() async {
        let controller = StubController()
        controller.availableInputSources = [
            source("zh.target", kind: .chinese),
            source("zh.bridge", kind: .chinese),
            source("abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "abc"

        let didActivate = await InputSourceActivationStrategy.activate(
            targetID: "zh.target",
            inputSourceController: controller,
            delayNanoseconds: 0
        )

        XCTAssertTrue(didActivate)
        XCTAssertEqual(controller.selected, ["zh.bridge", "zh.target"])
        XCTAssertEqual(controller.currentInputSourceIDValue, "zh.target")
    }

    @MainActor
    func testActivateFallsBackToDirectSelectionWithoutBridge() async {
        let controller = StubController()
        controller.availableInputSources = [source("abc", kind: .ascii)]
        controller.currentInputSourceIDValue = "abc"

        let didActivate = await InputSourceActivationStrategy.activate(
            targetID: "abc",
            inputSourceController: controller,
            delayNanoseconds: 0
        )

        XCTAssertTrue(didActivate)
        XCTAssertEqual(controller.selected, ["abc"])
    }
}

final class SwitchSchedulerSuspensionTests: XCTestCase {
    final class StubController: InputSourceControlling {
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

    private func source(_ id: String, kind: InputSourceKind) -> InputSource {
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
    func testSchedulerSkipsSwitchingWhileSuspended() async {
        let controller = StubController()
        controller.availableInputSources = [source("abc", kind: .ascii)]
        let scheduler = SwitchScheduler(inputSourceController: controller, activationDelayNanoseconds: 0)

        scheduler.suspendAutomaticSwitching(reason: "manual override")
        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "suppressed", sourceBundleID: nil, isPanelContext: false))
        try? await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertTrue(controller.selected.isEmpty)
    }

    @MainActor
    func testSchedulerNestedSuspendDepthRequiresFullResumeToRun() async {
        let controller = StubController()
        controller.availableInputSources = [source("abc", kind: .ascii)]
        let scheduler = SwitchScheduler(inputSourceController: controller, activationDelayNanoseconds: 0)

        scheduler.suspendAutomaticSwitching(reason: "outer")
        scheduler.suspendAutomaticSwitching(reason: "inner")
        scheduler.resumeAutomaticSwitching(reason: "inner")

        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "suppressed", sourceBundleID: nil, isPanelContext: false))
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(controller.selected.isEmpty)

        scheduler.resumeAutomaticSwitching(reason: "outer")
        scheduler.schedule(SwitchDecision(targetInputSourceID: "abc", reason: "eligible", sourceBundleID: nil, isPanelContext: false))
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(controller.selected.last, "abc")
    }
}
