import AppKit
import SwiftUI

struct AppRulesTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""
    @State private var showAddPopover: Bool = false
    @State private var selectedRuleIDs: Set<String> = []
    @State private var bulkInputSourceID: String?
    @State private var showBulkDeleteConfirmation: Bool = false
    @State private var ruleHandles: [UnifiedRuleHandle] = []

    fileprivate enum UnifiedKind: Hashable {
        case app
        case launcher
    }

    fileprivate struct UnifiedRuleHandle: Identifiable, Hashable {
        let kind: UnifiedKind
        let bundleID: String
        let displayName: String
        let inputSourceID: String?
        let enabled: Bool
        let lastSeenPath: String?
        let isBuiltin: Bool
        let searchableText: String
        var id: String { "\(kind):\(bundleID)" }
    }

    private var visibleRuleHandles: [UnifiedRuleHandle] {
        if ruleHandles.isEmpty {
            return Self.makeRuleHandles(from: appState.configStore.config)
        }
        return ruleHandles
    }

    private static func makeRuleHandles(from config: Config) -> [UnifiedRuleHandle] {
        let apps = config.appRules.map {
            UnifiedRuleHandle(
                kind: .app,
                bundleID: $0.bundleID,
                displayName: $0.displayName,
                inputSourceID: $0.inputSourceID.isEmpty ? nil : $0.inputSourceID,
                enabled: $0.enabled,
                lastSeenPath: $0.lastSeenPath,
                isBuiltin: false,
                searchableText: "\($0.displayName)\n\($0.bundleID)".lowercased()
            )
        }
        let launchers = config.spotlightRules.map {
            UnifiedRuleHandle(
                kind: .launcher,
                bundleID: $0.bundleID,
                displayName: $0.displayName,
                inputSourceID: $0.inputSourceID,
                enabled: $0.enabled,
                lastSeenPath: nil,
                isBuiltin: $0.isBuiltin,
                searchableText: "\($0.displayName)\n\($0.bundleID)".lowercased()
            )
        }
        return (apps + launchers).sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var filteredRules: [UnifiedRuleHandle] {
        let rules = visibleRuleHandles
        guard !searchText.isEmpty else { return rules }
        let needle = searchText.lowercased()
        return rules.filter { $0.searchableText.contains(needle) }
    }

    private var hasLauncherRules: Bool {
        visibleRuleHandles.contains { $0.kind == .launcher }
    }

    private var selectedRules: [UnifiedRuleHandle] {
        visibleRuleHandles.filter { selectedRuleIDs.contains($0.id) }
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
        let rules = visibleRuleHandles
        let currentFilteredRules = filteredRules
        let currentFilteredRuleIDs = Set(currentFilteredRules.map(\.id))
        let allFilteredRulesSelected = !currentFilteredRuleIDs.isEmpty
            && currentFilteredRuleIDs.isSubset(of: selectedRuleIDs)
        let inputSourceOptions = InputSourceOptions.make(from: appState.inputSourceController.availableInputSources)
        let defaultInputSourceID = defaultInputSourceID(options: inputSourceOptions)

        VStack(spacing: 0) {
            if hasLauncherRules && !appState.permissionsManager.accessibilityAuthorized {
                AccessibilityBanner()
            }

            ZStack {
                if selectedRuleIDs.isEmpty {
                    RuleToolbar(
                        searchText: $searchText,
                        searchPrompt: "搜索",
                        addLabel: "添加",
                        addAction: { showAddPopover = true },
                        selectAllLabel: currentFilteredRuleIDs.isEmpty ? nil : "全选",
                        selectAllAction: currentFilteredRuleIDs.isEmpty ? nil : {
                            selectedRuleIDs.formUnion(currentFilteredRuleIDs)
                        },
                        isAddPresented: $showAddPopover
                    ) {
                        AddAppPopover(
                            availableInputSources: appState.inputSourceController.availableInputSources,
                            defaultInputSourceID: appState.configStore.config.globalDefaultInputSourceID
                        ) { items, inputSourceID in
                            addRules(items: items, inputSourceID: inputSourceID)
                        }
                    }
                } else {
                    BulkRulesBar(
                        selectedCount: selectedRuleIDs.count,
                        canSelectFilteredRules: !currentFilteredRuleIDs.isEmpty,
                        isAllFilteredSelected: allFilteredRulesSelected,
                        availableInputSources: appState.inputSourceController.availableInputSources,
                        selection: Binding(
                            get: { resolvedBulkInputSourceID },
                            set: { bulkInputSourceID = $0 }
                        ),
                        selectAllAction: {
                            selectedRuleIDs.formUnion(currentFilteredRuleIDs)
                        },
                        applyAction: applyBulkInputSource,
                        deleteAction: { showBulkDeleteConfirmation = true },
                        clearAction: { selectedRuleIDs.removeAll() }
                    )
                }
            }
            .frame(height: 52)

            Divider()

            if rules.isEmpty {
                ContentUnavailableView {
                    Label("没有应用", systemImage: "app.badge")
                } description: {
                    Text("添加应用后，可在应用激活时自动切换到指定输入法。")
                } actions: {
                    Button("添加") { showAddPopover = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if currentFilteredRules.isEmpty {
                ContentUnavailableView {
                    Label("没有找到匹配项", systemImage: "magnifyingglass")
                } description: {
                    Text("没有与“\(searchText)”匹配的规则。")
                }
            } else {
                List {
                    ForEach(currentFilteredRules) { handle in
                        UnifiedRuleRow(
                            handle: handle,
                            inputSourceOptions: inputSourceOptions,
                            defaultInputSourceID: defaultInputSourceID,
                            isSelected: Binding(
                                get: { selectedRuleIDs.contains(handle.id) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedRuleIDs.insert(handle.id)
                                    } else {
                                        selectedRuleIDs.remove(handle.id)
                                    }
                                }
                            ),
                            setInputSource: { setInputSource($0, for: handle) },
                            setEnabled: { setEnabled($0, for: handle) },
                            deleteAction: { deleteRule(handle) }
                        )
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
        .onAppear {
            rebuildRuleHandles(from: appState.configStore.config)
        }
        .onChange(of: appState.configStore.config) { _, config in
            rebuildRuleHandles(from: config)
        }
    }

    private func rebuildRuleHandles(from config: Config) {
        let handles = Self.makeRuleHandles(from: config)
        ruleHandles = handles
        selectedRuleIDs.formIntersection(Set(handles.map(\.id)))
    }

    private func defaultInputSourceID(options: [InputSourceOption]) -> String? {
        let configuredDefaultID = appState.configStore.config.globalDefaultInputSourceID
        if let configuredDefaultID,
           options.contains(where: { $0.id == configuredDefaultID }) {
            return configuredDefaultID
        }
        return options.first?.id
    }

    private func setInputSource(_ newValue: String?, for handle: UnifiedRuleHandle) {
        switch handle.kind {
        case .app:
            appState.configStore.upsertAppRule(
                bundleID: handle.bundleID,
                displayName: handle.displayName,
                inputSourceID: newValue ?? "",
                enabled: handle.enabled,
                lastSeenPath: handle.lastSeenPath
            )
        case .launcher:
            appState.configStore.upsertSpotlightRule(
                bundleID: handle.bundleID,
                displayName: handle.displayName,
                inputSourceID: newValue,
                enabled: handle.enabled,
                isBuiltin: handle.isBuiltin
            )
        }
    }

    private func setEnabled(_ value: Bool, for handle: UnifiedRuleHandle) {
        switch handle.kind {
        case .app:
            appState.configStore.upsertAppRule(
                bundleID: handle.bundleID,
                displayName: handle.displayName,
                inputSourceID: handle.inputSourceID ?? "",
                enabled: value,
                lastSeenPath: handle.lastSeenPath
            )
        case .launcher:
            appState.configStore.upsertSpotlightRule(
                bundleID: handle.bundleID,
                displayName: handle.displayName,
                inputSourceID: handle.inputSourceID,
                enabled: value,
                isBuiltin: handle.isBuiltin
            )
        }
    }

    private func deleteRule(_ handle: UnifiedRuleHandle) {
        switch handle.kind {
        case .app:
            appState.configStore.removeAppRule(bundleID: handle.bundleID)
        case .launcher:
            appState.configStore.removeSpotlightRule(bundleID: handle.bundleID)
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
    let handle: AppRulesTab.UnifiedRuleHandle
    let inputSourceOptions: [InputSourceOption]
    let defaultInputSourceID: String?
    @Binding var isSelected: Bool
    let setInputSource: (String?) -> Void
    let setEnabled: (Bool) -> Void
    let deleteAction: () -> Void

    private var resolvedInputSourceID: String? {
        handle.inputSourceID ?? defaultInputSourceID
    }

    private var isInputSourceMissing: Bool {
        guard let id = handle.inputSourceID, !id.isEmpty else { return false }
        return !inputSourceOptions.contains(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("选择", isOn: $isSelected)
                .labelsHidden()
                .toggleStyle(.checkbox)

            CachedRuleIcon(bundleID: handle.bundleID, lastSeenPath: handle.lastSeenPath)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(handle.displayName)
                        .font(.body)
                        .lineLimit(1)
                    if isInputSourceMissing {
                        StatusPill(title: "缺失输入法", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                }
                Text(handle.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RuleInputSourceMenu(
                options: inputSourceOptions,
                selection: resolvedInputSourceID,
                isMissing: isInputSourceMissing,
                onSelect: setInputSource
            )
            .frame(width: 180)

            Toggle("启用", isOn: Binding(
                get: { handle.enabled },
                set: { setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            Button(action: deleteAction) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除")
        }
        .padding(.vertical, 4)
        .opacity(handle.enabled ? 1 : 0.55)
    }
}

private struct CachedRuleIcon: View {
    let bundleID: String
    let lastSeenPath: String?
    @State private var icon: NSImage?

    private var iconKey: String {
        "\(bundleID)|\(lastSeenPath ?? "")"
    }

    var body: some View {
        AppIcon(icon: icon)
            .onAppear {
                loadIcon()
            }
            .onChange(of: iconKey) { _, _ in
                loadIcon()
            }
    }

    private func loadIcon() {
        icon = AppIconCache.shared.icon(forApplication: bundleID, lastSeenPath: lastSeenPath)
    }
}

private struct RuleInputSourceMenu: View {
    let options: [InputSourceOption]
    let selection: String?
    let isMissing: Bool
    let onSelect: (String?) -> Void

    private var label: String {
        InputSourceOptions.label(for: selection, options: options)
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.id)
                } label: {
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isMissing ? Color.orange : Color.primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(options.isEmpty)
    }
}

private struct BulkRulesBar: View {
    let selectedCount: Int
    let canSelectFilteredRules: Bool
    let isAllFilteredSelected: Bool
    let availableInputSources: [InputSource]
    @Binding var selection: String?
    let selectAllAction: () -> Void
    let applyAction: () -> Void
    let deleteAction: () -> Void
    let clearAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("已选择 \(selectedCount) 条")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                selectAllAction()
            } label: {
                Label(isAllFilteredSelected ? "已全选" : "全选", systemImage: "checklist")
            }
            .disabled(!canSelectFilteredRules || isAllFilteredSelected)

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
