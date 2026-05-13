import XCTest
@testable import AutoSwitch

final class RuleEngineTests: XCTestCase {
    private let sources = [
        InputSource(id: "english", localizedName: "ABC", category: "keyboard", languages: ["en"], kind: .ascii, isEnabled: true, isSelectCapable: true),
        InputSource(id: "chinese", localizedName: "Pinyin", category: "inputmethod", languages: ["zh-Hans"], kind: .chinese, isEnabled: true, isSelectCapable: true),
        InputSource(id: "system", localizedName: "System", category: "keyboard", languages: [], kind: .system, isEnabled: true, isSelectCapable: true)
    ]

    func testAppRuleWinsOverGlobalDefault() {
        let engine = RuleEngine()
        let config = Config(
            globalDefaultInputSourceID: "english",
            appRules: [AppRule(bundleID: "com.apple.Safari", displayName: "Safari", inputSourceID: "chinese", enabled: true, lastSeenPath: nil)],
            spotlightRules: [],
            spotlightBundleIDs: BuiltinSpotlightBundles.defaultBundleIDs,
            launchAtLogin: false,
            createdAt: .now,
            updatedAt: .now
        )

        let decision = engine.resolve(bundleID: "com.apple.Safari", isPanelContext: false, config: config, availableInputSources: sources)
        XCTAssertEqual(decision?.targetInputSourceID, "chinese")
    }

    func testMissingRuleFallsBackToGlobalDefault() {
        let engine = RuleEngine()
        let config = Config(globalDefaultInputSourceID: "english")
        let sources = [
            InputSource(id: "english", localizedName: "ABC", category: "keyboard", languages: ["en"], kind: .ascii, isEnabled: true, isSelectCapable: true)
        ]
        let decision = engine.resolve(bundleID: "com.apple.Terminal", isPanelContext: false, config: config, availableInputSources: sources)
        XCTAssertEqual(decision?.targetInputSourceID, "english")
    }

    func testSpotlightRuleWinsInPanelContext() {
        let engine = RuleEngine()
        let config = Config(
            globalDefaultInputSourceID: "english",
            spotlightRules: [
                SpotlightRule(bundleID: "com.apple.Spotlight", displayName: "Spotlight", inputSourceID: "chinese", enabled: true, isBuiltin: true)
            ]
        )

        let decision = engine.resolve(bundleID: "com.apple.Spotlight", isPanelContext: true, config: config, availableInputSources: sources)

        XCTAssertEqual(decision?.targetInputSourceID, "chinese")
        XCTAssertEqual(decision?.reason, "spotlight rule")
        XCTAssertEqual(decision?.isPanelContext, true)
    }

    func testMissingRuleTargetFallsBackToGlobalDefault() {
        let engine = RuleEngine()
        let config = Config(
            globalDefaultInputSourceID: "english",
            appRules: [
                AppRule(bundleID: "com.apple.Terminal", displayName: "Terminal", inputSourceID: "missing", enabled: true, lastSeenPath: nil)
            ]
        )

        let decision = engine.resolve(bundleID: "com.apple.Terminal", isPanelContext: false, config: config, availableInputSources: sources)

        XCTAssertEqual(decision?.targetInputSourceID, "english")
        XCTAssertEqual(decision?.reason, "app fallback")
    }

    func testMissingGlobalDefaultFallsBackToAscii() {
        let engine = RuleEngine()
        let config = Config(globalDefaultInputSourceID: "missing")

        let decision = engine.resolve(bundleID: nil, isPanelContext: false, config: config, availableInputSources: sources)

        XCTAssertEqual(decision?.targetInputSourceID, "english")
        XCTAssertEqual(decision?.reason, "ascii fallback")
    }
}
