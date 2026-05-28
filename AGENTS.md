# AGENTS.md

## Repository Context

AutoSwitch is a self-use native macOS app for Apple Silicon and macOS 26 that switches the macOS system input source based on the active app. It runs as an accessory app (no Dock icon, no menu bar item); opening the app shows the settings window, and opening it again signals the existing instance to bring that window back.

## Layout

- `AutoSwitch/App/` — entry point, `AppState`, single-instance coordinator, `Info.plist`, entitlements.
- `AutoSwitch/Config/` — config schema, persistence, builtin Spotlight bundle IDs.
- `AutoSwitch/Engine/` — `RuleEngine`, `FocusCoordinator`, `SwitchScheduler` (debounce + verify).
- `AutoSwitch/InputSource/` — Carbon TIS wrapper and classifier.
- `AutoSwitch/Monitor/` — `NSWorkspace`, lock screen, and Spotlight-panel AX observers.
- `AutoSwitch/System/` — login item, permissions, document-switch checker, system settings deep links.
- `AutoSwitch/UI/` — SwiftUI settings scene and components.
- `AutoSwitch/Update/` — Sparkle controller.
- `AutoSwitch/Resources/Assets.xcassets/` — app icon and global assets.
- `AutoSwitchTests/` — XCTest unit tests.
- `Scripts/` — `release.sh`, `manual-smoke.sh`, appcast template.
- `script/build_and_run.sh` — local build/run helper (`run`, `--debug`, `--logs`, `--telemetry`, `--verify`).
- `generate_project.rb` — regenerates `AutoSwitch.xcodeproj` via `xcodeproj` gem.

## Build And Run

```bash
./script/build_and_run.sh           # build Debug as "AutoSwitchDEV" / display name "AutoSwitch DEV" and launch
./script/build_and_run.sh --verify  # build DEV, launch, confirm process is alive
xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData
```

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
- Target: Apple Silicon, macOS 26.
- Do not add Intel support, App Store distribution, Developer ID notarization, menu bar residency, cloud sync, telemetry, or third-party IME internal mode handling unless scope is explicitly expanded.
- Do not store Sparkle private keys, signing certificates, or GitHub tokens in the repository.
- Settings window must not be always-on-top. It is a normal window the user can move behind other apps.
- Config persists at `~/Library/Application Support/AutoSwitch/config.json`; on parse failure, back up as `config.corrupt.<timestamp>.json` and start from defaults.
- Development/test builds must use a distinct app name containing `DEV` instead of the production `AutoSwitch` name, so macOS Accessibility can keep production and test builds authorized separately. Keep release builds named `AutoSwitch`. When testing a development build, the expected workflow is to quit the production app from the background and run the DEV build, without repeatedly deleting or re-authorizing Accessibility entries.

## Logs

```bash
log show --info --style compact --predicate 'subsystem == "dev.autoswitch"' --last 5m
```

Categories: `app`, `app-state`, `input-source`, `coordinator`, `scheduler`, `spotlight-monitor`, `single-instance`.
