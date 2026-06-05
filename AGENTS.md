# AGENTS.md

## Repository Context

AutoSwitch is a self-use native macOS app for Apple Silicon and macOS 15+ that switches the macOS system input source based on the active app. It runs as an accessory app (no Dock icon, no menu bar item); opening the app shows the settings window, and opening it again signals the existing instance to bring that window back.

## Layout

- `AutoSwitch/App/` — entry point, `AppState`, single-instance coordinator, `Info.plist`, entitlements.
- `AutoSwitch/Config/` — config schema, persistence, builtin Spotlight bundle IDs.
- `AutoSwitch/Engine/` — `RuleEngine`, `FocusCoordinator`, `SwitchScheduler` (debounce + verify).
- `AutoSwitch/InputSource/` — Carbon TIS wrapper and classifier.
- `AutoSwitch/Monitor/` — `NSWorkspace`, lock screen, and Spotlight-panel AX observers; `KeyboardEventHub` (the single shared keystroke tap) and `AXTextReader` (AX-tree text extraction).
- `AutoSwitch/System/` — login item, permissions, document-switch checker, system settings deep links.
- `AutoSwitch/UI/` — SwiftUI settings scene and components.
- `AutoSwitch/Update/` — Sparkle controller.
- `AutoSwitch/Resources/Assets.xcassets/` — app icon and global assets.
- `AutoSwitchTests/` — XCTest unit tests.
- `Scripts/` — `release.sh`, `manual-smoke.sh`, appcast template.
- `script/build_and_run.sh` — local build/run helper (`run`, `--debug`, `--logs`, `--telemetry`, `--verify`).
- `generate_project.rb` — regenerates `AutoSwitch.xcodeproj` via `xcodeproj` gem.

## Architecture

Event-driven pipeline: signals from `Monitor/` reach `FocusCoordinator`, which
asks `RuleEngine` for a `SwitchDecision` that `SwitchScheduler` applies through
`InputSourceController` (Carbon TIS).

- `FocusCoordinator` is the single funnel for all context signals and holds the
  shell/TUI detection state.
- `RuleEngine` is a pure function. Priority: TUI prompt → shell prompt → Spotlight
  rule → app rule → global default (with ascii/system/first fallbacks). TUI input
  boxes force Chinese; shell prompts force English.
- `SwitchScheduler` debounces ~150 ms, then verifies/corrects once (~500 ms
  total); it skips when already on target and coalesces duplicate pending targets,
  so it never fights a manual switch.
- `InputSourceController` updates its cached current source synchronously on our
  own `selectInputSource`, so the TIS-changed notification path can tell a
  user-initiated switch (Shift / Ctrl-Space / menu) apart and fire
  `onUserInitiatedChange` (this drives transient English). `InputSourceClassifier`
  is the only classifier.
- Event sources: `AppActivationMonitor` (NSWorkspace), `SpotlightPanelMonitor`
  (per-app AX observers + CGWindow visibility poll), `LockScreenMonitor` (wake),
  and `FocusedElementMonitor` (terminal text via `AXTextReader` +
  `ShellPromptDetector` regexes).
- All keystroke-driven features subscribe to one `KeyboardEventHub` tap (wired in
  `AppState`): `SlashTriggerMonitor` and `TransientEnglishMonitor`.

`AppState` is the `@MainActor` singleton that constructs and wires every
subsystem, owns the settings window, and forwards child `ObservableObject`
changes to SwiftUI. The app is single-instance (flock + a
`DistributedNotificationCenter` "open settings" signal).

Slash trigger / IME (subtle — read before touching `SlashTriggerMonitor`):
line-start cannot be tracked by counting keystrokes under a CJK IME (pinyin emits
many keyDowns per committed character, and backspace deletes whole characters).
`CaretContextProbe` reads the real caret/text via Accessibility instead — enabling
`AXManualAccessibility` once per pid for Electron apps (Claude/Codex Desktop) that
expose no focused element. Terminals report an unreliable AX caret, so prompt
bundles fall back to a keystroke flag re-armed on Enter / app switch / backspace;
that re-arm is driven only by real app activation, never by rule decisions.

## Build And Run

```bash
./script/build_and_run.sh           # build Debug as "AutoSwitchDEV" / display name "AutoSwitch DEV" and launch
./script/build_and_run.sh --verify  # build DEV, launch, confirm process is alive
xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData

# A single class or method (append /testMethodName to narrow further):
xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData \
  -only-testing:AutoSwitchTests/SlashAndTransientMonitorTests
```

The Xcode project is generated, not hand-maintained: adding/removing/renaming a
source or test file means editing the `app_files` / `test_files` arrays in
`generate_project.rb` and re-running it — never hand-edit `project.pbxproj`.

To regenerate the Xcode project after touching `generate_project.rb`:

```bash
ruby generate_project.rb
```

## Release

```bash
Scripts/release.sh --dry-run   # validate environment / build chain
Scripts/release.sh             # full release
```

Required env vars: `AUTOSWITCH_SIGNING_IDENTITY`, `AUTOSWITCH_REPO`, `AUTOSWITCH_RELEASE_TAG`, `AUTOSWITCH_RELEASE_NOTES_URL`, `AUTOSWITCH_FEED_URL`. Optional: `AUTOSWITCH_ED_PRIVATE_KEY` (otherwise Sparkle reads its key from the macOS Keychain). The script archives, signs, zips, signs the zip with EdDSA, writes `appcast.xml`, and uses `gh release create` when available.

## Durable Constraints

- Swift 6, SwiftUI/AppKit, Carbon TIS, AX observers, `SMAppService`, Sparkle 2.x via SwiftPM.
- All keystroke-driven features (slash trigger, transient English, shell-prompt burst) share the single `KeyboardEventHub` listen-only `CGEventTap`. Do not add new per-feature taps — register a handler on the hub instead. Input-source classification has a single source of truth in `InputSourceClassifier`; do not re-implement it.
- Target: Apple Silicon, macOS 15+ (deployment floor `15.0`; the same single build runs unchanged through macOS 26+). The floor is set by `SMAppService` (macOS 13); 15 is the chosen, tested baseline. Keep this in sync with `LSMinimumSystemVersion` (Info.plist) and `MACOSX_DEPLOYMENT_TARGET` (generate_project.rb). Do not introduce `#available`/`@available` branches without expanding scope.
- Do not add Intel support, App Store distribution, Developer ID notarization, menu bar residency, cloud sync, telemetry, or third-party IME internal mode handling unless scope is explicitly expanded.
- Do not store Sparkle private keys, signing certificates, or GitHub tokens in the repository.
- Settings window must not be always-on-top. It is a normal window the user can move behind other apps.
- Config persists at `~/Library/Application Support/AutoSwitch/config.json`; on parse failure, back up as `config.corrupt.<timestamp>.json` and start from defaults.
- Development/test builds must use a distinct app name containing `DEV` instead of the production `AutoSwitch` name, so macOS Accessibility can keep production and test builds authorized separately. Keep release builds named `AutoSwitch`. When testing a development build, the expected workflow is to quit the production app from the background and run the DEV build, without repeatedly deleting or re-authorizing Accessibility entries.

## Logs

```bash
log show --info --style compact --predicate 'subsystem == "dev.autoswitch"' --last 5m
```

Categories: `app`, `app-state`, `config`, `coordinator`, `scheduler`, `input-source`, `keyboard-hub`, `slash-trigger`, `transient-english`, `focused-element`, `caret-probe`, `spotlight-monitor`, `single-instance`, `status-bar`.
