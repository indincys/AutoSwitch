import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Status") {
                CurrentInputSourceRow()
                AccessibilityRow()
                LaunchAtLoginRow()
                if let error = appState.configStore.lastErrorMessage {
                    Label("Config error: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if DocumentSwitchChecker.currentPreference() == true {
                    Label("macOS document input switching is on. Disable it in Keyboard settings to avoid system overrides.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                InputSourcePicker(
                    sources: appState.inputSourceController.availableInputSources,
                    selection: Binding(
                        get: { appState.configStore.config.globalDefaultInputSourceID },
                        set: { appState.configStore.setGlobalDefaultInputSourceID($0) }
                    )
                )
            } header: {
                Text("Default Input Source")
            } footer: {
                Text("Used when no app rule matches the active app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                AboutRow()
            }
        }
        .formStyle(.grouped)
    }
}

private struct CurrentInputSourceRow: View {
    @EnvironmentObject private var appState: AppState

    private var name: String {
        guard let id = appState.inputSourceController.currentInputSourceIDValue else {
            return "Unknown"
        }
        return appState.inputSourceController.inputSource(with: id)?.localizedName ?? id
    }

    var body: some View {
        LabeledContent("Current Input Source") {
            Text(name).foregroundStyle(.secondary)
        }
    }
}

private struct AccessibilityRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack {
            Text("Accessibility")
            Spacer()
            if appState.permissionsManager.accessibilityAuthorized {
                StatusPill(title: "Granted", systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                StatusPill(title: "Required", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                Button("Grant…") {
                    appState.permissionsManager.requestAccessibilityAccess()
                    appState.permissionsManager.openAccessibilitySettings()
                }
                .controlSize(.small)
            }
        }
    }
}

private struct LaunchAtLoginRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("Launch at login", isOn: Binding(
            get: { appState.configStore.config.launchAtLogin },
            set: {
                appState.configStore.setLaunchAtLogin($0)
                appState.loginItemManager.setEnabled($0)
            }
        ))
        if appState.loginItemManager.status == .requiresApproval {
            Label("Login item needs approval in System Settings.", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct AboutRow: View {
    @EnvironmentObject private var appState: AppState

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    var body: some View {
        LabeledContent("Version") {
            Text(version).foregroundStyle(.secondary)
        }
        HStack {
            Button("Check for Updates") {
                appState.updaterController.checkForUpdates()
            }
            .disabled(!appState.updaterController.canCheckForUpdates)

            Spacer()

            Text(appState.updaterController.lastCheckMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        if !appState.updaterController.isConfiguredForRelease {
            Label("Updates are not configured for this build.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
