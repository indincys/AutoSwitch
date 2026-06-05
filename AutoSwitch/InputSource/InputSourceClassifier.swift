import Foundation

/// Single source of truth for mapping a TIS input source to an ``InputSourceKind``.
///
/// `InputSourceController` builds every `InputSource` through this classifier;
/// nothing else should re-implement the rules.
///
/// Matching is intentionally token-based rather than loose substring matching.
/// The earlier substring approach misfired in real cases — e.g. the built-in
/// Pinyin source id `com.apple.inputmethod.SCIM.ITABC` contains "abc", so an
/// ascii-first `contains("abc")` check wrongly tagged Chinese Pinyin as ascii,
/// and `contains("us")` matched layouts like "Belarusian"/"Australian". We now
/// resolve Chinese first (by primary language tag / known IME ids) and only then
/// recognize a small allowlist of Latin keyboard-layout ids as ascii.
enum InputSourceClassifier {
    /// Lowercased trailing id components of Latin keyboard layouts AutoSwitch can
    /// use as a "type English directly here" target.
    private static let asciiLayoutSuffixes: Set<String> = [
        "abc", "us", "usextended", "british", "irish",
        "australian", "canadian", "canadianenglish"
    ]

    /// Lowercased id fragments that identify a Chinese input method even when the
    /// reported languages are empty.
    private static let chineseIDFragments = [
        "pinyin", "zhuyin", "wubi", "cangjie", "shuangpin", "sogou", "rime"
    ]

    static func classify(sourceID: String, category: String, languages: [String]) -> InputSourceKind {
        let normalized = sourceID.lowercased()
        let languageTokens = languages.map { $0.lowercased() }
        let primaryLanguage = languageTokens.first?.split(separator: "-").first.map(String.init)
        let idSuffix = normalized.split(separator: ".").last.map(String.init)

        // Chinese first: a source whose primary/declared language is Chinese, or
        // whose id names a known Chinese IME. Checking this before ascii avoids
        // mis-tagging ids that merely contain "abc" (e.g. SCIM.ITABC).
        if primaryLanguage == "zh"
            || languageTokens.contains(where: { $0 == "zh" || $0.hasPrefix("zh-") })
            || chineseIDFragments.contains(where: normalized.contains) {
            return .chinese
        }

        // ASCII: a known Latin keyboard layout, or a layout whose primary language
        // is English.
        if let idSuffix, asciiLayoutSuffixes.contains(idSuffix) {
            return .ascii
        }
        if primaryLanguage == "en" {
            return .ascii
        }

        // Other Apple-provided sources (non-Latin layouts, emoji/dictation, etc.).
        if normalized.hasPrefix("com.apple.") {
            return .system
        }

        // Third-party input methods for other languages.
        return .other
    }
}
