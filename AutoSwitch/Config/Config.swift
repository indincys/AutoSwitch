import Foundation

struct AppRule: Codable, Hashable, Identifiable {
    var id: String { bundleID }

    var bundleID: String
    var displayName: String
    var inputSourceID: String
    var enabled: Bool
    var lastSeenPath: String?
}

struct SpotlightRule: Codable, Hashable, Identifiable {
    var id: String { bundleID }

    var bundleID: String
    var displayName: String
    var inputSourceID: String?
    var enabled: Bool
    var isBuiltin: Bool
}

struct Config: Codable, Hashable {
    var schemaVersion: Int = 1
    var globalDefaultInputSourceID: String?
    var appRules: [AppRule] = []
    var spotlightRules: [SpotlightRule] = []
    var spotlightBundleIDs: [String] = BuiltinSpotlightBundles.defaultBundleIDs
    var launchAtLogin: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

struct SwitchDecision: Hashable {
    var targetInputSourceID: String
    var reason: String
    var sourceBundleID: String?
    var isPanelContext: Bool
}
