import Foundation

enum DocumentSwitchChecker {
    private static let candidateKeys = [
        "AppleInputSourceSwitchOnDocument",
        "AppleEnableInputSourceSwitchOnDocument",
        "AppleInputSourceSwitchOnDocumentEnabled"
    ]

    static func currentPreference() -> Bool? {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.HIToolbox") ?? [:]
        for key in candidateKeys {
            if let value = domain[key] as? Bool {
                return value
            }
        }
        return nil
    }
}
