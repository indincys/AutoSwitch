import Foundation

enum InputSourceClassifier {
    static func classify(sourceID: String, category: String, languages: [String]) -> InputSourceKind {
        let normalized = sourceID.lowercased()
        let languageBlob = languages.joined(separator: " ").lowercased()

        if normalized.contains("abc") || normalized.contains("com.apple.keylayout") || languageBlob.contains("en") {
            return .ascii
        }

        if languageBlob.contains("zh")
            || normalized.contains("pinyin")
            || normalized.contains("zhuyin")
            || normalized.contains("wubi")
            || normalized.contains("cangjie")
            || normalized.contains("shuangpin") {
            return .chinese
        }

        if normalized.hasPrefix("com.apple.") {
            return .system
        }

        if category.lowercased().contains("inputmethod") {
            return .other
        }

        return .other
    }
}
