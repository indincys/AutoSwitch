import AppKit
import SwiftUI

struct SpotlightTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddPopover: Bool = false

    private var filteredRules: [SpotlightRule] {
        let rules = appState.configStore.config.spotlightRules
        guard !searchText.isEmpty else { return rules }
        let needle = searchText.lowercased()
        return rules.filter { rule in
            rule.displayName.lowercased().contains(needle)
                || rule.bundleID.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !appState.permissionsManager.accessibilityAuthorized {
                AccessibilityBanner()
            }

            RuleToolbar(
                searchText: $searchText,
                searchPrompt: "Search launchers",
                addLabel: "Add Launcher",
                addAction: { showAddPopover = true },
                isAddPresented: $showAddPopover
            ) {
                AddAppPopover(title: "Add Launcher") { bundleID, displayName, _ in
                    addRule(bundleID: bundleID, displayName: displayName)
                }
            }

            Divider()

            if appState.configStore.config.spotlightRules.isEmpty {
                ContentUnavailableView {
                    Label("No Launchers", systemImage: "magnifyingglass")
                } description: {
                    Text("Add Spotlight-like apps (Raycast, Alfred, hapiGO…). AutoSwitch picks an input source when their panel appears and restores it when the panel closes.")
                } actions: {
                    Button("Add Launcher") { showAddPopover = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredRules) { rule in
                        SpotlightRuleRow(rule: rule)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func addRule(bundleID: String, displayName: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.configStore.upsertSpotlightRule(
            bundleID: trimmed,
            displayName: displayName.isEmpty ? trimmed : displayName,
            inputSourceID: nil,
            enabled: true,
            isBuiltin: false
        )
        showAddPopover = false
    }
}

private struct AccessibilityBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission required")
                    .font(.callout.weight(.semibold))
                Text("Launchers rely on the Accessibility API to detect floating panels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant…") {
                appState.permissionsManager.requestAccessibilityAccess()
                appState.permissionsManager.openAccessibilitySettings()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}

private struct SpotlightRuleRow: View {
    @EnvironmentObject private var appState: AppState
    let rule: SpotlightRule

    private var icon: NSImage? {
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        return nil
    }

    private var isInputSourceMissing: Bool {
        guard let id = rule.inputSourceID, !id.isEmpty else { return false }
        return appState.inputSourceController.inputSource(with: id) == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(icon: icon, fallbackSystemImage: "magnifyingglass")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if rule.isBuiltin {
                        StatusPill(title: "Built-in", systemImage: "shippingbox", tint: .secondary)
                    }
                    if isInputSourceMissing {
                        StatusPill(title: "Missing Source", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }
                Text(rule.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InputSourcePicker(
                sources: appState.inputSourceController.availableInputSources,
                selection: Binding(
                    get: { rule.inputSourceID },
                    set: { newValue in
                        appState.configStore.upsertSpotlightRule(
                            bundleID: rule.bundleID,
                            displayName: rule.displayName,
                            inputSourceID: newValue,
                            enabled: rule.enabled,
                            isBuiltin: rule.isBuiltin
                        )
                    }
                )
            )
            .labelsHidden()
            .frame(width: 180)

            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    appState.configStore.upsertSpotlightRule(
                        bundleID: rule.bundleID,
                        displayName: rule.displayName,
                        inputSourceID: rule.inputSourceID,
                        enabled: enabled,
                        isBuiltin: rule.isBuiltin
                    )
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                appState.configStore.removeSpotlightRule(bundleID: rule.bundleID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete launcher")
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}
