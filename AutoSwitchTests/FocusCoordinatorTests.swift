import XCTest
@testable import AutoSwitch

final class FocusCoordinatorTests: XCTestCase {
    private final class StubController: InputSourceControlling {
        var availableInputSources: [InputSource] = [
            InputSource(id: "english", localizedName: "ABC", category: "keyboard", languages: ["en"], kind: .ascii, isEnabled: true, isSelectCapable: true),
            InputSource(id: "chinese", localizedName: "Pinyin", category: "inputmethod", languages: ["zh-Hans"], kind: .chinese, isEnabled: true, isSelectCapable: true)
        ]
        var currentInputSourceIDValue: String?
        var selected: [String] = []

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

    private func makeConfigStore() -> ConfigStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: fileURL)
        store.update { config in
            config.globalDefaultInputSourceID = "chinese"
            config.appRules = [
                AppRule(bundleID: "com.apple.Terminal", displayName: "Terminal", inputSourceID: "english", enabled: true, lastSeenPath: nil)
            ]
            config.spotlightRules = [
                SpotlightRule(bundleID: "com.apple.Spotlight", displayName: "Spotlight", inputSourceID: "english", enabled: true, isBuiltin: true)
            ]
        }
        return store
    }

    @MainActor
    func testAppActivationSchedulesAppRule() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller)
        )

        coordinator.handleAppActivation(bundleID: "com.apple.Terminal")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected.last, "english")
    }

    @MainActor
    func testDuplicateAppActivationDoesNotRescheduleSameBundle() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller)
        )

        coordinator.handleAppActivation(bundleID: "com.apple.Terminal")
        try? await Task.sleep(nanoseconds: 250_000_000)
        coordinator.handleAppActivation(bundleID: "com.apple.Terminal")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected, ["english"])
    }

    @MainActor
    func testOwnAppActivationDoesNotOverridePendingContentAppRule() async {
        let controller = StubController()
        controller.currentInputSourceIDValue = "chinese"
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller)
        )

        coordinator.handleAppActivation(bundleID: "com.apple.Terminal")
        coordinator.handleAppActivation(bundleID: "dev.autoswitch.AutoSwitch")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected, ["english"])
    }

    @MainActor
    func testSystemUIActivationDoesNotScheduleGlobalDefault() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller)
        )

        coordinator.handleAppActivation(bundleID: "com.apple.dock")
        coordinator.handleAppActivation(bundleID: "com.apple.systemuiserver")
        coordinator.handleAppActivation(bundleID: "com.apple.controlcenter")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertTrue(controller.selected.isEmpty)
    }

    @MainActor
    func testAppActivationReschedulesWhenBundleChangesBack() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller)
        )

        coordinator.handleAppActivation(bundleID: "com.apple.Terminal")
        try? await Task.sleep(nanoseconds: 250_000_000)
        coordinator.handleAppActivation(bundleID: "com.apple.Finder")
        try? await Task.sleep(nanoseconds: 250_000_000)
        coordinator.handleAppActivation(bundleID: "com.apple.Terminal")
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected, ["english", "chinese", "english"])
    }

    @MainActor
    func testPanelShownUsesSpotlightRule() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller)
        )

        coordinator.handleSystemEvent(.panelShown(bundleID: "com.apple.Spotlight"))
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected.last, "english")
    }

    @MainActor
    func testPanelHiddenReconcilesFrontmostApp() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller),
            frontmostBundleIDProvider: { "com.apple.Finder" }
        )

        coordinator.handleSystemEvent(.panelHidden(bundleID: "com.apple.Spotlight"))
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected.last, "chinese")
    }

    @MainActor
    func testWakeReconcilesFrontmostApp() async {
        let controller = StubController()
        let coordinator = FocusCoordinator(
            configStore: makeConfigStore(),
            inputSourceController: controller,
            scheduler: SwitchScheduler(inputSourceController: controller),
            frontmostBundleIDProvider: { "com.apple.Terminal" }
        )

        coordinator.handleSystemEvent(.sessionActive)
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected.last, "english")
    }

    func testFrontmostResolverUsesWorkspaceBundleWhenUsable() {
        let bundleID = FrontmostApplicationResolver.preferredBundleID(
            workspaceBundleID: "com.apple.Terminal",
            visibleWindowBundleIDs: ["com.apple.Safari"]
        )

        XCTAssertEqual(bundleID, "com.apple.Terminal")
    }

    func testFrontmostResolverFallsBackWhenWorkspaceReportsLoginWindow() {
        let bundleID = FrontmostApplicationResolver.preferredBundleID(
            workspaceBundleID: "com.apple.loginwindow",
            visibleWindowBundleIDs: ["dev.autoswitch.AutoSwitch", "com.apple.Terminal"]
        )

        XCTAssertEqual(bundleID, "com.apple.Terminal")
    }
}
