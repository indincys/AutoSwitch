import AppKit
import SwiftUI

struct AppRulesTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddPopover: Bool = false

    fileprivate enum UnifiedKind: Hashable {
        case app
        case launcher
    }

    fileprivate struct UnifiedRuleHandle: Identifiable, Hashable {
        let kind: UnifiedKind
        let bundleID: String
        let displayName: String
        var id: String { "\(kind):\(bundleID)" }
    }

    private var allRules: [UnifiedRuleHandle] {
        let apps = appState.configStore.config.appRules.map {
            UnifiedRuleHandle(kind: .app, bundleID: $0.bundleID, displayName: $0.displayName)
        }
        let launchers = appState.configStore.config.spotlightRules.map {
            UnifiedRuleHandle(kind: .launcher, bundleID: $0.bundleID, displayName: $0.displayName)
        }
        return (apps + launchers).sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var filteredRules: [UnifiedRuleHandle] {
        guard !searchText.isEmpty else { return allRules }
        let needle = searchText.lowercased()
        return allRules.filter { handle in
            handle.displayName.lowercased().contains(needle)
                || handle.bundleID.lowercased().contains(needle)
        }
    }

    private var hasLauncherRules: Bool {
        !appState.configStore.config.spotlightRules.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasLauncherRules && !appState.permissionsManager.accessibilityAuthorized {
                AccessibilityBanner()
            }

            RuleToolbar(
                searchText: $searchText,
                searchPrompt: "Search",
                addLabel: "Add",
                addAction: { showAddPopover = true },
                isAddPresented: $showAddPopover
            ) {
                AddAppPopover(
                    availableInputSources: appState.inputSourceController.availableInputSources,
                    defaultInputSourceID: appState.configStore.config.globalDefaultInputSourceID
                ) { items, inputSourceID in
                    addRules(items: items, inputSourceID: inputSourceID)
                }
            }

            Divider()

            if allRules.isEmpty {
                ContentUnavailableView {
                    Label("No Apps", systemImage: "app.badge")
                } description: {
                    Text("Add an app to set its input source when it activates.")
                } actions: {
                    Button("Add") { showAddPopover = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                List {
                    ForEach(filteredRules) { handle in
                        UnifiedRuleRow(kind: handle.kind, bundleID: handle.bundleID)
                            .id(handle.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func addRules(items: [AddAppItem], inputSourceID: String?) {
        guard !items.isEmpty else { return }
        let resolvedAppID = inputSourceID
            ?? appState.configStore.config.globalDefaultInputSourceID
            ?? appState.inputSourceController.availableInputSources.first?.id
            ?? ""
        let knownLaunchers = Set(BuiltinSpotlightBundles.defaultBundleIDs)

        for item in items {
            let trimmed = item.bundleID.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let name = item.displayName.isEmpty ? trimmed : item.displayName
            if knownLaunchers.contains(trimmed) {
                appState.configStore.upsertSpotlightRule(
                    bundleID: trimmed,
                    displayName: name,
                    inputSourceID: inputSourceID,
                    enabled: true,
                    isBuiltin: false
                )
            } else {
                appState.configStore.upsertAppRule(
                    bundleID: trimmed,
                    displayName: name,
                    inputSourceID: resolvedAppID,
                    enabled: true,
                    lastSeenPath: item.path
                )
            }
        }
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
                Text("Some apps need Accessibility to detect when their panel appears.")
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

private struct UnifiedRuleRow: View {
    @EnvironmentObject private var appState: AppState
    let kind: AppRulesTab.UnifiedKind
    let bundleID: String

    private var appRule: AppRule? {
        guard kind == .app else { return nil }
        return appState.configStore.config.appRules.first { $0.bundleID == bundleID }
    }

    private var launcherRule: SpotlightRule? {
        guard kind == .launcher else { return nil }
        return appState.configStore.config.spotlightRules.first { $0.bundleID == bundleID }
    }

    private var displayName: String {
        appRule?.displayName ?? launcherRule?.displayName ?? bundleID
    }

    private var enabled: Bool {
        appRule?.enabled ?? launcherRule?.enabled ?? true
    }

    private var inputSourceID: String? {
        if let r = appRule {
            return r.inputSourceID.isEmpty ? nil : r.inputSourceID
        }
        return launcherRule?.inputSourceID
    }

    private var lastSeenPath: String? {
        appRule?.lastSeenPath
    }

    private var icon: NSImage? {
        if let path = lastSeenPath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
        return nil
    }

    private var pickerSources: [InputSource] {
        appState.inputSourceController.availableInputSources.selectableForPicker()
    }

    private var isInputSourceMissing: Bool {
        guard let id = inputSourceID, !id.isEmpty else { return false }
        return !pickerSources.contains(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(icon: icon)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.body)
                        .lineLimit(1)
                    if isInputSourceMissing {
                        StatusPill(title: "Missing Source", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }
                Text(bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            InputSourcePicker(
                sources: appState.inputSourceController.availableInputSources,
                selection: Binding(
                    get: { inputSourceID },
                    set: { newValue in setInputSource(newValue) }
                )
            )
            .labelsHidden()
            .frame(width: 180)

            Toggle("Enabled", isOn: Binding(
                get: { enabled },
                set: { setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button(action: deleteRule) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete")
        }
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.55)
    }

    private func setInputSource(_ newValue: String?) {
        if let r = appRule {
            appState.configStore.upsertAppRule(
                bundleID: r.bundleID,
                displayName: r.displayName,
                inputSourceID: newValue ?? "",
                enabled: r.enabled,
                lastSeenPath: r.lastSeenPath
            )
        } else if let r = launcherRule {
            appState.configStore.upsertSpotlightRule(
                bundleID: r.bundleID,
                displayName: r.displayName,
                inputSourceID: newValue,
                enabled: r.enabled,
                isBuiltin: r.isBuiltin
            )
        }
    }

    private func setEnabled(_ value: Bool) {
        if let r = appRule {
            appState.configStore.upsertAppRule(
                bundleID: r.bundleID,
                displayName: r.displayName,
                inputSourceID: r.inputSourceID,
                enabled: value,
                lastSeenPath: r.lastSeenPath
            )
        } else if let r = launcherRule {
            appState.configStore.upsertSpotlightRule(
                bundleID: r.bundleID,
                displayName: r.displayName,
                inputSourceID: r.inputSourceID,
                enabled: value,
                isBuiltin: r.isBuiltin
            )
        }
    }

    private func deleteRule() {
        switch kind {
        case .app:
            appState.configStore.removeAppRule(bundleID: bundleID)
        case .launcher:
            appState.configStore.removeSpotlightRule(bundleID: bundleID)
        }
    }
}
