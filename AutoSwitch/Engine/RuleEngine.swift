import Foundation

struct RuleEngine {
    func resolve(
        bundleID: String?,
        isPanelContext: Bool,
        config: Config,
        availableInputSources: [InputSource],
        shellPromptDetected: Bool = false,
        tuiPromptDetected: Bool = false
    ) -> SwitchDecision? {
        let sourceLookup = InputSourceLookup(availableInputSources)

        // TUI prompt overrides shell prompt and app rules: when we see Claude
        // Code / Codex's TUI input box, force Chinese regardless of what the
        // app rule says.
        if tuiPromptDetected, config.shellPromptDetectionEnabled, !isPanelContext {
            if let chinese = sourceLookup.chineseFallback(preferring: config.globalDefaultInputSourceID) {
                return SwitchDecision(
                    targetInputSourceID: chinese.id,
                    reason: "tui prompt detected",
                    sourceBundleID: bundleID,
                    isPanelContext: false
                )
            }
            // No Chinese source — fall through.
        }

        if shellPromptDetected, config.shellPromptDetectionEnabled, !isPanelContext {
            if let ascii = sourceLookup.asciiFallback {
                return SwitchDecision(
                    targetInputSourceID: ascii.id,
                    reason: "shell prompt detected",
                    sourceBundleID: bundleID,
                    isPanelContext: false
                )
            }
            // No ASCII source available — fall through to normal resolution.
        }

        if isPanelContext, let bundleID {
            if let rule = config.spotlightRules.first(where: { $0.bundleID == bundleID && $0.enabled }) {
                if let sourceID = sourceLookup.resolvedSourceID(rule.inputSourceID) {
                    return SwitchDecision(targetInputSourceID: sourceID, reason: "spotlight rule", sourceBundleID: bundleID, isPanelContext: true)
                }
                return fallbackDecision(bundleID: bundleID, isPanelContext: true, reason: "spotlight fallback", config: config, sourceLookup: sourceLookup)
            }
            return fallbackDecision(bundleID: bundleID, isPanelContext: true, reason: "spotlight default", config: config, sourceLookup: sourceLookup)
        }

        if let bundleID,
           let rule = config.appRules.first(where: { $0.bundleID == bundleID && $0.enabled }) {
            if let sourceID = sourceLookup.resolvedSourceID(rule.inputSourceID) {
                return SwitchDecision(targetInputSourceID: sourceID, reason: "app rule", sourceBundleID: bundleID, isPanelContext: false)
            }
            return fallbackDecision(bundleID: bundleID, isPanelContext: false, reason: "app fallback", config: config, sourceLookup: sourceLookup)
        }

        return fallbackDecision(bundleID: bundleID, isPanelContext: false, reason: "global default", config: config, sourceLookup: sourceLookup)
    }

    private func fallbackDecision(
        bundleID: String?,
        isPanelContext: Bool,
        reason: String,
        config: Config,
        sourceLookup: InputSourceLookup
    ) -> SwitchDecision? {
        if let sourceID = sourceLookup.resolvedSourceID(config.globalDefaultInputSourceID) {
            return SwitchDecision(targetInputSourceID: sourceID, reason: reason, sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }

        if let ascii = sourceLookup.asciiFallback {
            return SwitchDecision(targetInputSourceID: ascii.id, reason: "ascii fallback", sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }

        if let system = sourceLookup.systemFallback {
            return SwitchDecision(targetInputSourceID: system.id, reason: "system fallback", sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }

        return sourceLookup.firstSource.map {
            SwitchDecision(targetInputSourceID: $0.id, reason: "first available fallback", sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }
    }
}

private struct InputSourceLookup {
    private let sourcesByID: [String: InputSource]
    private let allSources: [InputSource]
    let asciiFallback: InputSource?
    let systemFallback: InputSource?
    let firstSource: InputSource?

    init(_ sources: [InputSource]) {
        var sourcesByID: [String: InputSource] = [:]
        for source in sources where sourcesByID[source.id] == nil {
            sourcesByID[source.id] = source
        }
        self.sourcesByID = sourcesByID
        self.allSources = sources
        asciiFallback = sources.first { $0.kind == .ascii && $0.isEnabled && $0.isSelectCapable }
        systemFallback = sources.first { $0.kind == .system && $0.isEnabled && $0.isSelectCapable }
        firstSource = sources.first
    }

    func resolvedSourceID(_ candidateID: String?) -> String? {
        guard let candidateID, let source = sourcesByID[candidateID] else {
            return nil
        }
        guard source.isEnabled, source.isSelectCapable else { return nil }
        return candidateID
    }

    /// First selectable Chinese source, preferring the user's configured global
    /// default if it's Chinese (so we honor their preferred Pinyin/Wubi/etc.
    /// over an arbitrary first match).
    func chineseFallback(preferring preferredID: String?) -> InputSource? {
        if let preferredID,
           let preferred = sourcesByID[preferredID],
           preferred.kind == .chinese,
           preferred.isEnabled,
           preferred.isSelectCapable {
            return preferred
        }
        return allSources.first { $0.kind == .chinese && $0.isEnabled && $0.isSelectCapable }
    }
}
