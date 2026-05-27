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
    var shellPromptDetectionEnabled: Bool = true
    var slashTriggerEnabled: Bool = true
    var transientEnglishEnabled: Bool = true
    var transientEnglishIdleSeconds: Int = 10
    var showMenuBarIcon: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case globalDefaultInputSourceID
        case appRules
        case spotlightRules
        case spotlightBundleIDs
        case launchAtLogin
        case shellPromptDetectionEnabled
        case slashTriggerEnabled
        case transientEnglishEnabled
        case transientEnglishIdleSeconds
        case showMenuBarIcon
        case createdAt
        case updatedAt
    }

    init(
        schemaVersion: Int = 1,
        globalDefaultInputSourceID: String? = nil,
        appRules: [AppRule] = [],
        spotlightRules: [SpotlightRule] = [],
        spotlightBundleIDs: [String] = BuiltinSpotlightBundles.defaultBundleIDs,
        launchAtLogin: Bool = false,
        shellPromptDetectionEnabled: Bool = true,
        slashTriggerEnabled: Bool = true,
        transientEnglishEnabled: Bool = true,
        transientEnglishIdleSeconds: Int = 10,
        showMenuBarIcon: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.globalDefaultInputSourceID = globalDefaultInputSourceID
        self.appRules = appRules
        self.spotlightRules = spotlightRules
        self.spotlightBundleIDs = spotlightBundleIDs
        self.launchAtLogin = launchAtLogin
        self.shellPromptDetectionEnabled = shellPromptDetectionEnabled
        self.slashTriggerEnabled = slashTriggerEnabled
        self.transientEnglishEnabled = transientEnglishEnabled
        self.transientEnglishIdleSeconds = transientEnglishIdleSeconds
        self.showMenuBarIcon = showMenuBarIcon
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        globalDefaultInputSourceID = try container.decodeIfPresent(String.self, forKey: .globalDefaultInputSourceID)
        appRules = try container.decodeIfPresent([AppRule].self, forKey: .appRules) ?? []
        spotlightRules = try container.decodeIfPresent([SpotlightRule].self, forKey: .spotlightRules) ?? []
        spotlightBundleIDs = try container.decodeIfPresent([String].self, forKey: .spotlightBundleIDs)
            ?? BuiltinSpotlightBundles.defaultBundleIDs
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        shellPromptDetectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .shellPromptDetectionEnabled) ?? true
        slashTriggerEnabled = try container.decodeIfPresent(Bool.self, forKey: .slashTriggerEnabled) ?? true
        transientEnglishEnabled = try container.decodeIfPresent(Bool.self, forKey: .transientEnglishEnabled) ?? true
        transientEnglishIdleSeconds = try container.decodeIfPresent(Int.self, forKey: .transientEnglishIdleSeconds) ?? 10
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct SwitchDecision: Hashable {
    var targetInputSourceID: String
    var reason: String
    var sourceBundleID: String?
    var isPanelContext: Bool
}
