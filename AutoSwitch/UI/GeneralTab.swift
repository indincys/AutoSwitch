import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var documentSwitchPreference: Bool?

    var body: some View {
        Form {
            Section("状态") {
                CurrentInputSourceRow()
                AccessibilityRow()
                LaunchAtLoginRow()
                if let error = appState.configStore.lastErrorMessage {
                    Label("配置错误：\(error)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if documentSwitchPreference == true {
                    Label("macOS 已开启“按文稿切换输入法”。建议在键盘设置中关闭，避免系统覆盖 AutoSwitch 的切换结果。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                InputSourcePicker(
                    sources: appState.inputSourceController.availableInputSources,
                    selection: Binding(
                        get: {
                            appState.configStore.config.globalDefaultInputSourceID
                                ?? appState.inputSourceController.availableInputSources.selectableForPicker().first?.id
                        },
                        set: { appState.configStore.setGlobalDefaultInputSourceID($0) }
                    ),
                    allowNone: false
                )
            } header: {
                Text("默认输入法")
            } footer: {
                Text("当前应用没有匹配规则时使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                AboutRow()
            }
        }
        .formStyle(.grouped)
        .task {
            documentSwitchPreference = DocumentSwitchChecker.currentPreference()
        }
    }
}

private struct CurrentInputSourceRow: View {
    @EnvironmentObject private var appState: AppState

    private var name: String {
        guard let id = appState.inputSourceController.currentInputSourceIDValue else {
            return "未知"
        }
        return appState.inputSourceController.inputSource(with: id)?.localizedName ?? id
    }

    var body: some View {
        LabeledContent("当前输入法") {
            Text(name).foregroundStyle(.secondary)
        }
    }
}

private struct AccessibilityRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack {
            Text("辅助功能权限")
            Spacer()
            if appState.permissionsManager.accessibilityAuthorized {
                StatusPill(title: "已授权", systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                StatusPill(title: "需要授权", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                Button("授权...") {
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
        Toggle("登录时启动", isOn: Binding(
            get: { appState.configStore.config.launchAtLogin },
            set: {
                appState.configStore.setLaunchAtLogin($0)
                appState.loginItemManager.setEnabled($0)
            }
        ))
        if appState.loginItemManager.status == .requiresApproval {
            Label("登录项需要在系统设置中批准。", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct AboutRow: View {
    @EnvironmentObject private var appState: AppState

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    var body: some View {
        LabeledContent("版本") {
            Text(version).foregroundStyle(.secondary)
        }
        HStack {
            Button("检查更新") {
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
            Label("此构建未配置更新。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
