# AutoSwitch — macOS 输入法自动切换工具 技术方案

## Context

需要从零构建一个仅供自用的 macOS 原生 App，按当前激活的应用（含 Raycast / Spotlight 类浮窗）自动切换 macOS 系统输入源，并在英文与所选中文输入法之间精准切换。运行环境锁定 Apple Silicon + macOS 26，不上架 App Store，走自签证书 + GitHub Release 分发，配 Sparkle 做应用内更新。

核心难点不在 UI，而在三件事：(1) 准确识别"前台 App 变化"和"Spotlight 类浮窗显隐"两类事件并去重；(2) 用 Carbon TIS API 稳定切换系统输入源、避开系统/App 抢占；(3) 自签证书 + GitHub Release + Sparkle 的分发链路要可重复、可验证。

---

## 技术选型结论

| 维度 | 选型 | 关键依据 |
|---|---|---|
| 语言 | Swift 6（启用 strict concurrency） | 原生最佳，配合 actor 隔离切换状态 |
| UI | SwiftUI（macOS 26）+ 少量 AppKit 桥接 | 设置页 SwiftUI 足够，系统监听需要 AppKit/Carbon |
| 工程结构 | Xcode `.xcodeproj` 单 target App | 自签 / entitlements / Sparkle 集成最顺 |
| 激活策略 | `.accessory`（`LSUIElement = YES`） | 无 Dock 无菜单栏；再次启动用单实例机制唤醒设置窗 |
| 输入源 API | `Carbon.HIToolbox` 的 TIS 系列 | 唯一可用的稳定 API（IMK 是写输入法用的，不是切换） |
| 前台 App 监听 | `NSWorkspace.didActivateApplicationNotification` | 仅在前台 App 变化时触发，符合规则要求 |
| 浮窗识别 | Accessibility（AX）全局观察 + 内置 Bundle ID 白名单 + 用户可扩展 | Raycast/hapiGO/Spotlight 等不一定走标准激活路径 |
| 防抖 | Swift Concurrency `Task` + 取消 | 150ms 主切换、500ms 校验补切 |
| 登录项 | `SMAppService.mainApp`（macOS 13+） | 现代 API，无需 LaunchAgent plist |
| 更新 | Sparkle 2.x（EdDSA 签名） | 自签场景下 EdDSA 比 Developer ID 更关键 |
| 配置存储 | Codable + JSON，路径 `~/Library/Application Support/AutoSwitch/config.json` | 易备份、易手工排查 |
| 日志 | `OSLog` + `Logger` | Console.app 直接可看，无第三方依赖 |
| 依赖管理 | Swift Package Manager（Xcode 内集成 Sparkle） | 不引入 CocoaPods |

### 签名 / 分发说明

- 用 Keychain Access > 证书助手创建 **Code Signing** 类型自签证书（不是 Developer ID）。
- Sparkle 2 强制要求 EdDSA 签名校验更新包，`generate_keys` 生成密钥对，私钥保留本地，公钥写入 Info.plist 的 `SUPublicEDKey`。
- 首次安装时 Gatekeeper 会拦：用户右键→打开 或 `xattr -dr com.apple.quarantine AutoSwitch.app` 解隔离。
- 之后 Sparkle 替换 App 时，签名身份一致，不会再触发 Gatekeeper。
- 不做 Notarization（前提是不考虑 Developer ID）。
- appcast.xml 托管在仓库 `gh-pages` 分支或直接用 `raw.githubusercontent.com`；Release 资产用 `.dmg` 或 `.zip` 二选一，`.zip` 更简单。

---

## 模块设计

```
AutoSwitch/
├── AutoSwitch.xcodeproj
└── AutoSwitch/
    ├── App/
    │   ├── AutoSwitchApp.swift          # SwiftUI App entry，注入 .accessory，挂依赖
    │   ├── AppDelegate.swift            # NSApplicationDelegate，承载长生命周期对象
    │   ├── SingleInstanceCoordinator.swift  # 二次启动→唤起设置窗（用 NSWorkspace 监听自身重复启动 + Distributed Notification）
    │   ├── Info.plist                   # LSUIElement=YES, SUFeedURL, SUPublicEDKey, LSMinimumSystemVersion=26.0
    │   └── AutoSwitch.entitlements      # 非沙盒；不需要 com.apple.security.app-sandbox
    │
    ├── InputSource/                     # 输入源抽象层
    │   ├── InputSource.swift            # struct（id/name/kind: ascii/chinese/other/system）
    │   ├── InputSourceController.swift  # TISCreateInputSourceList / TISSelectInputSource / TISCopyCurrentKeyboardInputSource
    │   └── InputSourceClassifier.swift  # 按 sourceID 和 languages 分类（ABC、中文、其它）
    │
    ├── Monitor/                         # 事件源
    │   ├── AppActivationMonitor.swift   # NSWorkspace.didActivateApplicationNotification
    │   ├── SpotlightPanelMonitor.swift  # AX observer，监听浮窗 App 的窗口创建/销毁
    │   ├── LockScreenMonitor.swift      # NSWorkspace.screensDid(Sleep|Wake)、sessionDid(Become|Resign)Active
    │   └── FocusEvent.swift             # enum，统一事件模型（appActivated / panelShown / panelHidden / wake）
    │
    ├── Engine/                          # 决策与执行
    │   ├── RuleEngine.swift             # 输入：bundleID + 浮窗状态 → 输出：目标 InputSource
    │   ├── SwitchScheduler.swift        # actor，封装 150ms+500ms 两阶段切换、取消旧任务
    │   └── FocusCoordinator.swift       # 总控：订阅 Monitor → 调 RuleEngine → 调 Scheduler
    │
    ├── Config/
    │   ├── Config.swift                 # Codable 根结构（globalDefault / appRules / spotlightApps / spotlightDefault）
    │   ├── AppRule.swift                # bundleID + inputSourceID
    │   ├── ConfigStore.swift            # 读写 JSON + 文件变更通知
    │   └── BuiltinSpotlightBundles.swift # com.apple.Spotlight / com.raycast.macos / com.lessons.hapigo / com.runningwithcrayons.Alfred 等
    │
    ├── System/                          # 系统能力
    │   ├── PermissionsManager.swift     # AXIsProcessTrustedWithOptions、状态查询、跳系统设置 Deep Link
    │   ├── LoginItemManager.swift       # SMAppService.mainApp.register/unregister/status
    │   ├── DocumentSwitchChecker.swift  # 读 com.apple.HIToolbox 的 AppleInputSourceSwitchOnDocument 等键，提醒用户
    │   └── SystemSettingsLinks.swift    # x-apple.systempreferences://... URL 集
    │
    ├── Update/
    │   └── UpdaterController.swift      # 包装 SPUStandardUpdaterController，绑定到设置页"检查更新"按钮
    │
    ├── UI/                              # 设置页 SwiftUI
    │   ├── SettingsScene.swift          # 顶层 Window + Tab 容器
    │   ├── GeneralTab.swift             # 全局默认输入法 / 开机自启 / 权限 / 更新 / 关闭"按文稿自动切换"提醒
    │   ├── AppRulesTab.swift            # 规则列表 + 增删改
    │   ├── RunningAppsPicker.swift      # 列 NSWorkspace.runningApplications 用于快速加规则
    │   ├── SpotlightTab.swift           # 浮窗 App 列表 + 默认输入法
    │   └── Components/                  # InputSourcePicker、StatusPill 等小组件
    │
    └── Resources/
        ├── Assets.xcassets
        └── appcast.template.xml         # 提交到 gh-pages 分支用的模板
```

---

## 关键设计点

### 1. 事件模型与触发时机

唯一事件来源汇总到 `FocusCoordinator`：

| 事件 | 来源 | 触发动作 |
|---|---|---|
| `appActivated(bundleID)` | NSWorkspace | RuleEngine 查规则 → Scheduler 切换 |
| `panelShown(bundleID)` | AX observer（白名单 App） | 用 spotlight 规则切换，记录 `inPanel=true` |
| `panelHidden(bundleID)` | AX observer | 重新读 `NSWorkspace.frontmostApplication`，按其规则切换 |
| `screenWoke` / `sessionActive` | NSWorkspace | 取当前前台 App，强制切一次 |

同一 Bundle ID 内部窗口变化不订阅 `AXFocusedWindowChangedNotification`，避免触发。

### 2. Spotlight 类浮窗识别

启动时为白名单里每个 Bundle ID（已安装的）拿到 `AXUIElement`（`AXUIElementCreateApplication(pid)`），订阅 `kAXWindowCreatedNotification` 和 `kAXUIElementDestroyedNotification`。这套做法不依赖该 App 是否走标准激活流程。

白名单内置：
- `com.apple.Spotlight`
- `com.raycast.macos`
- `com.lessons.hapigo`
- `com.runningwithcrayons.Alfred`
- `com.googlecode.iterm2`（如用户开 hotkey 窗口可加）

设置页提供「添加浮窗 App」入口，用户可加任意 Bundle ID。

### 3. 防抖与抢占容忍

`SwitchScheduler` 用一个 actor，内部持有「当前任务」`Task<Void, Never>?`：

```
schedule(target):
  cancel current task
  current = Task {
    try? await sleep(150ms)
    apply(target)
    try? await sleep(350ms)   // 总共到 500ms
    if current() != target { apply(target) }   // 仅校验一次，不循环
  }
```

新事件来时直接取消旧 Task，新一轮重新计时。

### 4. 输入源切换核心调用

```
TISCreateInputSourceList(nil, false)            // 仅当前已启用的
TISGetInputSourceProperty(src, kTISPropertyInputSourceID)
TISSelectInputSource(src)                        // 切换
TISCopyCurrentKeyboardInputSource()              // 校验
```

按 `kTISPropertyInputSourceCategory == kTISCategoryKeyboardInputSource` 过滤掉调色板/手写等非键盘源。

### 5. 单实例 + 设置窗唤起

`.accessory` 模式下二次启动机制：
- App 启动时尝试用 `NSDistributedNotificationCenter` 广播 `dev.autoswitch.openSettings`，若有响应说明已有实例 → 当前进程 `NSApp.terminate(nil)`。
- 已运行实例收到通知 → `NSApplication.shared.activate(ignoringOtherApps: true)` + 打开 SwiftUI 设置 Window。
- 备选方案：用 `NSRunningApplication` 枚举同 bundleID 进程数判定，作为 fallback。

### 6. 权限处理

- 启动时 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` 触发首次授权弹窗。
- 设置页 `GeneralTab` 实时显示授权状态（每秒轮询或监听 distributed notification），未授权时给一个按钮跳：`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`。
- 没有 AX 权限时，浮窗监听失效但 NSWorkspace 通知仍可用，按 graceful degrade 处理（UI 上明示）。

### 7. "按文稿自动切换输入源"提醒

读 `~/Library/Preferences/com.apple.HIToolbox.plist` 中 `AppleInputSourceSwitchOnDocument`（或 `AppleEnabledTextInputSources` 相关项），开关位置随 macOS 版本可能漂移，**实现时需在 macOS 26 上实地核对 key 名**——这是已知不确定点。若读不到就静默隐藏提醒，不弹错。

### 8. Sparkle 集成

- 通过 Xcode 「Add Package Dependency」加入 `https://github.com/sparkle-project/Sparkle`。
- Info.plist 配置：
  - `SUFeedURL`：指向 `https://raw.githubusercontent.com/<you>/<repo>/main/appcast.xml`
  - `SUPublicEDKey`：`sparkle-project/Sparkle/bin/generate_keys` 输出的公钥
  - `SUEnableInstallerLauncherService`：`YES`（自动更新需要）
- 发布流程脚本化（提交到 `Scripts/release.sh`）：
  1. `xcodebuild archive` → 导出 `.app`
  2. `codesign --deep --force --sign "<自签证书 CN>" AutoSwitch.app`
  3. 打 zip，`bin/sign_update AutoSwitch-x.y.z.zip` 生成 EdDSA 签名
  4. 更新 `appcast.xml`（手动或用 Sparkle 自带 `generate_appcast`）
  5. `gh release create vX.Y.Z AutoSwitch-x.y.z.zip --notes "..."`
  6. push appcast.xml 到 main 分支
- 设置页提供「检查更新」按钮，绑定 `SPUStandardUpdaterController.checkForUpdates(_:)`，默认提示更新不静默装。

---

## 已知不确定点 / 风险

1. **`AppleInputSourceSwitchOnDocument` 在 macOS 26 的实际 key 名** 需要装好系统后实测确认。
2. **Sparkle 在自签场景下的"代码签名身份校验"** 默认行为：Sparkle 会比较新旧 App 的 codesign 身份，若不一致拒绝更新——这正好保护我们，但要求每次发布都用同一张自签证书；证书过期前要规划续期或换发流程。
3. **某些 Spotlight 类 App（如 Raycast）的窗口可能是 panel 而非 window**，需要在 `kAXWindowCreatedNotification` 之外加 `kAXMainWindowChangedNotification` 兜底，开发期实测确认。
4. **macOS 26 是新系统**，`SMAppService`、AX 行为有细节变化的可能；优先用文档化 API，不依赖私有 SPI。

---

## 验证方式

End-to-end 验证清单，按顺序跑通即视为可发布：

1. **构建**：Xcode 选 My Mac，Debug 跑起来，确认无 Dock 图标、设置窗自动打开（首启）。
2. **权限**：首次提示授权 Accessibility，授权后设置页状态变绿。
3. **输入源枚举**：设置页能看到 ABC + 至少一个中文输入法，类型分类正确。
4. **基本切换**：设全局默认 = 中文；切换到 Safari → 输入法变中文；切换到 Terminal（配规则=英文）→ 输入法变英文。
5. **临时切换不写回**：在 Safari 手切英文，切走再切回 → 又变中文。
6. **Spotlight 浮窗**：在前台 App=Safari（中文）时按 `⌘空格` 唤 Spotlight，输入法切到 Spotlight 规则；关闭浮窗 → 重新切回中文。Raycast 重复同样测试。
7. **防抖**：快速 `⌘Tab` 来回切，无明显闪烁，Console 日志显示旧 Task 被取消。
8. **锁屏唤醒**：锁屏再解锁，输入法回到当前前台 App 的规则。
9. **登录项**：开启开机自启，重启 Mac，确认 App 已运行且无可见窗口。
10. **二次启动**：再次双击 App → 设置窗弹出而非启动新实例。
11. **更新流程**：本地 bump version 到 0.0.2，跑 `release.sh`，push appcast → 在 0.0.1 上点检查更新 → 看到提示 → 下载 → 替换 → 启动 0.0.2。
12. **Console 日志**：`log show --predicate 'subsystem == "dev.autoswitch"' --last 5m` 能看到事件流。

UI 验证用浏览器 / 终端 / Raycast / Spotlight 真实操作，不依赖单元测试。核心 actor（`SwitchScheduler`、`RuleEngine`）写少量单测覆盖去重和优先级逻辑即可。

---

## 关键文件待创建

- `AutoSwitch.xcodeproj`（Xcode 新建 macOS App）
- `AutoSwitch/App/AutoSwitchApp.swift`
- `AutoSwitch/App/AppDelegate.swift`
- `AutoSwitch/InputSource/InputSourceController.swift`
- `AutoSwitch/Monitor/AppActivationMonitor.swift`
- `AutoSwitch/Monitor/SpotlightPanelMonitor.swift`
- `AutoSwitch/Engine/FocusCoordinator.swift`
- `AutoSwitch/Engine/SwitchScheduler.swift`
- `AutoSwitch/Engine/RuleEngine.swift`
- `AutoSwitch/Config/Config.swift` + `ConfigStore.swift`
- `AutoSwitch/System/PermissionsManager.swift` + `LoginItemManager.swift`
- `AutoSwitch/Update/UpdaterController.swift`
- `AutoSwitch/UI/SettingsScene.swift` + 各 Tab
- `Scripts/release.sh`
- `appcast.xml`
- `Info.plist`、`AutoSwitch.entitlements`

仓库根放 `.gitignore`（忽略 `xcuserdata/`、`.build/`、`DerivedData/`）和 `README.md`（仅文档，本次不主动写）。
