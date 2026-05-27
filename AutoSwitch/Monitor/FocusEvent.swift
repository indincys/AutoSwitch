import Foundation

enum FocusEvent: Equatable {
    case appActivated(bundleID: String)
    case panelShown(bundleID: String)
    case panelHidden(bundleID: String)
    case screenWoke
    case sessionActive
    case shellPromptStateChanged(bundleID: String?, detected: Bool)
    case tuiPromptStateChanged(bundleID: String?, detected: Bool)
}
