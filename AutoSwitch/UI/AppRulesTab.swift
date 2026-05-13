import AppKit
import SwiftUI

struct AppRulesTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddPopover: Bool = false

    private var filteredRules: [AppRule] {
        let rules = appState.configStore.config.appRules
        guard !searchText.isEmpty else { return rules }
        let needle = searchText.lowercased()
        return rules.filter { rule in
            rule.displayName.lowercased().contains(needle)
                || rule.bundleID.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RuleToolbar(
                searchText: $searchText,
                searchPrompt: "Search apps",
                addLabel: "Add App",
                addAction: { showAddPopover = true },
                isAddPresented: $showAddPopover
            ) {
                AddAppPopover(title: "Add App Rule") { bundleID, displayName, path in
                    addRule(bundleID: bundleID, displayName: displayName, path: path)
                }
            }

            Divider()

            if appState.configStore.config.appRules.isEmpty {
                ContentUnavailableView {
                    Label("No App Rules", systemImage: "app.badge")
                } description: {
                    Text("Add an app to automatically switch its input source when it comes to the front.")
                } actions: {
                    Button("Add App") { showAddPopover = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredRules) { rule in
                        AppRuleRow(rule: rule)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func addRule(bundleID: String, displayName: String, path: String?) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let defaultID = appState.configStore.config.globalDefaultInputSourceID
            ?? appState.inputSourceController.availableInputSources.first?.id
            ?? ""
        appState.configStore.upsertAppRule(
            bundleID: trimmed,
            displayName: displayName.isEmpty ? trimmed : displayName,
            inputSourceID: defaultID,
            enabled: true,
            lastSeenPath: path
        )
        showAddPopover = false
    }
}

private struct AppRuleRow: View {
    @EnvironmentObject private var appState: AppState
    let rule: AppRule

    private var icon: NSImage? {
        if let path = rule.lastSeenPath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        return nil
    }

    private var isInputSourceMissing: Bool {
        appState.inputSourceController.inputSource(with: rule.inputSourceID) == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(icon: icon)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(rule.displayName)
                        .font(.body)
                        .lineLimit(1)
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

            Picker("Input Source", selection: Binding(
                get: { rule.inputSourceID },
                set: { newValue in
                    appState.configStore.upsertAppRule(
                        bundleID: rule.bundleID,
                        displayName: rule.displayName,
                        inputSourceID: newValue,
                        enabled: rule.enabled,
                        lastSeenPath: rule.lastSeenPath
                    )
                }
            )) {
                if isInputSourceMissing, !rule.inputSourceID.isEmpty {
                    Text("Missing (\(rule.inputSourceID))").tag(rule.inputSourceID)
                }
                ForEach(appState.inputSourceController.availableInputSources) { source in
                    Text(source.localizedName).tag(source.id)
                }
            }
            .labelsHidden()
            .frame(width: 180)

            Toggle("Enabled", isOn: Binding(
                get: { rule.enabled },
                set: { enabled in
                    appState.configStore.upsertAppRule(
                        bundleID: rule.bundleID,
                        displayName: rule.displayName,
                        inputSourceID: rule.inputSourceID,
                        enabled: enabled,
                        lastSeenPath: rule.lastSeenPath
                    )
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                appState.configStore.removeAppRule(bundleID: rule.bundleID)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete rule")
        }
        .padding(.vertical, 4)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}
