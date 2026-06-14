import AppKit
import SwiftUI

// MARK: - Liquid Glass palette

private func lgHex(_ v: UInt) -> Color {
    Color(.sRGB,
          red: Double((v >> 16) & 0xff) / 255,
          green: Double((v >> 8) & 0xff) / 255,
          blue: Double(v & 0xff) / 255,
          opacity: 1)
}

private enum LG {
    static let accent = lgHex(0x0A84FF)
    static let okGreen = lgHex(0x1C7A3E)
    static let switchOff = Color(.sRGB, red: 120/255, green: 120/255, blue: 128/255, opacity: 0.30)
    static let hairline = Color.primary.opacity(0.08)
}

// MARK: - General tab

struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var documentSwitchPreference: Bool?

    var body: some View {
        GeometryReader { geometry in
                let compact = geometry.size.width < 560

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {

                        // 默认输入法
                        LGGroupLabel("默认输入法")
                        LGCard {
                            LGRow(
                                title: "没有应用规则时使用",
                                sub: "切到没有专属规则的应用时，回落到这个输入法"
                            ) {
                                DefaultInputSourceDropdown()
                            }
                            LGRow(title: "辅助功能权限", last: true) {
                                AccessibilityControl()
                            }
                        }

                        if let error = appState.configStore.lastErrorMessage {
                            LGNotice(text: "配置错误：\(error)")
                        }

                        // 自动切换规则
                        LGGroupLabel("自动切换规则", hint: "仅影响自动切换 · 不覆盖手动选择")
                        LGCard {
                            LGRow(
                                title: "终端中自动切到英文",
                                sub: "检测到终端提示符时强制使用英文"
                            ) {
                                LGSwitch(isOn: Binding(
                                    get: { appState.configStore.config.shellPromptDetectionEnabled },
                                    set: { appState.configStore.setShellPromptDetectionEnabled($0) }
                                ))
                            }
                            LGRow(
                                title: "输入「/」时临时切到英文",
                                sub: "空格、Tab 或回车后自动恢复"
                            ) {
                                LGSwitch(isOn: Binding(
                                    get: { appState.configStore.config.slashTriggerEnabled },
                                    set: { appState.configStore.setSlashTriggerEnabled($0) }
                                ))
                            }
                            LGRow(
                                title: "用 Shift 临时切换中英",
                                sub: "在 ABC 与中文输入法之间快速切换"
                            ) {
                                LGSwitch(isOn: Binding(
                                    get: { appState.configStore.config.transientEnglishEnabled },
                                    set: { appState.configStore.setTransientEnglishEnabled($0) }
                                ))
                            }
                            LGRow(
                                title: "无活动后自动恢复",
                                sub: "临时切换后，停顿这么久就切回默认",
                                last: true
                            ) {
                                LGStepper(
                                    value: appState.configStore.config.transientEnglishIdleSeconds,
                                    unit: "秒",
                                    range: 3...120,
                                    onChange: { appState.configStore.setTransientEnglishIdleSeconds($0) }
                                )
                                .opacity(appState.configStore.config.transientEnglishEnabled ? 1 : 0.4)
                                .disabled(!appState.configStore.config.transientEnglishEnabled)
                            }
                        }

                        if documentSwitchPreference == true {
                            LGNotice(text: "macOS 已开启\u{201C}按文稿切换输入法\u{201D}。建议在键盘设置中关闭，避免系统覆盖 AutoSwitch 的切换结果。")
                        }

                        // 菜单栏与更新
                        LGGroupLabel("菜单栏与更新")
                        LGCard {
                            LGRow(
                                title: "显示菜单栏图标",
                                sub: "可在菜单栏快速给当前应用添加规则"
                            ) {
                                LGSwitch(isOn: Binding(
                                    get: { appState.configStore.config.showMenuBarIcon },
                                    set: { appState.configStore.setShowMenuBarIcon($0) }
                                ))
                            }
                            LGRow(
                                title: "登录时启动",
                                sub: "开机自动在后台运行"
                            ) {
                                LGSwitch(isOn: Binding(
                                    get: { appState.configStore.config.launchAtLogin },
                                    set: {
                                        appState.configStore.setLaunchAtLogin($0)
                                        appState.loginItemManager.setEnabled($0)
                                    }
                                ))
                            }
                            UpdateRow()
                        }

                        if appState.loginItemManager.status == .requiresApproval {
                            LGNotice(text: "登录项需要在系统设置中批准。")
                        }

                        // 系统光标提示
                        LGGroupLabel("系统光标提示")
                        LGCard {
                            SystemTextCursorRow()
                        }
                    }
                    .padding(.horizontal, compact ? 16 : 26)
                    .padding(.vertical, compact ? 18 : 24)
                    .frame(maxWidth: 760, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollContentBackground(.hidden)
            }
        .task {
            documentSwitchPreference = DocumentSwitchChecker.currentPreference()
        }
    }
}

// MARK: - Group label (outside the card)

private struct LGGroupLabel: View {
    let title: String
    var hint: String?

    init(_ title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Glass card container

private struct LGCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .padding(.bottom, 26)
    }
}

// MARK: - Row

private struct LGRow<Trailing: View>: View {
    let title: String
    var sub: String?
    var last: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                if let sub {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            if !last {
                Rectangle()
                    .fill(LG.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Inline notice (replaces big info panel)

private struct LGNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 26)
            .offset(y: -18)
    }
}

// MARK: - iOS-style switch

private struct LGSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Capsule()
                .fill(isOn ? LG.accent : LG.switchOff)
                .frame(width: 44, height: 26)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.28), radius: 1, x: 0, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isOn)
    }
}

// MARK: - Compact stepper

private struct LGStepper: View {
    let value: Int
    let unit: String
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(value) \(unit)")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()

            VStack(spacing: 0) {
                stepButton(systemName: "chevron.up") {
                    if value < range.upperBound { onChange(value + 1) }
                }
                Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 0.5)
                stepButton(systemName: "chevron.down") {
                    if value > range.lowerBound { onChange(value - 1) }
                }
            }
            .frame(width: 30)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
        }
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .frame(width: 30, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Glass dropdown

private struct DefaultInputSourceDropdown: View {
    @EnvironmentObject private var appState: AppState

    private var options: [InputSourceOption] {
        InputSourceOptions.make(from: appState.inputSourceController.availableInputSources)
    }

    private var selectionID: String? {
        appState.configStore.config.globalDefaultInputSourceID
            ?? options.first?.id
    }

    var body: some View {
        let opts = options
        let current = selectionID
        Menu {
            ForEach(opts) { option in
                Button {
                    appState.configStore.setGlobalDefaultInputSourceID(option.id)
                } label: {
                    if option.id == current {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(InputSourceOptions.label(for: current, options: opts))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 9)
            .padding(.vertical, 7)
            .frame(width: 170, alignment: .leading)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: - Accessibility control

private struct AccessibilityControl: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.permissionsManager.accessibilityAuthorized {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                Text("已授权")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(LG.okGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(lgHex(0x30D158).opacity(0.16), in: Capsule())
        } else {
            LGButton(title: "授权...", accent: true) {
                appState.permissionsManager.requestAccessibilityAccess()
                appState.permissionsManager.openAccessibilitySettings()
            }
        }
    }
}

// MARK: - Update row

private struct UpdateRow: View {
    @EnvironmentObject private var appState: AppState

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    var body: some View {
        LGRow(
            title: "软件更新",
            sub: "当前版本 \(version) · \(appState.updaterController.lastCheckMessage)",
            last: true
        ) {
            LGButton(title: "检查更新") {
                appState.updaterController.checkForUpdates()
            }
            .disabled(!appState.updaterController.canCheckForUpdates)
        }
    }
}

// MARK: - Glass button

private struct LGButton: View {
    let title: String
    var systemImage: String?
    var accent: Bool = false
    var danger: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(accent ? AnyShapeStyle(.white) : (danger ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary)))
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                if accent {
                    Capsule(style: .continuous).fill(LG.accent)
                } else {
                    Capsule(style: .continuous).fill(Color.primary.opacity(0.05))
                }
            }
            .overlay {
                if !accent {
                    Capsule(style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - System text cursor row

private struct SystemTextCursorRow: View {
    @State private var copiedDisable = false
    @State private var copiedRestore = false

    private let disableCmd = "sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool NO"
    private let restoreCmd = "sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool YES"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("关闭或恢复光标旁输入法气泡")
                    .font(.system(size: 14, weight: .medium))
                Text("关闭的是光标旁气泡；菜单栏输入法图标仍会显示。因命令需要 sudo，应用不会替你静默执行。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                LGButton(title: copiedDisable ? "已复制" : "复制关闭命令",
                         systemImage: copiedDisable ? "checkmark" : "doc.on.doc") {
                    copy(disableCmd)
                    copiedDisable = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedDisable = false }
                }
                LGButton(title: copiedRestore ? "已复制" : "复制恢复命令",
                         systemImage: copiedRestore ? "checkmark" : "arrow.counterclockwise") {
                    copy(restoreCmd)
                    copiedRestore = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedRestore = false }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
