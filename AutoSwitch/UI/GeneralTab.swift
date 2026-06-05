import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var documentSwitchPreference: Bool?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 560

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsPageHeader(
                        title: "通用设置",
                        subtitle: "设置默认输入法和全局开关。",
                        systemImage: "switch.2"
                    )

                    SettingsGroup(
                        title: "状态与权限",
                        systemImage: "checkmark.shield"
                    ) {
                        CurrentInputSourceRow()
                        AccessibilityRow()
                        LaunchAtLoginRow()

                        if let error = appState.configStore.lastErrorMessage {
                            InlineNotice(
                                text: "配置错误：\(error)",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .orange
                            )
                        }

                        if documentSwitchPreference == true {
                            InlineNotice(
                                text: "macOS 已开启“按文稿切换输入法”。建议在键盘设置中关闭，避免系统覆盖 AutoSwitch 的切换结果。",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .orange
                            )
                        }
                    }

                    SettingsGroup(
                        title: "默认输入法",
                        systemImage: "keyboard",
                        footer: "没有应用规则时使用。"
                    ) {
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
                        .labelsHidden()
                    }

                    SettingsGroup(
                        title: "自动触发",
                        systemImage: "bolt.horizontal",
                        footer: "只影响自动切换，不会覆盖你手动选择的输入法。"
                    ) {
                        ShellPromptDetectionRow()
                        SlashTriggerRow()
                        TransientEnglishRow()
                        TransientEnglishIdleRow()
                    }

                    SettingsGroup(
                        title: "菜单栏与更新",
                        systemImage: "menubar.rectangle",
                        footer: "菜单栏图标可快速添加当前应用规则。"
                    ) {
                        MenuBarIconRow()
                        AboutRow()
                    }
                }
                .padding(.horizontal, compact ? 16 : 24)
                .padding(.vertical, compact ? 16 : 22)
                .frame(maxWidth: 760, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .task {
            documentSwitchPreference = DocumentSwitchChecker.currentPreference()
        }
    }
}

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let systemImage: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 11) {
                content()
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 0.5)
        }
    }
}

private struct InlineNotice: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Text("辅助功能权限")
                Spacer(minLength: 12)
                authorizationControl
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("辅助功能权限")
                authorizationControl
            }
        }
    }

    @ViewBuilder
    private var authorizationControl: some View {
        if appState.permissionsManager.accessibilityAuthorized {
            StatusPill(title: "已授权", systemImage: "checkmark.circle.fill", tint: .green)
        } else {
            HStack(spacing: 8) {
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

private struct ShellPromptDetectionRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("在终端提示符处自动切到英文", isOn: Binding(
            get: { appState.configStore.config.shellPromptDetectionEnabled },
            set: { appState.configStore.setShellPromptDetectionEnabled($0) }
        ))
    }
}

private struct SlashTriggerRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("输入「/」时临时切到英文，空格/Tab/回车后恢复", isOn: Binding(
            get: { appState.configStore.config.slashTriggerEnabled },
            set: { appState.configStore.setSlashTriggerEnabled($0) }
        ))
    }
}

private struct TransientEnglishRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("用 Shift 在 ABC 和中文输入法之间临时切换", isOn: Binding(
            get: { appState.configStore.config.transientEnglishEnabled },
            set: { appState.configStore.setTransientEnglishEnabled($0) }
        ))
    }
}

private struct TransientEnglishIdleRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let seconds = appState.configStore.config.transientEnglishIdleSeconds
        ViewThatFits(in: .horizontal) {
            HStack {
                Text("无活动后恢复")
                Spacer(minLength: 12)
                idleStepper(seconds: seconds)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("无活动后恢复")
                idleStepper(seconds: seconds)
            }
        }
        .disabled(!appState.configStore.config.transientEnglishEnabled)
    }

    private func idleStepper(seconds: Int) -> some View {
        Stepper(value: Binding(
            get: { seconds },
            set: { appState.configStore.setTransientEnglishIdleSeconds($0) }
        ), in: 3...120, step: 1) {
            Text("\(seconds) 秒")
                .monospacedDigit()
                .frame(minWidth: 50, alignment: .trailing)
        }
    }
}

private struct MenuBarIconRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("显示菜单栏图标", isOn: Binding(
            get: { appState.configStore.config.showMenuBarIcon },
            set: { appState.configStore.setShowMenuBarIcon($0) }
        ))
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

        ViewThatFits(in: .horizontal) {
            HStack {
                updateButton
                Spacer(minLength: 12)
                updateMessage
            }

            VStack(alignment: .leading, spacing: 6) {
                updateButton
                updateMessage
            }
        }

        if !appState.updaterController.isConfiguredForRelease {
            Label("此构建未配置更新。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var updateButton: some View {
        Button("检查更新") {
            appState.updaterController.checkForUpdates()
        }
        .disabled(!appState.updaterController.canCheckForUpdates)
    }

    private var updateMessage: some View {
        Text(appState.updaterController.lastCheckMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
