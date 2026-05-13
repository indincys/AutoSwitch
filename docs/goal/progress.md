# Progress Snapshot

Last updated: 2026-05-13 06:01 +08

## Objective Audit

Goal: deliver a native Apple Silicon + macOS 26 AutoSwitch MVP that switches macOS input sources by active app and Spotlight-like panel rules, includes settings UI, launch-at-login, permission status, Sparkle update integration, a local release path, tests, README, and final proof.

Status: implemented and automatically verified where the current session can produce reliable evidence. Real foreground App switching has now been smoke-tested for Terminal and Finder. The goal is not marked complete because Spotlight show/hide, lock/wake, login-at-reboot, and true Sparkle update E2E still require manual desktop action and/or user-owned release credentials.

## Current Checkpoint

AutoSwitch is buildable, testable, launchable, and the reported settings-window sizing issue is fixed. The SwiftUI lifecycle no longer declares a placeholder `WindowGroup`; the hand-owned AppKit settings window now targets a deterministic user-visible `900x640` frame, derives content size from that frame, has an independent `760x520` minimum frame, fits within the visible display frame, disables restoration/tabbing side effects, uses a floating window level so the accessory app settings window is not hidden behind normal app windows, and restores an undersized reused settings window back to the default frame.

Foreground App switching is now verified in the logged-in GUI session. A bug found during smoke testing was fixed: AutoSwitch now ignores activation events from itself and non-content system UI bundle IDs, so the settings window cannot cancel a pending Terminal app-rule switch.

The release signing path is wired: an explicit non-sandbox entitlements file is part of the app target, and real release signing passes that entitlements file to `codesign`.

## Prompt-To-Artifact Checklist

- Xcode app project and source tree: present at `AutoSwitch.xcodeproj`, `AutoSwitch/`, and `AutoSwitchTests/`.
- Apple Silicon + macOS 26 only: `xcodebuild -showBuildSettings` confirms `ARCHS=arm64` and `MACOSX_DEPLOYMENT_TARGET=26.0`; built binary is thin `arm64`.
- Swift 6 native macOS app: app target build settings confirm `SWIFT_VERSION=6.0`; source uses SwiftUI/AppKit, Carbon, ApplicationServices, ServiceManagement, and Sparkle.
- Accessory app shape: built `Info.plist` has `LSUIElement=true`; source audit found no `NSStatusBar`, `statusItem`, or `MenuBarExtra` use.
- Input source layer: `InputSourceController` uses Carbon TIS APIs, enumerates enabled keyboard input sources, filters non-selectable sources, selects by source ID, and reads current source.
- Rule engine: `RuleEngineTests` cover app rule priority, global fallback, Spotlight panel priority, missing target fallback, and ASCII fallback.
- Config storage: `ConfigStoreTests` cover JSON round trip and corrupt config fallback; config path is `~/Library/Application Support/AutoSwitch/config.json`.
- App activation monitor: `AppActivationMonitor` listens to `NSWorkspace.didActivateApplicationNotification`.
- Same-app and non-content activation suppression: `FocusCoordinator` tracks the last regular activation bundle ID, ignores duplicate regular activations for that same bundle, and ignores activations from AutoSwitch itself, loginwindow, Dock, SystemUIServer, and Control Center so utility windows cannot override the real content app rule.
- Spotlight monitor: `SpotlightPanelMonitor` uses AX observers plus visible-window fallback for configured Spotlight-like bundle IDs.
- Switch debounce/correction: `SwitchScheduler` applies after 150 ms and performs one verification/correction at 500 ms total; `SwitchSchedulerTests` verify latest decision wins.
- Wake/session handling: `LockScreenMonitor` and `FocusCoordinatorTests.testWakeReconcilesFrontmostApp` cover the event path.
- Settings UI: `SettingsScene`, `GeneralTab`, `AppRulesTab`, `SpotlightTab`, and picker/components exist for global default, app rules, running apps, Spotlight apps, login item, permission status, document-switch reminder, and update check.
- Login item: `LoginItemManager` uses `SMAppService.mainApp`.
- Permissions: `PermissionsManager` uses Accessibility trust checks and system settings links.
- Sparkle integration: `UpdaterController` uses Sparkle `SPUStandardUpdaterController`; app `Info.plist` has `SUFeedURL`, `SUPublicEDKey`, and `SUEnableInstallerLauncherService`.
- Release workflow: `Scripts/release.sh` has explicit argument parsing, early missing-input checks, entitlements validation, appcast template validation, XML escaping for templated appcast fields, archives the app, builds Sparkle CLI tools, signs with `--entitlements`, zips, signs the update, writes `appcast.xml`, and optionally creates a GitHub release.
- Appcast template: present at `Scripts/appcast.template.xml`.
- README: present and covers build/run, first setup, behavior, updates, logs, and release.
- Codex run script: `script/build_and_run.sh` exists and `./script/build_and_run.sh --verify` passes.
- Guided manual smoke script: `Scripts/manual-smoke.sh` exists, is executable, passes `bash -n`, does not depend on non-system `rg`, and collects a Markdown smoke report under `Build/manual-smoke/` with config hashes, current input source, enabled input sources, visible windows, AutoSwitch PID, accessibility warning process, filtered AutoSwitch logs, and structured pass/fail/skip manual observations.
- Window sizing fix: `AppStateWindowSizingTests` cover default visible frame sizing, titlebar/content-size conversion, minimum sizing, centered default placement, and constrained visible-frame placement.

## Latest Verified Commands

- `xcodebuild -version`
  - Result: Xcode 26.3, build 17C529.
- `swift --version`
  - Result: Apple Swift 6.2.4, target `arm64-apple-macosx26.0`.
- `system_profiler SPHardwareDataType | grep 'Chip'`
  - Result: Apple M3 Max.
- `xcodebuild -project AutoSwitch.xcodeproj -scheme AutoSwitch -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData build`
  - Result: passed after adding `LSApplicationCategoryType`.
- `xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData`
  - Result: passed, 26 tests.
- `xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData -only-testing:AutoSwitchTests/AppStateWindowSizingTests`
  - Result: passed, 6 focused window-sizing tests.
- `xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData -only-testing:AutoSwitchTests/FocusCoordinatorTests`
  - Result: passed, 10 focused coordinator tests.
- `Scripts/release.sh --dry-run`
  - Result: passed after adding `LSApplicationCategoryType`; Release archive succeeded without the previous app-category warning, and Sparkle CLI schemes `generate_keys`, `sign_update`, and `generate_appcast` built.
- `./script/build_and_run.sh --verify`
  - Result: Debug build and process verification passed; runtime CGWindow inspection found exactly one visible AutoSwitch window at `900x640` on floating layer `3`.
- Foreground app smoke using real AutoSwitch process `93748`
  - Result: `osascript` activated Terminal, System Events reported `com.apple.Terminal`, and TIS current source was `com.apple.keylayout.ABC`; then Finder activation reported `com.apple.finder` and current source was `com.tencent.inputmethod.wetype.pinyin`.
- Idle CPU check after foreground smoke
  - Result: `top -l 3 -pid <AutoSwitch PID>` reported AutoSwitch at `0.0` to `0.1%` CPU while sleeping; repeated `ps` checks over 15 seconds reported `0.0%` CPU.
- `env -u ... Scripts/release.sh`
  - Result: failed early with `Missing required environment variable: AUTOSWITCH_SIGNING_IDENTITY`, as intended.
- `Scripts/release.sh --bogus`
  - Result: usage printed and exit code `2`, as intended.
- `bash -n Scripts/release.sh && Scripts/release.sh --help`
  - Result: passed.
- `bash -n Scripts/manual-smoke.sh && Scripts/manual-smoke.sh --help`
  - Result: passed; script documents `Scripts/manual-smoke.sh [--no-build]`.
- `printf '\n...skip...' | Scripts/manual-smoke.sh --no-build`
  - Result: generated `Build/manual-smoke/20260513-051404.md`; empty smoke correctly reports unchecked runtime events as `needs review` while proving report generation, input source capture, visible-window capture, config hash capture, log collection, and structured manual observation capture work. The generated dry-check report was deleted after verification.

## Build And Runtime Evidence

- Built Debug `Info.plist` contains `CFBundleIdentifier=dev.autoswitch.AutoSwitch`, `LSMinimumSystemVersion=26.0`, `LSUIElement=true`, `SUFeedURL`, `SUPublicEDKey`, and `SUEnableInstallerLauncherService=true`.
- Built Debug binary is a non-fat `arm64` Mach-O.
- Latest dry-run archive binary is a thin `arm64` Mach-O; archive `Info.plist` has `LSApplicationCategoryType=public.app-category.utilities`, `LSMinimumSystemVersion=26.0`, `LSUIElement=true`, `SUFeedURL`, `SUPublicEDKey`, and `SUEnableInstallerLauncherService=true`; Sparkle framework is embedded in the archived app.
- App target build settings confirm `ENABLE_APP_SANDBOX=NO` and `CODE_SIGN_ENTITLEMENTS=AutoSwitch/App/AutoSwitch.entitlements`.
- `AutoSwitch/App/AutoSwitch.entitlements` is an empty non-sandbox entitlements plist.
- Input source enumeration on this machine lists ABC plus Chinese sources including 微信输入法 and 豆包输入法.
- Current config persists at `~/Library/Application Support/AutoSwitch/config.json` and includes global 微信输入法 default, Terminal -> ABC rule, and Spotlight rule.
- Single-instance reopen path is logged: a second `open -n` signaled the existing process and reused the settings window.
- Temporary manual input source selection did not modify the config file hash in the previous runtime smoke.
- Real foreground smoke after filtering AutoSwitch self-activation: Terminal activation logged `reconcile focus (startup): com.apple.Terminal` and `scheduled switch to com.apple.keylayout.ABC because app rule`; AutoSwitch settings-window activation logged `ignoring non-content app activation: dev.autoswitch.AutoSwitch`; current input source after Terminal activation was `com.apple.keylayout.ABC`. Finder activation logged `app activation: com.apple.finder`, `scheduled switch to com.tencent.inputmethod.wetype.pinyin because global default`, `applied target com.tencent.inputmethod.wetype.pinyin`, and `verification matched target`; current input source after Finder activation was `com.tencent.inputmethod.wetype.pinyin`.
- Idle performance was rechecked after an initially misleading `ps` sample. `sample <AutoSwitch PID> 5` showed the app mostly blocked in the AppKit event loop with only timer samples in Spotlight visibility polling; follow-up `top`/`ps` checks showed stable idle CPU at `0.0` to `0.1%`.
- Settings-window runtime telemetry after the latest sizing fix: first launch logged `frame=(306.0, 188.0, 900.0, 640.0) contentLayout=(0.0, 0.0, 900.0, 588.0) contentViewSize=(900.0, 588.0)`; second launch reused the existing window and logged `frame=(612.0, 66.0, 900.0, 640.0) contentLayout=(0.0, 0.0, 900.0, 588.0) contentViewSize=(900.0, 588.0)`.
- Delayed CGWindow inspection after launch found exactly one visible AutoSwitch window with bounds `900x640` on layer `3`.
- Accessibility permission is authorized for the current app bundle in this session.
- Manual smoke report dry check captured enabled input sources: `com.apple.keylayout.ABC`, `com.tencent.inputmethod.wetype.pinyin`, and `com.bytedance.inputmethod.doubaoime.pinyin`.
- Manual smoke report dry check captured visible AutoSwitch, Terminal, Safari, TextEdit, Finder, Telegram, and other windows plus the `universalAccessAuthWarn` window.

## Completion Audit Against PLAN.md Section 8

- [x] 工程可构建并启动
  - Evidence: Debug build passed; `./script/build_and_run.sh --verify` passed.
- [x] App 以 accessory 形态运行，无 Dock 图标，无菜单栏常驻入口，首启显示设置窗
  - Evidence: `LSUIElement=true`, no menu bar API usage, runtime window telemetry logged.
- [x] 输入源枚举能显示 ABC 和本机至少一个中文输入源
  - Evidence: runtime enumeration found `com.apple.keylayout.ABC`, 微信输入法, and 豆包输入法.
- [x] 普通 App 规则按 Bundle ID 切换，临时手动切换不会写回配置
  - Evidence: Terminal/Finder real foreground smoke passed after filtering AutoSwitch self-activation; Terminal selected `com.apple.keylayout.ABC`, Finder selected global `com.tencent.inputmethod.wetype.pinyin`, and prior config hash stability verified temporary manual source selection did not write back.
- [x] 同一 Bundle ID 内部切换窗口不触发规则重判
  - Evidence: `FocusCoordinator` ignores duplicate regular activations for the same bundle; `FocusCoordinatorTests.testDuplicateAppActivationDoesNotRescheduleSameBundle` verifies no duplicate scheduling, and `testAppActivationReschedulesWhenBundleChangesBack` verifies switching to another bundle and back still schedules correctly. Real GUI smoke/log confirmation is still useful but no longer the only evidence for this requirement.
- [ ] Spotlight 类浮窗出现和关闭时按规则切换并恢复前台 App 规则
  - Evidence: `FocusCoordinatorTests` cover panel shown/hidden; real Spotlight show/hide smoke remains unconfirmed.
- [x] 防抖逻辑符合 150ms 首切和 500ms 校验补切，且不长期循环抢占
  - Evidence: `SwitchScheduler.swift`; `SwitchSchedulerTests.testSchedulerAppliesLatestDecision`; coordinator tests show verification logs.
- [ ] 锁屏、唤醒、登录后按当前前台 App 规则重切
  - Evidence: code and tests cover wake/session event path; real lock/unlock or wake smoke is not performed because it interrupts the desktop session.
- [x] 设置页覆盖全局默认、App 规则、运行中 App 添加、Spotlight App、开机自启、权限状态、文稿自动切换提醒和检查更新
  - Evidence: UI source files implement each section and controls; app launches settings window.
- [x] Sparkle 集成可构建，检查更新按钮可调用 updater
  - Evidence: Sparkle package resolves/builds; `UpdaterController` wires `SPUStandardUpdaterController`; Debug build passes.
- [ ] 发布脚本可在提供外部凭据后生成签名 zip 和 appcast
  - Evidence: dry-run passes; argument parsing rejects unknown flags; real path validates missing credentials, entitlements file, and appcast template early; real appcast generation now renders `Scripts/appcast.template.xml` with XML-escaped values. True signed zip/appcast E2E still requires user-owned certificate, Sparkle private key, repo/feed URL, and release permission.
- [x] README 覆盖安装、授权、配置、日志和发布流程
  - Evidence: README contains those sections.
- [x] 最终状态写入 `docs/goal/progress.md`
  - Evidence: this snapshot.

## Blocked Or Needs Manual Confirmation

- Spotlight show/hide smoke is not fully confirmed. Terminal-driven Spotlight automation attempts did not produce a visible Spotlight window or AutoSwitch Spotlight/coordinator/scheduler logs, so they are not counted as a real smoke pass.
- Real lock/unlock or wake testing is intentionally not performed automatically because it interrupts the user's desktop session.
- Login item reboot/login smoke remains manual even though `SMAppService` implementation exists.
- Real Sparkle update/release E2E requires user-owned inputs: GitHub repo/feed URL, Sparkle EdDSA private/public key, self-signed Code Signing certificate CN, and release permission/token.

## Next Step

Run `Scripts/manual-smoke.sh` in the logged-in GUI session and complete its prompts. Attach or summarize the generated `Build/manual-smoke/<timestamp>.md` report, then either provide release credentials for a true Sparkle E2E or accept the dry-run as the scoped release validation.
