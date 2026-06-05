# AutoSwitch

Native macOS input source switcher for Apple Silicon and macOS 15 or later.

AutoSwitch runs as an accessory app: no Dock icon and no menu bar item. Opening the app shows the settings window; opening it again signals the existing instance and reopens that window.

## Build And Run

```bash
./script/build_and_run.sh
```

Other useful commands:

```bash
./script/build_and_run.sh --verify
xcodebuild test -project AutoSwitch.xcodeproj -scheme AutoSwitch -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData
```

Guided manual smoke test:

```bash
Scripts/manual-smoke.sh
```

This starts AutoSwitch, prompts you through the foreground app, Spotlight, wake,
login item, and config-persistence checks, then writes a Markdown report under
`Build/manual-smoke/`. The report includes collected logs plus pass/fail/skip
answers for the manual observations.

## First Setup

1. Open AutoSwitch.
2. If Gatekeeper blocks a downloaded build, right-click AutoSwitch.app and choose Open. For a quarantined self-use build, `xattr -dr com.apple.quarantine AutoSwitch.app` also clears the quarantine flag.
3. Grant Accessibility permission when prompted, or use Settings > General > Open Settings.
4. Disable macOS document-level input source switching in Keyboard settings if AutoSwitch reports that it is enabled.
5. Pick a global default input source.
6. Add app rules from the running app list or by bundle ID.
7. Add Spotlight-like apps if you use Raycast, hapiGO, Alfred, or another floating launcher.
8. Enable launch at login if desired.

The app stores configuration at:

```text
~/Library/Application Support/AutoSwitch/config.json
```

If the config file is corrupt, AutoSwitch backs it up as `config.corrupt.<timestamp>.json` and starts from defaults.

## Behavior

- Normal apps use `NSWorkspace.didActivateApplicationNotification`.
- Rules match by bundle ID.
- Same-app window and focus changes are intentionally ignored.
- Spotlight-like panels use Accessibility observers plus a CGWindow visibility fallback.
- Switches are debounced: 150 ms before applying, then one verification/correction at 500 ms total.
- Temporary manual input-source changes are not written back to config.
- Wake/session-active events re-evaluate the current frontmost app.

AutoSwitch switches macOS system input sources through Carbon TIS APIs. It does not handle internal English/Chinese modes inside third-party IMEs.

## Privacy

AutoSwitch needs Accessibility permission to read the active app, detect terminal
prompts, and observe keystrokes for the `/`-to-English and transient-English
features. All keyboard observation is local and listen-only: a single shared
event tap uses keystrokes only to detect trigger keys (`/`, space/return, bare
Shift) and terminal-prompt activity in the moment. Nothing typed is recorded,
stored, or transmitted, and there is no telemetry.

## Updates

Sparkle 2.x is integrated through Swift Package Manager. The Debug project uses placeholder values until release inputs are supplied:

- `SUFeedURL`
- `SUPublicEDKey`

Use the Check for Updates button in Settings after a real appcast and public EdDSA key are configured.

Sparkle private keys are user-owned release material. Generate or import them outside the repository and put only the public EdDSA key in `AutoSwitch/App/Info.plist`.

## Logs

```bash
log show --info --style compact --predicate 'subsystem == "dev.autoswitch"' --last 5m
```

Common categories:

- `app`
- `app-state`
- `input-source`
- `coordinator`
- `scheduler`
- `spotlight-monitor`
- `single-instance`

## Release

Dry run:

```bash
Scripts/release.sh --dry-run
```

Required environment variables for a real release:

- `AUTOSWITCH_SIGNING_IDENTITY`
- `AUTOSWITCH_ED_PRIVATE_KEY`
- `AUTOSWITCH_REPO`
- `AUTOSWITCH_RELEASE_TAG`
- `AUTOSWITCH_RELEASE_NOTES_URL`
- `AUTOSWITCH_FEED_URL`

The release script archives the app, signs the exported `.app`, zips it, signs the zip with Sparkle EdDSA, writes `appcast.xml`, and uses `gh release create` when GitHub CLI is available.

The signing identity is expected to be a local self-signed Code Signing certificate common name. Use the same signing identity for subsequent releases so Sparkle can replace the app cleanly.

Do not commit Sparkle private keys, signing certificate material, or GitHub tokens.
