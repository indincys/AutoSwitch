# Goal: 实现 AutoSwitch macOS 输入法自动切换 App MVP

## /goal Command

`/goal Implement GOAL.md without stopping until the AutoSwitch MVP builds successfully, the listed validations pass, and docs/goal/progress.md records the final proof.`

## Objective

从空仓库实现一个仅支持 Apple Silicon + macOS 26 的原生 macOS App：根据当前前台 App 或 Spotlight 类浮窗规则，在 macOS 系统输入源之间自动切换，提供设置页、开机自启、权限状态、Sparkle 检查更新和本地发布脚本。

## Stopping Condition

Codex should stop only when:

- `AutoSwitch.xcodeproj` 和源码已创建，Debug build 在 Apple Silicon macOS 26 目标上通过。
- `PLAN.md` 中 MVP 功能已实现或有明确的、不可绕过的外部阻塞项。
- 普通 App 规则、Spotlight 类浮窗规则、防抖补切、锁屏/唤醒重切、配置持久化和设置页都完成对应验证。
- Sparkle 更新集成能构建；发布脚本能在用户提供证书和 GitHub 信息后生成 release 资产，或在缺少外部凭据时按 Pause rules 暂停而不是假装完成。
- `docs/goal/progress.md` 已更新为最终短快照，记录最后验证命令、手动 smoke test 结果、已知风险和后续动作。

## Read First

- `AGENTS.md` - durable repository guidance and document roles.
- `macos-floating-teacup.md` - 用户提供的技术选型和模块设计原稿的仓库内副本。
- `PLAN.md` - 稳定产品技术规格；实现时以它为功能、约束、数据模型和验收依据。
- `docs/goal/progress.md` - 当前 `/goal` 运行的短进度快照；每个重要 checkpoint 后重写。

## Project Instructions

- `AGENTS.md` status: created at repository root as durable project navigation for `/goal` and future resumed runs.
- In resumed or compacted runs, read `AGENTS.md`, `PLAN.md`, `GOAL.md`, and `docs/goal/progress.md`, then inspect the actual filesystem before deciding what remains.
- 如果执行过程中发现需要长期保留的仓库级规则，只添加最小 `AGENTS.md` 更新，不要把 checkpoint、实时进度或一次性状态写入其中。
- 保留用户提供的产品决策：不做菜单栏常驻、不走 App Store、不做 notarization、不支持 Intel、不处理第三方输入法内部中英文模式。

## Initial Baseline

- Workspace: `/Users/indincys/Documents/Code/autoswitch`
- Snapshot before goal artifacts were created: 工作区尚无 Xcode 工程、实现源码或 Git 仓库初始化记录；只有用户提供的技术方案作为输入。
- Do not treat this section as live state after implementation begins. For resumed or compacted runs, inspect the actual filesystem and read `docs/goal/progress.md` before deciding what remains.
- 用户已提供完整产品方案和技术方案，核心不确定项集中在 macOS 26 上的文稿自动切换 preference key、AX panel 事件细节、Sparkle 发布外部凭据。

## Desired End State

- 一个可本地构建、可后台运行、可通过设置窗配置的 `AutoSwitch.app`。
- App 能枚举当前已启用输入源，并按全局、App、Spotlight 类 App 规则切换系统输入源。
- 普通 App 仅在前台 Bundle ID 变化时触发；Spotlight 类浮窗出现和关闭时触发；同一 App 内焦点变化不触发。
- 设置完成后 App 可后台运行并支持开机自启。
- Sparkle 检查更新和本地 release 流程已集成到可验证状态。

## Scope

- 创建 Xcode macOS App 工程、Swift 源码、资源、entitlements、Info.plist、测试 target 和必要脚本。
- 实现 InputSource、Monitor、Engine、Config、System、Update、UI 模块。
- 添加 focused unit tests，至少覆盖 `RuleEngine`、`SwitchScheduler` 和配置读写/迁移中的纯逻辑。
- 添加 `Scripts/release.sh` 或等价发布脚本、`appcast` 模板和 README。
- 更新 `PLAN.md` 和 `docs/goal/progress.md`，必要时小幅调整 `GOAL.md` 以反映真实实现约束。

## Non-Goals

- 不支持 Intel Mac 或 macOS 26 以下系统。
- 不做 App Store、Developer ID notarization、账号系统、云同步或远程配置。
- 不处理第三方输入法内部中英文模式。
- 不按浏览器地址栏、网页、文本框、窗口标题或文档类型切换。
- 不实现菜单栏常驻入口。
- 不使用私有 SPI。
- 不为了抢占输入法做长期循环切换。

## Constraints

- 使用 Swift 6 strict concurrency；共享可变状态优先 actor 或主线程隔离。
- 使用 Carbon TIS API 切换 macOS 系统输入源；只枚举当前已启用键盘输入源。
- 普通 App 事件来自 `NSWorkspace.didActivateApplicationNotification`。
- Spotlight 类浮窗识别来自 Accessibility AX observer + Bundle ID 白名单/用户扩展。
- 防抖策略固定为 150ms 首切和 500ms 校验补切一次。
- 配置文件路径固定为 `~/Library/Application Support/AutoSwitch/config.json`，必须能处理缺失、损坏和旧 schema。
- Sparkle 私钥、签名证书和 GitHub token 不得写入仓库。
- Release 脚本必须清晰提示缺失的外部输入，不得静默使用错误签名身份。

## Checkpoints

1. Project scaffold and baseline build
   - Expected result: `AutoSwitch.xcodeproj`、单 app target、test target、Info.plist、entitlements、目录结构和空设置窗可构建运行。
   - Validation: `xcodebuild -project AutoSwitch.xcodeproj -scheme AutoSwitch -configuration Debug -destination 'platform=macOS,arch=arm64' build`
2. Input source layer
   - Expected result: 能枚举、分类、定位、选择和校验系统输入源；非键盘源被过滤。
   - Validation: focused unit tests where possible + 设置页/日志手动检查 ABC 和中文输入源。
3. Config and rule engine
   - Expected result: JSON 配置读写、迁移/损坏恢复、全局/App/Spotlight 规则优先级完成。
   - Validation: `xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch -destination 'platform=macOS,arch=arm64'`
4. Monitoring and switch scheduling
   - Expected result: 普通 App activation、Spotlight panel shown/hidden、wake/session active 事件进入 `FocusCoordinator`；`SwitchScheduler` 正确取消旧任务并补切一次。
   - Validation: unit tests for scheduler/rule decisions + Console 日志手动检查事件流。
5. Settings UI and system controls
   - Expected result: 设置页覆盖全局默认输入法、App 规则、运行中 App 添加、Spotlight App、开机自启、权限状态、文稿自动切换提醒和更新按钮。
   - Validation: 手动 UI smoke test；必要时截图或把检查结果写入 `docs/goal/progress.md`。
6. Sparkle and release path
   - Expected result: Sparkle 2.x 集成、Info.plist keys 可配置、检查更新按钮可调用 updater、发布脚本和 appcast 模板存在。
   - Validation: build 通过；`Scripts/release.sh --dry-run` 或等价检查通过；如果外部凭据可用，完成一次真实 update smoke test。
7. End-to-end manual smoke test
   - Expected result: 按 `PLAN.md` 验收清单完成普通 App、Spotlight、唤醒、登录项、二次启动、日志等验证。
   - Validation: 将手动结果汇总到 `docs/goal/progress.md`。
8. Documentation and final proof
   - Expected result: README、发布说明、进度快照和最终报告完整。
   - Validation: final build/test commands pass；进度快照记录 residual risks and next step。

## Validation and Proof

- Baseline discovery:
  - `xcodebuild -version`
  - `swift --version`
  - `system_profiler SPHardwareDataType | grep 'Chip'`
- Build:
  - `xcodebuild -project AutoSwitch.xcodeproj -scheme AutoSwitch -configuration Debug -destination 'platform=macOS,arch=arm64' build`
- Tests:
  - `xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch -destination 'platform=macOS,arch=arm64'`
- Release checks:
  - `Scripts/release.sh --dry-run` or documented equivalent.
  - If credentials and remote repo are available: run real release/update smoke test.
- Runtime/manual:
  - Verify no Dock icon and no menu bar status item.
  - Verify input source list contains ABC and at least one configured Chinese input source.
  - Verify Safari/global and Terminal/App-specific switching.
  - Verify temporary manual switch is not written back.
  - Verify Spotlight panel show/hide behavior.
  - Verify lock/wake/session active re-switch.
  - Verify login item toggle.
  - Verify second launch opens settings window instead of leaving a second instance running.
  - Verify logs with `log show --predicate 'subsystem == "dev.autoswitch"' --last 5m`.

## Progress Snapshot

Maintain `docs/goal/progress.md` as a compact current-state snapshot. Rewrite it after each meaningful checkpoint; do not append a full history.

## Run Control

- Inspect status with `/goal`.
- Use `/goal pause` when a listed pause condition occurs or when user-owned credentials/hardware/permissions are needed.
- Use `/goal resume` after the missing input is provided or the user chooses a scoped fallback.
- Use `/goal clear` only after the goal is complete, abandoned, or replaced by a materially different objective.

## Pause or Ask

Pause before:

- Choosing a different product shape, such as adding a menu bar item, supporting Intel, supporting older macOS, or using Developer ID/notarization.
- Replacing the selected technology stack with a non-native UI, private API, LaunchAgent-based login item, or non-Sparkle update mechanism.
- Performing destructive filesystem or Git operations.
- Claiming Sparkle update E2E complete without a GitHub repo/feed URL, Sparkle private key, public key, self-signed certificate CN, and release permission.
- Continuing if macOS 26 behavior invalidates AX panel detection or TIS input source switching.
- Continuing after a failing build/test that cannot be narrowed within the current implementation scope.

Continue with labeled assumptions when:

- App display names, icons, or running-app metadata are unavailable; use Bundle ID and update later.
- A third-party Spotlight-like App is not installed locally; validate Spotlight and keep the third-party path configurable.
- The macOS document auto-switch preference key cannot be confirmed; hide the reminder and record the risk.
- GitHub release credentials are missing before final packaging; implement dry-run and pause before E2E release validation.

## Deliverables

- Xcode project and source files for `AutoSwitch.app`.
- Focused tests for rule decisions, scheduler behavior and config handling.
- `Scripts/release.sh` or equivalent release workflow plus appcast template.
- README with install, permissions, configuration, logging and release instructions.
- Updated `PLAN.md` if implementation reality changes accepted scope.
- Updated `docs/goal/progress.md` with final proof.
- Final report listing completed checkpoints, validation commands/results, manual smoke tests, known risks and follow-ups.

