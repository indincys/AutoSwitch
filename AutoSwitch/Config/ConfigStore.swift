import Combine
import Foundation
import os.log

final class ConfigStore: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var lastErrorMessage: String?

    var onChange: (() -> Void)?

    private let logger = Logger(subsystem: "dev.autoswitch", category: "config")
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL = ConfigStore.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.config = Self.loadConfig(from: fileURL, fileManager: fileManager)
    }

    func reload() {
        config = Self.loadConfig(from: fileURL, fileManager: fileManager)
        lastErrorMessage = nil
        onChange?()
    }

    func update(_ mutate: (inout Config) -> Void) {
        var next = config
        mutate(&next)
        next.updatedAt = Date()
        config = next
        save()
        onChange?()
    }

    func setGlobalDefaultInputSourceID(_ inputSourceID: String?) {
        update { $0.globalDefaultInputSourceID = inputSourceID }
    }

    func upsertAppRule(bundleID: String, displayName: String, inputSourceID: String, enabled: Bool = true, lastSeenPath: String? = nil) {
        update { config in
            let rule = AppRule(
                bundleID: bundleID,
                displayName: displayName,
                inputSourceID: inputSourceID,
                enabled: enabled,
                lastSeenPath: lastSeenPath
            )
            if let index = config.appRules.firstIndex(where: { $0.bundleID == bundleID }) {
                config.appRules[index] = rule
            } else {
                config.appRules.append(rule)
            }
            config.appRules.sort { lhs, rhs in lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending }
        }
    }

    func removeAppRule(bundleID: String) {
        update { config in
            config.appRules.removeAll { $0.bundleID == bundleID }
        }
    }

    func upsertSpotlightRule(bundleID: String, displayName: String, inputSourceID: String?, enabled: Bool = true, isBuiltin: Bool = false) {
        update { config in
            let rule = SpotlightRule(
                bundleID: bundleID,
                displayName: displayName,
                inputSourceID: inputSourceID,
                enabled: enabled,
                isBuiltin: isBuiltin
            )
            if let index = config.spotlightRules.firstIndex(where: { $0.bundleID == bundleID }) {
                config.spotlightRules[index] = rule
            } else {
                config.spotlightRules.append(rule)
            }
            config.spotlightRules.sort { lhs, rhs in lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending }
            config.spotlightBundleIDs = Array(Set(config.spotlightBundleIDs).union([bundleID])).sorted()
        }
    }

    func removeSpotlightRule(bundleID: String) {
        update { config in
            config.spotlightRules.removeAll { $0.bundleID == bundleID }
            if !BuiltinSpotlightBundles.defaultBundleIDs.contains(bundleID) {
                config.spotlightBundleIDs.removeAll { $0 == bundleID }
            }
        }
    }

    func setInputSourceForRules(appBundleIDs: Set<String>, spotlightBundleIDs: Set<String>, inputSourceID: String) {
        guard !inputSourceID.isEmpty else { return }
        guard !appBundleIDs.isEmpty || !spotlightBundleIDs.isEmpty else { return }

        update { config in
            for index in config.appRules.indices where appBundleIDs.contains(config.appRules[index].bundleID) {
                config.appRules[index].inputSourceID = inputSourceID
            }
            for index in config.spotlightRules.indices where spotlightBundleIDs.contains(config.spotlightRules[index].bundleID) {
                config.spotlightRules[index].inputSourceID = inputSourceID
            }
        }
    }

    func removeRules(appBundleIDs: Set<String>, spotlightBundleIDs: Set<String>) {
        guard !appBundleIDs.isEmpty || !spotlightBundleIDs.isEmpty else { return }

        update { config in
            config.appRules.removeAll { appBundleIDs.contains($0.bundleID) }
            config.spotlightRules.removeAll { spotlightBundleIDs.contains($0.bundleID) }
            let customSpotlightBundleIDs = spotlightBundleIDs.subtracting(BuiltinSpotlightBundles.defaultBundleIDs)
            if !customSpotlightBundleIDs.isEmpty {
                config.spotlightBundleIDs.removeAll { customSpotlightBundleIDs.contains($0) }
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        update { $0.launchAtLogin = enabled }
    }

    func replaceSpotlightBundleIDs(_ bundleIDs: [String]) {
        update { $0.spotlightBundleIDs = Array(Set(bundleIDs)).sorted() }
    }

    static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseURL
            .appendingPathComponent("AutoSwitch", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.prettyPrinted.encode(config)
            try data.write(to: fileURL, options: [.atomic])
            lastErrorMessage = nil
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            logger.error("failed to save config: \(message, privacy: .public)")
        }
    }

    private static func loadConfig(from fileURL: URL, fileManager: FileManager) -> Config {
        do {
            let data = try Data(contentsOf: fileURL)
            let config = try JSONDecoder.autoswitch.decode(Config.self, from: data)
            return config
        } catch {
            if fileManager.fileExists(atPath: fileURL.path) {
                backupCorruptConfig(at: fileURL, fileManager: fileManager)
            }
            return Config()
        }
    }

    private static func backupCorruptConfig(at fileURL: URL, fileManager: FileManager) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("config.corrupt.\(timestamp).json")
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: fileURL, to: backupURL)
        } catch {
            // Best effort backup only.
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONDecoder {
    static var autoswitch: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
