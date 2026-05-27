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
