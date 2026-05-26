import XCTest
@testable import AutoSwitch

final class ConfigStoreTests: XCTestCase {
    func testNoOpUpdateDoesNotSaveOrNotify() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)
        var changeCount = 0
        store.onChange = { changeCount += 1 }

        store.update { _ in }
        store.setGlobalDefaultInputSourceID(nil)

        XCTAssertEqual(changeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRoundTripPreservesRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)
        store.upsertAppRule(bundleID: "com.apple.Safari", displayName: "Safari", inputSourceID: "zh")
        store.setGlobalDefaultInputSourceID("abc")

        let reloaded = ConfigStore(fileURL: url)
        XCTAssertEqual(reloaded.config.globalDefaultInputSourceID, "abc")
        XCTAssertEqual(reloaded.config.appRules.first?.bundleID, "com.apple.Safari")
    }

    func testCorruptConfigFallsBackToDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = "not json".data(using: .utf8) else {
            XCTFail("UTF-8 encoding failed")
            return
        }
        try data.write(to: url)

        let store = ConfigStore(fileURL: url)

        XCTAssertEqual(store.config.schemaVersion, 1)
        XCTAssertTrue(store.config.appRules.isEmpty)
    }

    func testUpsertSpotlightRuleAddsBundleIDToObservedSet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.upsertSpotlightRule(
            bundleID: "com.qsapp.Quicksilver",
            displayName: "Quicksilver",
            inputSourceID: nil,
            enabled: true,
            isBuiltin: false
        )

        XCTAssertTrue(
            store.config.spotlightBundleIDs.contains("com.qsapp.Quicksilver"),
            "custom launcher bundle ID must be observed by the panel monitor"
        )
        XCTAssertEqual(
            store.config.spotlightBundleIDs,
            store.config.spotlightBundleIDs.sorted(),
            "spotlightBundleIDs must remain sorted"
        )
        XCTAssertEqual(
            store.config.spotlightBundleIDs.count,
            Set(store.config.spotlightBundleIDs).count,
            "spotlightBundleIDs must be deduplicated"
        )
        for builtin in BuiltinSpotlightBundles.defaultBundleIDs {
            XCTAssertTrue(
                store.config.spotlightBundleIDs.contains(builtin),
                "built-in \(builtin) must remain after upsert"
            )
        }
    }

    func testUpsertSpotlightRuleIsIdempotentForBundleIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.upsertSpotlightRule(bundleID: "com.qsapp.Quicksilver", displayName: "Quicksilver", inputSourceID: nil)
        store.upsertSpotlightRule(bundleID: "com.qsapp.Quicksilver", displayName: "Quicksilver", inputSourceID: "abc")

        let occurrences = store.config.spotlightBundleIDs.filter { $0 == "com.qsapp.Quicksilver" }.count
        XCTAssertEqual(occurrences, 1, "repeated upsert must not duplicate the bundle ID")
    }

    func testRemoveSpotlightRuleRemovesCustomBundleIDFromObservedSet() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.upsertSpotlightRule(bundleID: "com.qsapp.Quicksilver", displayName: "Quicksilver", inputSourceID: nil)
        XCTAssertTrue(store.config.spotlightBundleIDs.contains("com.qsapp.Quicksilver"))

        store.removeSpotlightRule(bundleID: "com.qsapp.Quicksilver")

        XCTAssertFalse(
            store.config.spotlightBundleIDs.contains("com.qsapp.Quicksilver"),
            "removed custom launcher must stop being observed"
        )
        XCTAssertTrue(store.config.spotlightRules.allSatisfy { $0.bundleID != "com.qsapp.Quicksilver" })
    }

    func testRemoveSpotlightRuleKeepsBuiltinBundleID() throws {
        guard let builtin = BuiltinSpotlightBundles.defaultBundleIDs.first else {
            XCTFail("expected at least one built-in spotlight bundle")
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.upsertSpotlightRule(bundleID: builtin, displayName: builtin, inputSourceID: nil, isBuiltin: true)
        store.removeSpotlightRule(bundleID: builtin)

        XCTAssertTrue(
            store.config.spotlightBundleIDs.contains(builtin),
            "built-in \(builtin) must remain observed even after its rule is removed"
        )
    }

    func testBulkSetInputSourceUpdatesAppAndSpotlightRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.upsertAppRule(bundleID: "com.apple.Safari", displayName: "Safari", inputSourceID: "abc")
        store.upsertAppRule(bundleID: "com.apple.Terminal", displayName: "Terminal", inputSourceID: "abc")
        store.upsertSpotlightRule(bundleID: "com.apple.Spotlight", displayName: "Spotlight", inputSourceID: nil, isBuiltin: true)

        store.setInputSourceForRules(
            appBundleIDs: ["com.apple.Safari"],
            spotlightBundleIDs: ["com.apple.Spotlight"],
            inputSourceID: "zh"
        )

        XCTAssertEqual(store.config.appRules.first { $0.bundleID == "com.apple.Safari" }?.inputSourceID, "zh")
        XCTAssertEqual(store.config.appRules.first { $0.bundleID == "com.apple.Terminal" }?.inputSourceID, "abc")
        XCTAssertEqual(store.config.spotlightRules.first { $0.bundleID == "com.apple.Spotlight" }?.inputSourceID, "zh")
    }

    func testBulkRemoveRulesPreservesBuiltinSpotlightObservationAndRemovesCustomObservation() throws {
        guard let builtin = BuiltinSpotlightBundles.defaultBundleIDs.first else {
            XCTFail("expected at least one built-in spotlight bundle")
            return
        }
        let custom = "com.qsapp.Quicksilver"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        store.upsertAppRule(bundleID: "com.apple.Safari", displayName: "Safari", inputSourceID: "abc")
        store.upsertSpotlightRule(bundleID: builtin, displayName: builtin, inputSourceID: "abc", isBuiltin: true)
        store.upsertSpotlightRule(bundleID: custom, displayName: "Quicksilver", inputSourceID: "abc")

        store.removeRules(
            appBundleIDs: ["com.apple.Safari"],
            spotlightBundleIDs: [builtin, custom]
        )

        XCTAssertTrue(store.config.appRules.isEmpty)
        XCTAssertTrue(store.config.spotlightRules.isEmpty)
        XCTAssertTrue(store.config.spotlightBundleIDs.contains(builtin))
        XCTAssertFalse(store.config.spotlightBundleIDs.contains(custom))
    }
}
