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

            Section {
                ShellPromptDetectionRow()
            } header: {
                Text("终端识别")
            } footer: {
                Text("仅在常见终端类应用中识别命令提示符,例如 user@host path %、~/repo $、➜ repo。Codex/Claude 的 TUI 输入提示不会被当作 shell prompt。停止匹配时回退到 app 规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SlashTriggerRow()
            } header: {
                Text("/ 键触发")
            } footer: {
                Text("任何 app 中输入「/」时临时切到英文,直到下一次输入空格、Tab 或回车,自动还原为之前的输入法。适用于 Claude Code / Codex CLI 的 slash 命令。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TransientEnglishRow()
                TransientEnglishIdleRow()
            } header: {
                Text("Shift 切换系统输入源")
            } footer: {
                Text("关闭输入法自带 Shift 中英切换后,单独按 Shift 会在当前中文输入法和 ABC 之间切换。无任何键盘活动达到设定秒数会自动切回之前的中文输入法;Shift+字母或快捷键不会触发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                MenuBarIconRow()
            } header: {
                Text("菜单栏")
            } footer: {
                Text("菜单栏图标用于快速给当前应用添加规则、切换功能开关、退出 app。")
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

private struct ShellPromptDetectionRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("检测 shell 提示符自动切英文", isOn: Binding(
            get: { appState.configStore.config.shellPromptDetectionEnabled },
            set: { appState.configStore.setShellPromptDetectionEnabled($0) }
        ))
    }
}

private struct SlashTriggerRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("输入「/」时自动切英文,遇空格/Tab/回车恢复", isOn: Binding(
            get: { appState.configStore.config.slashTriggerEnabled },
            set: { appState.configStore.setSlashTriggerEnabled($0) }
        ))
    }
}

private struct TransientEnglishRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Toggle("启用 Shift 切换 ABC/中文输入法", isOn: Binding(
            get: { appState.configStore.config.transientEnglishEnabled },
            set: { appState.configStore.setTransientEnglishEnabled($0) }
        ))
    }
}

private struct TransientEnglishIdleRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let seconds = appState.configStore.config.transientEnglishIdleSeconds
        HStack {
            Text("无活动秒数后切回")
            Spacer()
            Stepper(value: Binding(
                get: { seconds },
                set: { appState.configStore.setTransientEnglishIdleSeconds($0) }
            ), in: 3...120, step: 1) {
                Text("\(seconds) 秒")
                    .monospacedDigit()
                    .frame(minWidth: 50, alignment: .trailing)
            }
        }
        .disabled(!appState.configStore.config.transientEnglishEnabled)
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
