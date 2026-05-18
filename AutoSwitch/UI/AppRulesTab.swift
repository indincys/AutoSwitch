import AppKit
import SwiftUI

struct AppRulesTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddPopover: Bool = false
    @State private var selectedRuleIDs: Set<String> = []
    @State private var bulkInputSourceID: String?
    @State private var showBulkDeleteConfirmation: Bool = false

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

    private var selectedRules: [UnifiedRuleHandle] {
        allRules.filter { selectedRuleIDs.contains($0.id) }
    }

    private var selectedAppBundleIDs: Set<String> {
        Set(selectedRules.filter { $0.kind == .app }.map(\.bundleID))
    }

    private var selectedLauncherBundleIDs: Set<String> {
        Set(selectedRules.filter { $0.kind == .launcher }.map(\.bundleID))
    }

    private var selectableInputSources: [InputSource] {
        appState.inputSourceController.availableInputSources.selectableForPicker()
    }

    private var defaultBulkInputSourceID: String? {
        let configuredDefaultID = appState.configStore.config.globalDefaultInputSourceID
        if let configuredDefaultID,
           selectableInputSources.contains(where: { $0.id == configuredDefaultID }) {
            return configuredDefaultID
        }
        return selectableInputSources.first?.id
    }

    private var resolvedBulkInputSourceID: String? {
        bulkInputSourceID ?? defaultBulkInputSourceID
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasLauncherRules && !appState.permissionsManager.accessibilityAuthorized {
                AccessibilityBanner()
            }

            RuleToolbar(
                searchText: $searchText,
                searchPrompt: "搜索",
                addLabel: "添加",
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

            if !selectedRuleIDs.isEmpty {
                BulkRulesBar(
                    selectedCount: selectedRuleIDs.count,
                    availableInputSources: appState.inputSourceController.availableInputSources,
                    selection: Binding(
                        get: { resolvedBulkInputSourceID },
                        set: { bulkInputSourceID = $0 }
                    ),
                    applyAction: applyBulkInputSource,
                    deleteAction: { showBulkDeleteConfirmation = true },
                    clearAction: { selectedRuleIDs.removeAll() }
                )
            }

            Divider()

            if allRules.isEmpty {
                ContentUnavailableView {
                    Label("没有应用", systemImage: "app.badge")
                } description: {
                    Text("添加应用后，可在应用激活时自动切换到指定输入法。")
                } actions: {
                    Button("添加") { showAddPopover = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if filteredRules.isEmpty {
                ContentUnavailableView {
                    Label("没有找到匹配项", systemImage: "magnifyingglass")
                } description: {
                    Text("没有与“\(searchText)”匹配的规则。")
                }
            } else {
                List {
                    ForEach(filteredRules) { handle in
                        UnifiedRuleRow(
                            kind: handle.kind,
                            bundleID: handle.bundleID,
                            isSelected: Binding(
                                get: { selectedRuleIDs.contains(handle.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedRuleIDs.insert(handle.id)
                                    } else {
                                        selectedRuleIDs.remove(handle.id)
                                    }
                                }
                            )
                        )
                            .id(handle.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog(
            "删除所选规则？",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除 \(selectedRuleIDs.count) 条规则", role: .destructive) {
                deleteSelectedRules()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会从规则列表中移除所选应用。")
        }
        .onChange(of: allRules.map(\.id)) { _, currentIDs in
            selectedRuleIDs.formIntersection(Set(currentIDs))
        }
    }

    private func addRules(items: [AddAppItem], inputSourceID: String?) {
        guard !items.isEmpty else { return }
        let resolvedAppID = inputSourceID
            ?? appState.configStore.config.globalDefaultInputSourceID
            ?? appState.inputSourceController.availableInputSources.selectableForPicker().first?.id
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

    private func applyBulkInputSource() {
        guard let inputSourceID = resolvedBulkInputSourceID, !inputSourceID.isEmpty else { return }
        appState.configStore.setInputSourceForRules(
            appBundleIDs: selectedAppBundleIDs,
            spotlightBundleIDs: selectedLauncherBundleIDs,
            inputSourceID: inputSourceID
        )
    }

    private func deleteSelectedRules() {
        appState.configStore.removeRules(
            appBundleIDs: selectedAppBundleIDs,
            spotlightBundleIDs: selectedLauncherBundleIDs
        )
        selectedRuleIDs.removeAll()
    }
}

private struct AccessibilityBanner: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要辅助功能权限")
                    .font(.callout.weight(.semibold))
                Text("部分启动器面板需要辅助功能权限才能被检测到。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("授权...") {
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
    @Binding var isSelected: Bool

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

    private var fallbackInputSourceID: String? {
        let configuredDefaultID = appState.configStore.config.globalDefaultInputSourceID
        if let configuredDefaultID,
           pickerSources.contains(where: { $0.id == configuredDefaultID }) {
            return configuredDefaultID
        }
        return pickerSources.first?.id
    }

    private var resolvedInputSourceID: String? {
        inputSourceID ?? fallbackInputSourceID
    }

    private var isInputSourceMissing: Bool {
        guard let id = inputSourceID, !id.isEmpty else { return false }
        return !pickerSources.contains(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("选择", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)

            AppIcon(icon: icon)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(displayName)
                        .font(.body)
                        .lineLimit(1)
                    if isInputSourceMissing {
                        StatusPill(title: "缺失输入法", systemImage: "exclamationmark.triangle.fill", tint: .orange)
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
                    get: { resolvedInputSourceID },
                    set: { newValue in setInputSource(newValue) }
                )
            )
            .labelsHidden()
            .frame(width: 180)

            Toggle("启用", isOn: Binding(
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
            .help("删除")
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

private struct BulkRulesBar: View {
    let selectedCount: Int
    let availableInputSources: [InputSource]
    @Binding var selection: String?
    let applyAction: () -> Void
    let deleteAction: () -> Void
    let clearAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("已选择 \(selectedCount) 条")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            InputSourcePicker(
                sources: availableInputSources,
                selection: $selection
            )
            .labelsHidden()
            .frame(width: 190)

            Button {
                applyAction()
            } label: {
                Label("应用到所选", systemImage: "checkmark.circle")
            }
            .disabled(selection?.isEmpty ?? true)

            Button(role: .destructive) {
                deleteAction()
            } label: {
                Label("删除所选", systemImage: "trash")
            }

            Spacer()

            Button("清除选择") {
                clearAction()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
