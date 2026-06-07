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
    func testSchedulerReactivatesChineseTargetEvenWhenAlreadySelected() async {
        let controller = StubController()
        controller.availableInputSources = [
            InputSource(id: "zh.target", localizedName: "Target IME", category: "inputmethod", languages: ["zh-Hans"], kind: .chinese, isEnabled: true, isSelectCapable: true),
            InputSource(id: "zh.bridge", localizedName: "Bridge IME", category: "inputmethod", languages: ["zh-Hans"], kind: .chinese, isEnabled: true, isSelectCapable: true),
            InputSource(id: "abc", localizedName: "ABC", category: "keyboard", languages: ["en"], kind: .ascii, isEnabled: true, isSelectCapable: true)
        ]
        controller.currentInputSourceIDValue = "zh.target"
        let scheduler = SwitchScheduler(inputSourceController: controller, activationDelayNanoseconds: 0)

        scheduler.schedule(SwitchDecision(targetInputSourceID: "zh.target", reason: "tui prompt detected", sourceBundleID: "com.apple.Terminal", isPanelContext: false))
        try? await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(controller.selected, ["zh.bridge", "zh.target"])
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

/// Behavioral tests for the slash-trigger and transient-English monitors. These
/// drive the monitors through their event entry points directly; the keyboard
/// tap lifecycle (install / permission retry / re-enable) now lives in
/// ``KeyboardEventHub`` and is covered by `KeyboardEventHubTests`.
final class SlashAndTransientMonitorTests: XCTestCase {
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

    /// Forces the keystroke fallback path (probe returns nil) so the existing
    /// keystroke-sequence tests exercise that branch deterministically.
    @MainActor
    private func makeSlashMonitor(_ controller: StubController) -> SlashTriggerMonitor {
        SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { nil }
        )
    }

    @MainActor
    private func makeTransientMonitor(_ controller: StubController) -> TransientEnglishMonitor {
        TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            inputSourceController: controller
        )
    }

    @MainActor
    private func chineseAndAsciiController() -> StubController {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "wechat", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "wechat"
        return controller
    }

    @MainActor
    private func chineseAndAsciiController(current: String) -> StubController {
        let controller = chineseAndAsciiController()
        controller.currentInputSourceIDValue = current
        return controller
    }

    @MainActor
    func testSlashAtLineStartSwitchesToEnglishThenSpaceRestores() {
        let controller = chineseAndAsciiController()
        let monitor = makeSlashMonitor(controller)
        monitor.start()

        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleKey(keycode: 49, typed: " ")
        XCTAssertEqual(controller.selected, ["abc", "wechat"])
        monitor.stop()
    }

    @MainActor
    func testSlashRestoresChineseInputModeViaAlternateChineseSource() async {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "zh.target", kind: .chinese),
            makeSource(id: "zh.bridge", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "zh.target"
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { nil },
            reactivationDelayNanoseconds: 0
        )
        monitor.start()

        monitor.handleKey(keycode: 44, typed: "/")
        monitor.handleKey(keycode: 49, typed: " ")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.selected, [
            "abc",
            "zh.bridge",
            "zh.target"
        ])
        monitor.stop()
    }

    @MainActor
    func testPendingChineseReactivationCancelsOnContextReset() async {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "zh.target", kind: .chinese),
            makeSource(id: "zh.bridge", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "zh.target"
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { nil },
            reactivationDelayNanoseconds: 120_000_000
        )
        monitor.start()

        monitor.handleKey(keycode: 44, typed: "/")
        monitor.handleKey(keycode: 49, typed: " ")
        monitor.noteContextReset()
        try? await Task.sleep(nanoseconds: 180_000_000)

        XCTAssertEqual(controller.selected, [
            "abc",
            "zh.bridge"
        ])
        monitor.stop()
    }

    @MainActor
    func testSlashTemporaryOverrideSuppressesTUIChineseDecisionUntilTerminator() async {
        let controller = chineseAndAsciiController()
        let scheduler = SwitchScheduler(inputSourceController: controller, activationDelayNanoseconds: 0)
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { nil },
            reactivationDelayNanoseconds: 0
        )
        monitor.onTemporaryOverrideChanged = { isActive in
            if isActive {
                scheduler.suspendAutomaticSwitching(reason: "slash trigger")
            } else {
                scheduler.resumeAutomaticSwitching(reason: "slash trigger")
            }
        }
        monitor.start()

        monitor.handleKey(keycode: 44, typed: "/")
        scheduler.schedule(SwitchDecision(targetInputSourceID: "wechat", reason: "tui prompt detected", sourceBundleID: "com.apple.Terminal", isPanelContext: false))
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(controller.currentInputSourceIDValue, "abc")
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleKey(keycode: 49, typed: " ")
        XCTAssertEqual(controller.currentInputSourceIDValue, "wechat")
        XCTAssertEqual(controller.selected, ["abc", "wechat"])
        monitor.stop()
    }

    @MainActor
    func testSlashMidLineDoesNotSwitch() {
        let controller = chineseAndAsciiController()
        let monitor = makeSlashMonitor(controller)
        monitor.start()

        monitor.handleKey(keycode: 0, typed: "a") // content keystroke → no longer line start
        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertTrue(controller.selected.isEmpty)
        monitor.stop()
    }

    @MainActor
    func testEnterReArmsLineStartForSlash() {
        let controller = chineseAndAsciiController()
        let monitor = makeSlashMonitor(controller)
        monitor.start()

        monitor.handleKey(keycode: 0, typed: "a")   // content → mid line
        monitor.handleKey(keycode: 36, typed: "\r") // return → fresh line
        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertEqual(controller.selected, ["abc"])
        monitor.stop()
    }

    @MainActor
    func testNoteContextResetReArmsLineStartForSlash() {
        let controller = chineseAndAsciiController()
        let monitor = makeSlashMonitor(controller)
        monitor.start()

        monitor.handleKey(keycode: 0, typed: "a") // content → mid line
        monitor.noteContextReset()                 // focus moved to a fresh field
        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertEqual(controller.selected, ["abc"])
        monitor.stop()
    }

    @MainActor
    func testCaretProbeAtLineStartArmsEvenWhenFallbackSaysMidLine() {
        // Regression for the IME case: after typing/deleting CJK the keystroke
        // fallback is stuck "mid line", but the AX caret probe sees an empty line.
        // The probe must win so `/` switches to English.
        let controller = chineseAndAsciiController() // current = wechat (Chinese)
        var probeAtLineStart: Bool? = nil
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { probeAtLineStart }
        )
        monitor.start()

        // Simulate prior CJK typing then deletion: fallback flag is now false.
        monitor.handleKey(keycode: 0, typed: "a")
        // ...but the focused field is actually empty (caret at line start).
        probeAtLineStart = true
        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertEqual(controller.selected, ["abc"])
        monitor.stop()
    }

    @MainActor
    func testCaretProbeMidLineDisarmsEvenWhenFallbackSaysLineStart() {
        // Inverse: the probe sees content before the caret, so `/` must NOT switch
        // even though the keystroke fallback would have armed.
        let controller = chineseAndAsciiController()
        var probeAtLineStart: Bool? = false
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { probeAtLineStart }
        )
        monitor.start()

        // Fallback flag is true at the very start, but the probe says mid-line.
        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertTrue(controller.selected.isEmpty)

        // When the probe goes unavailable (nil), fall back to the keystroke flag.
        probeAtLineStart = nil
        monitor.handleKey(keycode: 36, typed: "\r") // Enter → fallback re-arms
        monitor.handleKey(keycode: 44, typed: "/")
        XCTAssertEqual(controller.selected, ["abc"])
        monitor.stop()
    }

    @MainActor
    func testBackspaceReArmsFallbackWhenProbeUnavailable() {
        // Terminal / AX-blind case (probe nil): typing then deleting a line back to
        // empty must let `/` switch again. Enter is not the only way to re-arm.
        let controller = chineseAndAsciiController()
        let monitor = SlashTriggerMonitor(
            isEnabledProvider: { true },
            inputSourceController: controller,
            lineStartProbe: { nil } // simulate a terminal whose caret can't be read
        )
        monitor.start()

        monitor.handleKey(keycode: 0, typed: "a")       // content → fallback false
        monitor.handleKey(keycode: 44, typed: "/")      // mid line → no switch
        XCTAssertTrue(controller.selected.isEmpty)

        monitor.handleKey(keycode: 51, typed: "\u{7f}") // backspace → re-arm
        monitor.handleKey(keycode: 44, typed: "/")      // line start again → switch
        XCTAssertEqual(controller.selected, ["abc"])
        monitor.stop()
    }

    @MainActor
    func testBareShiftFromChineseSwitchesToAsciiThenRestoresOnIdle() {
        let controller = chineseAndAsciiController()
        let monitor = makeTransientMonitor(controller)

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
    func testBareShiftFromChineseReactivatesSavedChineseOnIdleViaAlternateChineseSource() async {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "zh.target", kind: .chinese),
            makeSource(id: "zh.bridge", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "zh.target"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            inputSourceController: controller,
            reactivationDelayNanoseconds: 0
        )
        monitor.start()

        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])
        XCTAssertEqual(controller.currentInputSourceIDValue, "abc")

        monitor.fireIdleTimeoutForTesting()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.selected, [
            "abc",
            "zh.bridge",
            "zh.target"
        ])
        XCTAssertEqual(controller.currentInputSourceIDValue, "zh.target")
        monitor.stop()
    }

    @MainActor
    func testShiftModifiedKeyDoesNotSwitchSources() {
        let controller = chineseAndAsciiController()
        let monitor = makeTransientMonitor(controller)

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
        let controller = chineseAndAsciiController()
        let monitor = makeTransientMonitor(controller)

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
    func testSecondBareShiftReactivatesPreviousChineseViaAlternateChineseSource() async {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "zh.target", kind: .chinese),
            makeSource(id: "zh.bridge", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "zh.target"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            inputSourceController: controller,
            reactivationDelayNanoseconds: 0
        )
        monitor.start()

        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.selected, [
            "abc",
            "zh.bridge",
            "zh.target"
        ])
        XCTAssertEqual(controller.currentInputSourceIDValue, "zh.target")
        monitor.stop()
    }

    @MainActor
    func testFocusDecisionClearsShiftTransientSoSchedulerCanApplyTarget() {
        let controller = chineseAndAsciiController()
        let monitor = makeTransientMonitor(controller)

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
        let controller = chineseAndAsciiController()
        let monitor = makeTransientMonitor(controller)

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
    func testBareShiftFromAsciiOutsideTransientReactivatesRememberedChineseSource() async {
        let controller = StubController()
        controller.availableInputSources = [
            makeSource(id: "zh.target", kind: .chinese),
            makeSource(id: "zh.bridge", kind: .chinese),
            makeSource(id: "abc", kind: .ascii)
        ]
        controller.currentInputSourceIDValue = "zh.target"
        let monitor = TransientEnglishMonitor(
            isEnabledProvider: { true },
            idleSecondsProvider: { 5 },
            inputSourceController: controller,
            reactivationDelayNanoseconds: 0
        )
        monitor.start()

        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        XCTAssertEqual(controller.selected, ["abc"])

        monitor.handleFocusDecision(SwitchDecision(targetInputSourceID: "abc", reason: "app rule", sourceBundleID: "app", isPanelContext: false))
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(controller.selected, [
            "abc",
            "zh.bridge",
            "zh.target"
        ])
        XCTAssertEqual(controller.currentInputSourceIDValue, "zh.target")
        monitor.stop()
    }

    @MainActor
    func testFocusDecisionRemembersChineseTargetForLaterShiftFromAscii() {
        let controller = chineseAndAsciiController(current: "abc")
        let monitor = makeTransientMonitor(controller)

        monitor.start()
        monitor.handleFocusDecision(SwitchDecision(targetInputSourceID: "wechat", reason: "app rule", sourceBundleID: "app", isPanelContext: false))
        monitor.handleFlagsChanged(keyCode: 56, flags: .maskShift)
        monitor.handleFlagsChanged(keyCode: 56, flags: [])

        XCTAssertEqual(controller.selected, ["wechat"])
        monitor.stop()
    }
}
