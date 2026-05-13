import Foundation

struct RuleEngine {
    func resolve(
        bundleID: String?,
        isPanelContext: Bool,
        config: Config,
        availableInputSources: [InputSource]
    ) -> SwitchDecision? {
        let availableIDs = Set(availableInputSources.map(\.id))

        if isPanelContext, let bundleID {
            if let rule = config.spotlightRules.first(where: { $0.bundleID == bundleID && $0.enabled }) {
                if let sourceID = resolvedSourceID(rule.inputSourceID, availableIDs: availableIDs, availableInputSources: availableInputSources) {
                    return SwitchDecision(targetInputSourceID: sourceID, reason: "spotlight rule", sourceBundleID: bundleID, isPanelContext: true)
                }
                return fallbackDecision(bundleID: bundleID, isPanelContext: true, reason: "spotlight fallback", config: config, availableInputSources: availableInputSources)
            }
            return fallbackDecision(bundleID: bundleID, isPanelContext: true, reason: "spotlight default", config: config, availableInputSources: availableInputSources)
        }

        if let bundleID,
           let rule = config.appRules.first(where: { $0.bundleID == bundleID && $0.enabled }) {
            if let sourceID = resolvedSourceID(rule.inputSourceID, availableIDs: availableIDs, availableInputSources: availableInputSources) {
                return SwitchDecision(targetInputSourceID: sourceID, reason: "app rule", sourceBundleID: bundleID, isPanelContext: false)
            }
            return fallbackDecision(bundleID: bundleID, isPanelContext: false, reason: "app fallback", config: config, availableInputSources: availableInputSources)
        }

        return fallbackDecision(bundleID: bundleID, isPanelContext: false, reason: "global default", config: config, availableInputSources: availableInputSources)
    }

    private func fallbackDecision(
        bundleID: String?,
        isPanelContext: Bool,
        reason: String,
        config: Config,
        availableInputSources: [InputSource]
    ) -> SwitchDecision? {
        let availableIDs = Set(availableInputSources.map(\.id))
        if let sourceID = resolvedSourceID(config.globalDefaultInputSourceID, availableIDs: availableIDs, availableInputSources: availableInputSources) {
            return SwitchDecision(targetInputSourceID: sourceID, reason: reason, sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }

        if let ascii = availableInputSources.first(where: { $0.kind == .ascii && $0.isEnabled && $0.isSelectCapable }) {
            return SwitchDecision(targetInputSourceID: ascii.id, reason: "ascii fallback", sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }

        if let system = availableInputSources.first(where: { $0.kind == .system && $0.isEnabled && $0.isSelectCapable }) {
            return SwitchDecision(targetInputSourceID: system.id, reason: "system fallback", sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }

        return availableInputSources.first.map {
            SwitchDecision(targetInputSourceID: $0.id, reason: "first available fallback", sourceBundleID: bundleID, isPanelContext: isPanelContext)
        }
    }

    private func resolvedSourceID(
        _ candidateID: String?,
        availableIDs: Set<String>,
        availableInputSources: [InputSource]
    ) -> String? {
        guard let candidateID, availableIDs.contains(candidateID) else { return nil }
        guard let source = availableInputSources.first(where: { $0.id == candidateID }), source.isEnabled, source.isSelectCapable else {
            return nil
        }
        return candidateID
    }
}
