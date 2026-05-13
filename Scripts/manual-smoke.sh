#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT_DIR="$ROOT_DIR/Build/manual-smoke"
CONFIG_FILE="$HOME/Library/Application Support/AutoSwitch/config.json"
APP_NAME="AutoSwitch"
LOG_SUBSYSTEM="dev.autoswitch"

usage() {
  cat <<'EOF'
Usage:
  Scripts/manual-smoke.sh [--no-build]

Runs a guided manual smoke session for AutoSwitch and writes a Markdown report
under Build/manual-smoke/. The script does not change system settings; it only
starts AutoSwitch unless --no-build is supplied, prompts for manual actions, and
collects logs/config hashes.
EOF
}

NO_BUILD=0
case "${1:-}" in
  "")
    ;;
  --no-build)
    NO_BUILD=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

hash_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    shasum -a 256 "$CONFIG_FILE" | awk '{print $1}'
  else
    echo "missing"
  fi
}

frontmost_bundle_id() {
  /usr/bin/osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true' 2>/dev/null || true
}

current_input_source() {
  /usr/bin/swift -e 'import Carbon.HIToolbox; if let unmanaged = TISCopyCurrentKeyboardInputSource() { let source = unmanaged.takeRetainedValue(); if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) { print(Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String) } }' 2>/dev/null || true
}

enabled_input_sources() {
  /usr/bin/swift -e 'import Carbon.HIToolbox; let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource] as CFDictionary; if let unmanaged = TISCreateInputSourceList(filter, false) { let list = unmanaged.takeRetainedValue() as NSArray; for item in list { let source = item as! TISInputSource; func str(_ key: CFString) -> String { guard let raw = TISGetInputSourceProperty(source, key) else { return "" }; return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String }; func bool(_ key: CFString) -> Bool { guard let raw = TISGetInputSourceProperty(source, key) else { return false }; return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue()) }; if bool(kTISPropertyInputSourceIsEnabled) && bool(kTISPropertyInputSourceIsSelectCapable) { print("\(str(kTISPropertyInputSourceID))\t\(str(kTISPropertyLocalizedName))") } } }' 2>/dev/null || true
}

visible_windows() {
  /usr/bin/swift -e 'import AppKit; import CoreGraphics; let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []; for window in windows { guard let layer = window[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0 else { continue }; guard let onscreen = window[kCGWindowIsOnscreen as String] as? NSNumber, onscreen.boolValue else { continue }; let owner = window[kCGWindowOwnerName as String] as? String ?? "unknown"; let pid = window[kCGWindowOwnerPID as String] as? NSNumber; let bundleID = pid.flatMap { NSRunningApplication(processIdentifier: $0.int32Value)?.bundleIdentifier } ?? "unknown"; let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]; print("\(owner)\t\(bundleID)\t\(bounds)") }' 2>/dev/null || true
}

collect_logs() {
  local since="$1"
  /usr/bin/log show \
    --info \
    --style compact \
    --predicate "subsystem == \"$LOG_SUBSYSTEM\"" \
    --start "$since" 2>/dev/null || true
}

report_has() {
  local pattern="$1"
  local file="$2"
  if grep -Eq "$pattern" "$file"; then
    echo "pass"
  else
    echo "needs review"
  fi
}

ask_result() {
  local prompt="$1"
  local answer
  while true; do
    read -r -p "$prompt [pass/fail/skip]: " answer
    case "$answer" in
      pass|fail|skip)
        echo "$answer"
        return
        ;;
      *)
        echo "Please enter pass, fail, or skip." >&2
        ;;
    esac
  done
}

mkdir -p "$REPORT_DIR"
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
REPORT="$REPORT_DIR/$RUN_ID.md"
LOG_FILE="$REPORT_DIR/$RUN_ID.log"

if [[ "$NO_BUILD" -eq 0 ]]; then
  echo "Building and launching AutoSwitch..."
  "$ROOT_DIR/script/build_and_run.sh" --verify
else
  echo "Skipping build/launch because --no-build was supplied."
  pgrep -x "$APP_NAME" >/dev/null || {
    echo "AutoSwitch is not running. Start it first or omit --no-build." >&2
    exit 1
  }
fi

START_WALL="$(date '+%Y-%m-%d %H:%M:%S %z')"
LOG_START="$(date '+%Y-%m-%d %H:%M:%S')"
BEFORE_HASH="$(hash_config)"
BEFORE_INPUT="$(current_input_source)"
BEFORE_FRONTMOST="$(frontmost_bundle_id)"
AUTOSWITCH_PID="$(pgrep -x "$APP_NAME" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
INPUT_SOURCES="$(enabled_input_sources)"
WINDOWS_BEFORE="$(visible_windows)"
AUTH_WARN_PROCESS="$(pgrep -fl universalAccessAuthWarn || true)"

cat <<EOF

Manual smoke started at $START_WALL.

Do these actions in the logged-in desktop session, then return here and press Enter:

1. Confirm AutoSwitch has no Dock icon and no menu bar status item.
2. Confirm the settings window is visible and sized reasonably.
3. Confirm the input source list contains ABC and at least one Chinese input source.
4. Switch from a global/default app such as Safari or Finder to Terminal, wait 1 second, then switch back.
5. Switch between two windows in the same app, if available, and wait 1 second.
6. Temporarily change the input source manually, then switch apps again.
7. Show Spotlight with Command-Space, wait 1 second, then close it.
8. If acceptable, lock/unlock or wake the machine, then return to the current app.
9. Toggle Launch at Login in AutoSwitch settings only if you intend to test that system setting.

The script will collect AutoSwitch logs and config hashes after you press Enter.
EOF

read -r -p "Press Enter after completing the manual actions..."

echo
echo "Record manual observations for the report."
DOCK_STATUS="$(ask_result "No Dock icon and no menu bar status item")"
WINDOW_STATUS="$(ask_result "Settings window visible and correctly sized")"
INPUT_LIST_STATUS="$(ask_result "Input source list includes ABC and at least one Chinese source")"
SAME_BUNDLE_STATUS="$(ask_result "Same-bundle window switch did not trigger extra rule scheduling")"
LOGIN_ITEM_STATUS="$(ask_result "Launch at Login toggle/reboot behavior")"
read -r -p "Optional notes: " MANUAL_NOTES

END_WALL="$(date '+%Y-%m-%d %H:%M:%S %z')"
AFTER_HASH="$(hash_config)"
AFTER_INPUT="$(current_input_source)"
AFTER_FRONTMOST="$(frontmost_bundle_id)"
WINDOWS_AFTER="$(visible_windows)"
collect_logs "$LOG_START" > "$LOG_FILE"

APP_ACTIVATION_STATUS="$(report_has 'app activation:' "$LOG_FILE")"
APP_RULE_STATUS="$(report_has 'because app rule' "$LOG_FILE")"
GLOBAL_RULE_STATUS="$(report_has 'because global default' "$LOG_FILE")"
SPOTLIGHT_SHOWN_STATUS="$(report_has 'panel shown: com\\.apple\\.Spotlight' "$LOG_FILE")"
SPOTLIGHT_HIDDEN_STATUS="$(report_has 'panel hidden' "$LOG_FILE")"
WAKE_STATUS="$(report_has 'system wake/session active' "$LOG_FILE")"
VERIFICATION_STATUS="$(report_has 'verification matched target|verification mismatch' "$LOG_FILE")"

if [[ "$BEFORE_HASH" == "$AFTER_HASH" ]]; then
  CONFIG_STATUS="pass"
else
  CONFIG_STATUS="changed"
fi

cat > "$REPORT" <<EOF
# AutoSwitch Manual Smoke Report

- Started: $START_WALL
- Ended: $END_WALL
- Initial frontmost bundle: $BEFORE_FRONTMOST
- Final frontmost bundle: $AFTER_FRONTMOST
- Initial input source: $BEFORE_INPUT
- Final input source: $AFTER_INPUT
- Config hash before: $BEFORE_HASH
- Config hash after: $AFTER_HASH
- AutoSwitch PID(s): $AUTOSWITCH_PID
- Accessibility warning process: ${AUTH_WARN_PROCESS:-none}
- Raw log file: $LOG_FILE

## Automated Checks From Collected Logs

- App activation events: $APP_ACTIVATION_STATUS
- App rule scheduling: $APP_RULE_STATUS
- Global default scheduling: $GLOBAL_RULE_STATUS
- Spotlight shown event: $SPOTLIGHT_SHOWN_STATUS
- Spotlight hidden event: $SPOTLIGHT_HIDDEN_STATUS
- Wake/session-active event: $WAKE_STATUS
- Switch verification/correction log: $VERIFICATION_STATUS
- Config hash unchanged after temporary manual switch: $CONFIG_STATUS

## Manual Observations

- No Dock icon and no menu bar status item: $DOCK_STATUS
- Settings window visible and correctly sized: $WINDOW_STATUS
- Input source list includes ABC and at least one Chinese source: $INPUT_LIST_STATUS
- Same-bundle window switch did not trigger extra rule scheduling: $SAME_BUNDLE_STATUS
- Launch at Login toggle/reboot behavior: $LOGIN_ITEM_STATUS
- Notes: $MANUAL_NOTES

## Enabled Input Sources At Start

\`\`\`text
$INPUT_SOURCES
\`\`\`

## Visible Windows At Start

\`\`\`text
$WINDOWS_BEFORE
\`\`\`

## Visible Windows At End

\`\`\`text
$WINDOWS_AFTER
\`\`\`

## Relevant AutoSwitch Logs

\`\`\`text
$(tail -n 240 "$LOG_FILE")
\`\`\`
EOF

echo
echo "Manual smoke report written to:"
echo "$REPORT"
echo
echo "Summary:"
echo "  App activation events: $APP_ACTIVATION_STATUS"
echo "  App rule scheduling: $APP_RULE_STATUS"
echo "  Global default scheduling: $GLOBAL_RULE_STATUS"
echo "  Spotlight shown event: $SPOTLIGHT_SHOWN_STATUS"
echo "  Spotlight hidden event: $SPOTLIGHT_HIDDEN_STATUS"
echo "  Wake/session-active event: $WAKE_STATUS"
echo "  Config hash status: $CONFIG_STATUS"
echo "  Manual Dock/menu status: $DOCK_STATUS"
echo "  Manual settings window status: $WINDOW_STATUS"
echo "  Manual input list status: $INPUT_LIST_STATUS"
