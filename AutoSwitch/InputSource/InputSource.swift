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
