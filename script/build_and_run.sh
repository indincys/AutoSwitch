#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AutoSwitchDEV"
PROJECT="$ROOT_DIR/AutoSwitch.xcodeproj"
SCHEME="AutoSwitch"
BUILD_DIR="$ROOT_DIR/DerivedData"
CONFIGURATION="Debug"
DESTINATION='platform=macOS,arch=arm64'
APP_BUNDLE="$BUILD_DIR/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

kill_existing() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

build() {
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "$DESTINATION" -derivedDataPath "$BUILD_DIR" build
}

launch() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    kill_existing
    build
    launch
    ;;
  --debug|debug)
    kill_existing
    build
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    kill_existing
    build
    launch
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    kill_existing
    build
    launch
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"dev.autoswitch\""
    ;;
  --verify|verify)
    kill_existing
    build
    launch
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
