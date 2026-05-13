import Foundation

enum InputSourceKind: String, Codable, CaseIterable, Hashable {
    case ascii
    case chinese
    case other
    case system
}

struct InputSource: Identifiable, Codable, Hashable {
    var id: String
    var localizedName: String
    var category: String
    var languages: [String]
    var kind: InputSourceKind
    var isEnabled: Bool
    var isSelectCapable: Bool
}

extension Array where Element == InputSource {
    func selectableForPicker() -> [InputSource] {
        filter { $0.isEnabled && $0.isSelectCapable }
    }

    func displayLabel(for source: InputSource) -> String {
        let sameName = filter { $0.localizedName == source.localizedName }
        guard sameName.count > 1 else { return source.localizedName }
        if let lang = source.languages.first, !lang.isEmpty {
            return "\(source.localizedName) (\(lang))"
        }
        if let suffix = source.id.split(separator: ".").last {
            return "\(source.localizedName) — \(suffix)"
        }
        return source.localizedName
    }
}
