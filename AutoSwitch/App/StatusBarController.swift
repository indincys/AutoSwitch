import AppKit
import Foundation
import os.log

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let logger = Logger(subsystem: "dev.autoswitch", category: "status-bar")
    private weak var appState: AppState?

    private var statusItem: NSStatusItem?
    private var didStart = false

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        installStatusItem()
    }

    func stop() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
        didStart = false
    }

    func updateVisibility() {
        guard let appState else { return }
        let shouldShow = appState.configStore.config.showMenuBarIcon
        if shouldShow {
            if statusItem == nil { installStatusItem() }
        } else {
            stop()
            didStart = true // keep didStart so re-enabling via toggle calls installStatusItem
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "AutoSwitch")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "AutoSwitch"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let appState else { return }
        buildCurrentAppSection(into: menu, appState: appState)
        menu.addItem(.separator())
        buildSettingsSection(into: menu, appState: appState)
        menu.addItem(.separator())
        buildFeatureTogglesSection(into: menu, appState: appState)
        menu.addItem(.separator())
        buildSystemSection(into: menu, appState: appState)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 AutoSwitch", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildCurrentAppSection(into menu: NSMenu, appState: AppState) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let bundleID = frontmost?.bundleIdentifier
        let displayName = frontmost?.localizedName ?? bundleID ?? "未知"

        guard
            let frontmost,
            let bundleID,
            !FrontmostApplicationResolver.shouldIgnore(bundleID: bundleID)
        else {
            let item = NSMenuItem(title: "当前应用不可识别", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let header = NSMenuItem(title: "当前应用：\(displayName)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let bundleItem = NSMenuItem(title: "  \(bundleID)", action: nil, keyEquivalent: "")
        bundleItem.isEnabled = false
        menu.addItem(bundleItem)

        let existingRule = appState.configStore.config.appRules.first { $0.bundleID == bundleID }

        let setItem = NSMenuItem(
            title: existingRule == nil ? "为「\(displayName)」添加规则…" : "修改「\(displayName)」的规则…",
            action: nil,
            keyEquivalent: ""
        )
        let submenu = NSMenu()
        let sources = appState.inputSourceController.availableInputSources.selectableForPicker()
        if sources.isEmpty {
            let empty = NSMenuItem(title: "无可用输入法", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for source in sources {
                let item = NSMenuItem(
                    title: source.localizedName,
                    action: #selector(setRuleForFrontmostApp(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = SetRuleAction(
                    bundleID: bundleID,
                    displayName: displayName,
                    inputSourceID: source.id,
                    lastSeenPath: frontmost.bundleURL?.path
                )
                if existingRule?.inputSourceID == source.id {
                    item.state = .on
                }
                submenu.addItem(item)
            }
        }
        setItem.submenu = submenu
        menu.addItem(setItem)

        if existingRule != nil {
            let remove = NSMenuItem(
                title: "移除「\(displayName)」的规则",
                action: #selector(removeRuleForFrontmostApp(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            remove.representedObject = bundleID
            menu.addItem(remove)
        }
    }

    private func buildSettingsSection(into menu: NSMenu, appState: AppState) {
        let open = NSMenuItem(title: "打开 AutoSwitch 设置…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
    }

    private func buildFeatureTogglesSection(into menu: NSMenu, appState: AppState) {
        let promptItem = NSMenuItem(title: "检测 shell 提示符自动切英文", action: #selector(toggleShellPromptDetection(_:)), keyEquivalent: "")
        promptItem.target = self
        promptItem.state = appState.configStore.config.shellPromptDetectionEnabled ? .on : .off
        menu.addItem(promptItem)

        let slashItem = NSMenuItem(title: "输入 / 时自动切英文", action: #selector(toggleSlashTrigger(_:)), keyEquivalent: "")
        slashItem.target = self
        slashItem.state = appState.configStore.config.slashTriggerEnabled ? .on : .off
        menu.addItem(slashItem)
    }

    private func buildSystemSection(into menu: NSMenu, appState: AppState) {
        let launchItem = NSMenuItem(title: "登录时启动", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = appState.configStore.config.launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        let updaterItem = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updaterItem.target = self
        updaterItem.isEnabled = appState.updaterController.canCheckForUpdates
        menu.addItem(updaterItem)
    }

    // MARK: - Actions

    @objc private func setRuleForFrontmostApp(_ sender: NSMenuItem) {
        guard let data = sender.representedObject as? SetRuleAction, let appState else { return }
        appState.configStore.upsertAppRule(
            bundleID: data.bundleID,
            displayName: data.displayName,
            inputSourceID: data.inputSourceID,
            enabled: true,
            lastSeenPath: data.lastSeenPath
        )
        logger.info("status-bar: upserted rule for \(data.bundleID, privacy: .public) → \(data.inputSourceID, privacy: .public)")
    }

    @objc private func removeRuleForFrontmostApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String, let appState else { return }
        appState.configStore.removeAppRule(bundleID: bundleID)
        logger.info("status-bar: removed rule for \(bundleID, privacy: .public)")
    }

    @objc private func openSettings(_ sender: Any?) {
        appState?.showSettingsWindow()
    }

    @objc private func toggleShellPromptDetection(_ sender: Any?) {
        guard let appState else { return }
        let new = !appState.configStore.config.shellPromptDetectionEnabled
        appState.configStore.setShellPromptDetectionEnabled(new)
    }

    @objc private func toggleSlashTrigger(_ sender: Any?) {
        guard let appState else { return }
        let new = !appState.configStore.config.slashTriggerEnabled
        appState.configStore.setSlashTriggerEnabled(new)
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        guard let appState else { return }
        let new = !appState.configStore.config.launchAtLogin
        appState.configStore.setLaunchAtLogin(new)
        appState.loginItemManager.setEnabled(new)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        appState?.updaterController.checkForUpdates()
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

private struct SetRuleAction {
    let bundleID: String
    let displayName: String
    let inputSourceID: String
    let lastSeenPath: String?
}
