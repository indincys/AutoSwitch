import AppKit
import ApplicationServices
import SwiftUI

private let accessibilityPromptKey = "AXTrustedCheckOptionPrompt"

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var accessibilityAuthorized = false

    func refresh(prompt: Bool = false) {
        let options = [accessibilityPromptKey: prompt] as CFDictionary
        accessibilityAuthorized = AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibilityAccess() {
        refresh(prompt: true)
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
