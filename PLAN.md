# PLAN.md: AutoSwitch macOS 输入法自动切换工具

## 1. 技术栈与约束 / Tech Stack & Constraints

| Layer | Choice | Constraint / Rationale |
| --- | --- | --- |
| Product | AutoSwitch | 自用 macOS 原生 App，按当前激活 App 自动切换 macOS 系统输入源。 |
| Platform | Apple Silicon only, macOS 26.x | Deployment target `macOS 26.0`；只构建 `arm64`，不做 Intel / Universal。 |
| Language | Swift 6, strict concurrency | 用 actor 隔离切换调度状态；避免长期共享可变状态。 |
| UI | SwiftUI + 少量 AppKit bridge | 设置页用 SwiftUI；生命周期、窗口、AX、NSWorkspace、Sparkle 需要 AppKit 桥接。 |
| Project | Xcode `.xcodeproj`, single app target | 便于配置 entitlements、Info.plist、Sparkle、签名和本地运行。 |
| App shape | `.accessory`, `LSUIElement = YES` | 不显示 Dock 图标，不做菜单栏常驻入口；二次启动唤起设置窗。 |
| Input source API | `Carbon.HIToolbox` TIS APIs | 使用系统输入源切换 API；不处理第三方输入法内部中英文模式。 |
| App activation | `NSWorkspace.didActivateApplicationNotification` | 普通 App 只在前台 Bundle ID 变化时触发。 |
| Spotlight panel detection | Accessibility AX observer + built-in/user Bundle ID list | Raycast / hapiGO / Spotlight 类浮窗不完全依赖普通 App 激活逻辑。 |
| Login item | `SMAppService.mainApp` | macOS 13+ 现代登录项 API，不写 LaunchAgent plist。 |
| Updates | Sparkle 2.x, EdDSA update signing | GitHub Release 分发；默认提示更新，不静默安装。 |
| Config storage | Codable JSON at `~/Library/Application Support/AutoSwitch/config.json` | 易备份、易排障；配置仅保存在本地。 |
| Logging | `OSLog` / `Logger`, subsystem `dev.autoswitch` | Console.app 可直接查看事件、切换、防抖和错误。 |
| Dependencies | Swift Package Manager only | Sparkle 通过 Xcode SPM 集成；不引入 CocoaPods。 |
| Signing | Local self-signed Code Signing certificate | 不走 App Store，不做 notarization；每次发布必须使用同一签名身份，证书名由用户提供。 |
| Distribution | GitHub Release + appcast | 仓库 URL、`SUFeedURL`、Sparkle private key path 由用户提供或在发布阶段暂停确认。 |

默认产品标识假设：

- Product name: `AutoSwitch`
- Bundle ID: `dev.autoswitch.AutoSwitch`
- Distributed notification: `dev.autoswitch.openSettings`
- Logging subsystem: `dev.autoswitch`

如果用户后续给出不同 Bundle ID 或 GitHub 仓库地址，开发时应替换这些占位值。

## 2. 功能模块清单 / Feature List

- F-001: Xcode 工程与 App 生命周期
  - Priority: MVP
  - Behavior: 创建 macOS App 工程，使用 SwiftUI App entry + AppDelegate 承载长期对象；首启打开设置窗；二次启动唤起已有实例设置窗。
  - Acceptance: Debug build 可在 My Mac 启动；无 Dock 图标；重复双击不会产生第二个长期运行实例。

- F-002: 输入源枚举、分类与切换
  - Priority: MVP
  - Behavior: 探测当前已启用的 macOS 键盘输入源，包括 ABC、系统输入法和第三方中文输入法；按 `ascii` / `chinese` / `other` / `system` 分类；按 source ID 切换系统输入源。
  - Acceptance: 设置页能列出 ABC 和至少一个中文输入源；规则保存的 source ID 可被 TIS API 重新定位；切换后可读取当前输入源验证。

- F-003: 配置存储
  - Priority: MVP
  - Behavior: 保存全局默认输入法、每 App 默认输入法、Spotlight 类 App 列表与独立默认输入法、开机自启偏好和 UI 需要的显示元数据。
  - Acceptance: 重启 App 后配置保持；损坏配置不会导致 App 崩溃。

- F-004: RuleEngine
  - Priority: MVP
  - Behavior: 按 Bundle ID 查找 App 规则；未配置 App 使用全局默认输入法；Spotlight 类浮窗按其独立默认输入法，未配置时回退全局默认。
  - Acceptance: 单元测试覆盖全局默认、App 规则优先级、Spotlight 规则优先级、缺失输入源回退。

- F-005: 普通 App 前台变化监听
  - Priority: MVP
  - Behavior: 仅在前台 App Bundle ID 变化时触发切换；同一 Bundle ID 内部窗口和焦点变化默认不触发。
  - Acceptance: Safari 和 Terminal 之间切换会触发；同一 App 内换窗口不会触发。

- F-006: Spotlight 类浮窗监听
  - Priority: MVP
  - Behavior: 对内置和用户标记的浮窗 App 建立 AX observer；浮窗出现时切到该浮窗 App 规则；浮窗关闭后重新读取当前 frontmost application 并按其规则切换。
  - Acceptance: Spotlight 和至少一个第三方浮窗 App（如 Raycast，如果本机安装）通过手动 smoke test；无 AX 权限时普通 App 规则仍可工作并在 UI 中明确降级状态。

- F-007: 切换防抖与补切
  - Priority: MVP
  - Behavior: App 或浮窗事件到达后取消旧任务，延迟 150ms 切换一次；总计 500ms 后校验当前输入源，若不是目标则只补切一次；不做长期循环抢占。
  - Acceptance: 快速 `Cmd-Tab` 时不会排队执行过期切换；日志显示旧任务取消和最多一次补切。

- F-008: 锁屏、唤醒、登录后重切
  - Priority: MVP
  - Behavior: 监听 wake/session active 等事件，按当前前台 App 规则重新切一次。
  - Acceptance: 锁屏后解锁，输入法回到当前前台 App 配置。

- F-009: 设置页
  - Priority: MVP
  - Behavior: 提供全局默认输入法选择、App 规则列表、当前运行 App 探测列表、Spotlight 类 App 管理、开机自启开关、权限状态、关闭“按文稿自动切换输入源”提醒、检查更新按钮。
  - Acceptance: 所有 MVP 设置可读写并反馈状态；不使用菜单栏入口。

- F-010: 权限与系统状态
  - Priority: MVP
  - Behavior: 显示 Accessibility 权限状态并提供跳转；显示登录项状态；检测 macOS “按文稿自动切换输入源”设置，能确定开启时提醒用户关闭。
  - Acceptance: 权限未授予时 UI 明确说明；授权后状态更新；无法确认文稿自动切换 key 时静默隐藏该提醒。

- F-011: Sparkle 更新集成
  - Priority: MVP
  - Behavior: 集成 Sparkle updater；启动时可检查更新；设置页有“检查更新”按钮；默认提示用户确认安装，不静默替换。
  - Acceptance: 本地 build 能链接 Sparkle；`SUFeedURL` 和 `SUPublicEDKey` 可配置；在可用 GitHub Release 和 EdDSA 签名资产时通过一次更新 smoke test。

- F-012: 发布脚本与 appcast
  - Priority: MVP
  - Behavior: 提供 `Scripts/release.sh` 或等价脚本，完成 archive、codesign、zip、Sparkle signing、appcast 更新和 GitHub Release 资产发布步骤。
  - Acceptance: 在用户提供签名证书 CN、Sparkle private key、GitHub repo 后可生成可发布资产；缺少外部凭据时脚本清晰失败并提示所需环境变量。

- F-013: README 与运维说明
  - Priority: MVP
  - Behavior: 说明安装、首次打开 Gatekeeper 处理、辅助功能权限、关闭文稿自动切换、开机自启、更新发布流程和本地日志查看。
  - Acceptance: 用户可按 README 完成首次安装、授权、配置规则和发布新版本。

## 3. UI/UX / UI&UXRequirements

- Information architecture:
  - 单一设置窗口，不做菜单栏常驻入口。
  - 顶层可用 tab 或 sidebar 分区：`General`、`App Rules`、`Spotlight`、`Updates` 或等价结构。

- General:
  - 全局默认输入法 picker。
  - 开机自启 toggle。
  - Accessibility 权限状态和跳转按钮。
  - “按文稿自动切换输入源”提醒，仅在能确认开启时显示。
  - “检查更新”按钮和当前版本信息。

- App Rules:
  - 展示已配置规则：App 名称、Bundle ID、目标输入源、启用状态、删除按钮。
  - 展示当前正在运行的 App 探测列表，支持一键添加规则。
  - 规则按 Bundle ID 存储；显示名称和图标仅作为 UI 元数据。

- Spotlight:
  - 展示内置浮窗 App 和用户添加的浮窗 App。
  - 每个浮窗 App 可设置独立默认输入法；为空时使用全局默认。
  - 支持从正在运行 App 中添加，也支持手动输入 Bundle ID。
  - 显示 AX 权限缺失导致浮窗监听不可用的降级说明。

- Updates:
  - 可并入 General。
  - 显示当前版本、feed URL 配置状态、最后检查结果和“检查更新”按钮。
  - 不提供静默安装开关。

- States:
  - Empty: 无 App 规则时显示可从运行中 App 添加的空状态。
  - Permission denied: 普通 App 切换可用，Spotlight 类浮窗监听不可用。
  - Missing input source: 规则引用的 source ID 不存在时显示警告并提供重选。
  - Update unavailable: Sparkle 正常提示“已是最新”或错误信息。
  - Config error: 配置损坏时提示已备份损坏文件并恢复默认配置。

- macOS interaction constraints:
  - 不为浏览器地址栏做特殊英文规则。
  - 不在同一 App 内焦点变化时重判。
  - 多显示器场景仍以当前激活 App 为准。

## 4. 数据模型 / Data Model

- `InputSource`
  - Fields: `id`, `localizedName`, `category`, `languages`, `kind`
  - Kind: `ascii`, `chinese`, `other`, `system`
  - Storage: 运行时枚举；规则只持久化 `id`，显示名可缓存用于 UI。

- `Config`
  - Fields: `schemaVersion`, `globalDefaultInputSourceID`, `appRules`, `spotlightRules`, `spotlightBundleIDs`, `launchAtLogin`, `createdAt`, `updatedAt`
  - Storage: `~/Library/Application Support/AutoSwitch/config.json`
  - Migration: `schemaVersion` 向前兼容；未知字段忽略；破损文件备份为 `config.corrupt.<timestamp>.json` 后恢复默认。

- `AppRule`
  - Fields: `bundleID`, `displayName`, `inputSourceID`, `enabled`, `lastSeenPath`
  - Relationship: 按 `bundleID` 匹配普通 App。

- `SpotlightRule`
  - Fields: `bundleID`, `displayName`, `inputSourceID`, `enabled`, `isBuiltin`
  - Relationship: 匹配 AX observer 识别到的浮窗 App；`inputSourceID == nil` 时回退全局默认。

- `FocusEvent`
  - Cases: `appActivated(bundleID)`, `panelShown(bundleID)`, `panelHidden(bundleID)`, `screenWoke`, `sessionActive`
  - Storage: 不持久化；用于 monitor 到 coordinator 的内部事件流。

- `SwitchDecision`
  - Fields: `targetInputSourceID`, `reason`, `sourceBundleID`, `isPanelContext`
  - Storage: 不持久化；可写入 OSLog。

## 5. 非功能要求 / Non-functional

- Performance:
  - App 常驻后台时 CPU 接近空闲；普通状态不轮询前台 App。
  - AX 权限状态可低频轮询或在设置页激活时刷新，避免常态高频轮询。
  - 快速切换事件通过 `SwitchScheduler` 取消旧任务，避免堆积。

- Reliability:
  - TIS 切换失败应记录日志并在 500ms 校验阶段最多补切一次。
  - 输入源消失时不要崩溃，回退到全局默认；全局默认也不存在时提示用户重新选择。
  - 无 AX 权限时 Spotlight 类规则降级，不影响普通 App 规则。

- Privacy/security:
  - 不采集输入内容，不读取文本字段内容。
  - 不联网，除 Sparkle 检查 GitHub appcast 外无远程通信。
  - 本地配置不包含敏感输入内容；发布私钥不写入仓库。

- Offline behavior:
  - 除检查更新外完全离线可用。

- Logging/observability:
  - 使用 `Logger(subsystem: "dev.autoswitch", category: ...)`。
  - 记录事件来源、目标输入源 ID、切换结果、补切、配置错误、权限降级，不记录用户输入内容。

- Packaging/release:
  - Release 资产优先 `.zip`。
  - `Scripts/release.sh` 必须显式要求签名证书 CN、Sparkle private key、GitHub repo 等输入。
  - 不做 App Store、Developer ID notarization 或静默安装。

- Maintainability:
  - 核心逻辑拆成 InputSource、Monitor、Engine、Config、System、Update、UI 模块。
  - `RuleEngine` 和 `SwitchScheduler` 需要可单元测试；AX/TIS 相关调用通过小接口封装以便局部替换或 mock。

## 6. 范围外 / Out of Scope

- 不支持 Intel Mac 或 macOS 26 以下系统。
- 不上架 App Store。
- 不做 Developer ID notarization。
- 不处理微信输入法、搜狗输入法、豆包输入法等第三方输入法内部中英文模式。
- 不按浏览器地址栏、网页、文本框、窗口标题或文档类型做特殊规则。
- 不做菜单栏常驻入口。
- 不做云同步、账号系统、遥测分析或远程配置。
- 不做长期循环抢占输入法。
- 不使用私有 SPI。

## 7. 错误处理 / Error Handling

- Accessibility permission denied:
  - User-facing behavior: 设置页显示未授权，普通 App 规则可用，Spotlight 类浮窗规则不可用。
  - Retry/fallback: 用户点击跳转系统设置授权后刷新状态。
  - Pause condition: 如果 macOS 26 上 AX observer API 行为变化导致无法实现浮窗显隐监听，需要暂停并记录替代方案。

- Target input source missing:
  - User-facing behavior: 对应规则显示警告，要求重新选择输入法。
  - Retry/fallback: 普通 App 规则回退全局默认；全局默认缺失时回退 ABC（若可用）并提示用户。
  - Pause condition: 如果 TIS API 在 macOS 26 上无法枚举已启用输入源，需要暂停。

- TIS select failure:
  - User-facing behavior: 不弹频繁错误；设置页可显示最近错误。
  - Retry/fallback: 500ms 校验时最多补切一次。
  - Pause condition: 如果同一输入源持续切换失败且不是权限或输入源缺失导致，需要暂停并保留日志。

- Config read/write failure:
  - User-facing behavior: 提示配置不可写或已恢复默认配置。
  - Retry/fallback: 损坏配置备份后恢复默认；写入失败时保留内存配置并提示路径。
  - Pause condition: 如果用户目录权限异常导致无法持久化配置，需要暂停。

- Document auto-switch preference unknown:
  - User-facing behavior: 读不到 macOS 26 实际 key 时静默隐藏提醒。
  - Retry/fallback: 在目标系统实机确认 key 后补充实现。
  - Pause condition: 不阻塞 MVP，除非用户要求该提醒必须准确。

- Sparkle feed/signing missing:
  - User-facing behavior: 更新页显示 feed 或公钥未配置，检查更新按钮禁用或提示配置缺失。
  - Retry/fallback: 开发期使用占位配置；发布前由用户提供 GitHub repo、feed URL、Sparkle public/private key 和证书 CN。
  - Pause condition: 做最终更新 E2E 验收前，如果缺少外部凭据或仓库权限，必须暂停询问。

## 8. 验收清单 / Acceptance Checklist

- [ ] 工程可构建并启动
  - Validation: `xcodebuild -project AutoSwitch.xcodeproj -scheme AutoSwitch -configuration Debug -destination 'platform=macOS,arch=arm64' build`

- [ ] App 以 accessory 形态运行，无 Dock 图标，无菜单栏常驻入口，首启显示设置窗
  - Validation: 手动启动检查，并记录结果到 `docs/goal/progress.md`

- [ ] 输入源枚举能显示 ABC 和本机至少一个中文输入源
  - Validation: 设置页手动检查；必要时用 Console 日志核对 TIS source IDs

- [ ] 普通 App 规则按 Bundle ID 切换，临时手动切换不会写回配置
  - Validation: Safari / Terminal 或用户本机可用 App 的手动 smoke test

- [ ] 同一 Bundle ID 内部切换窗口不触发规则重判
  - Validation: 手动 smoke test + 日志检查

- [ ] Spotlight 类浮窗出现和关闭时按规则切换并恢复前台 App 规则
  - Validation: Spotlight 必测；Raycast / hapiGO / Alfred 按本机安装情况测试

- [ ] 防抖逻辑符合 150ms 首切和 500ms 校验补切，且不长期循环抢占
  - Validation: `RuleEngine` / `SwitchScheduler` 单元测试 + Console 日志手动检查

- [ ] 锁屏、唤醒、登录后按当前前台 App 规则重切
  - Validation: 手动 smoke test

- [ ] 设置页覆盖全局默认、App 规则、运行中 App 添加、Spotlight App、开机自启、权限状态、文稿自动切换提醒和检查更新
  - Validation: 手动 UI smoke test

- [ ] Sparkle 集成可构建，检查更新按钮可调用 updater
  - Validation: build 通过；有可用 appcast 时完成一次更新 smoke test

- [ ] 发布脚本可在提供外部凭据后生成签名 zip 和 appcast
  - Validation: `Scripts/release.sh --dry-run` 或等价检查；最终发布前执行真实 release

- [ ] README 覆盖安装、授权、配置、日志和发布流程
  - Validation: 人工阅读检查

- [ ] 最终状态写入 `docs/goal/progress.md`
  - Validation: 进度快照列出已完成 checkpoint、最后验证命令、残余风险和下一步
