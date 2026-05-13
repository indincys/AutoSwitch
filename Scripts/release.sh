#!/usr/bin/env bash
set -euo pipefail

DRY_RUN=0

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/AutoSwitch.xcodeproj"
SCHEME="AutoSwitch"
CONFIGURATION="Release"
DESTINATION="generic/platform=macOS"
DERIVED_DATA="$ROOT_DIR/DerivedData"
BUILD_DIR="$ROOT_DIR/Build"
ARCHIVE_PATH="$BUILD_DIR/AutoSwitch.xcarchive"
EXPORT_PATH="$BUILD_DIR/Export"
APP_NAME="AutoSwitch"
APP_BUNDLE="$EXPORT_PATH/$APP_NAME.app"
ARCHIVE_ZIP="$BUILD_DIR/${APP_NAME}.zip"
ENTITLEMENTS_FILE="$ROOT_DIR/AutoSwitch/App/AutoSwitch.entitlements"
APPCAST_OUTPUT="$ROOT_DIR/appcast.xml"
APPCAST_TEMPLATE="$ROOT_DIR/Scripts/appcast.template.xml"
SPARKLE_ROOT="$ROOT_DIR/DerivedData/SourcePackages/checkouts/Sparkle"
SPARKLE_PROJECT="$SPARKLE_ROOT/Sparkle.xcodeproj"
SPARKLE_TOOL_SCHEMES=(generate_keys sign_update generate_appcast)
SPARKLE_TOOL_DIR="$DERIVED_DATA/Build/Products/Release"

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
}

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  value="${value//\"/&quot;}"
  value="${value//\'/&apos;}"
  printf '%s' "$value"
}

usage() {
  cat <<'EOF'
Usage:
  Scripts/release.sh --dry-run
  Scripts/release.sh

Required environment variables for a real release:
  AUTOSWITCH_SIGNING_IDENTITY   Code signing certificate common name
  AUTOSWITCH_REPO               GitHub repo in owner/name form
  AUTOSWITCH_RELEASE_TAG        Release tag, e.g. v0.1.0
  AUTOSWITCH_RELEASE_NOTES_URL  Release notes URL
  AUTOSWITCH_FEED_URL           Appcast URL

Optional:
  AUTOSWITCH_ED_PRIVATE_KEY     Path to Sparkle EdDSA private key file. If
                                unset, sign_update reads the key from the
                                macOS Keychain (default account).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
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
done

if [[ "$DRY_RUN" -eq 0 ]]; then
  require_env AUTOSWITCH_SIGNING_IDENTITY
  require_env AUTOSWITCH_REPO
  require_env AUTOSWITCH_RELEASE_TAG
  require_env AUTOSWITCH_RELEASE_NOTES_URL
  require_env AUTOSWITCH_FEED_URL
fi

if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
  echo "Entitlements file not found: $ENTITLEMENTS_FILE" >&2
  exit 1
fi

if [[ ! -f "$APPCAST_TEMPLATE" ]]; then
  echo "Appcast template not found: $APPCAST_TEMPLATE" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "Building release archive..."
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -destination "$DESTINATION" -derivedDataPath "$DERIVED_DATA" archive -archivePath "$ARCHIVE_PATH"

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive missing app bundle: $APP_PATH" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_PROJECT" ]]; then
  echo "Sparkle project not found at $SPARKLE_PROJECT" >&2
  exit 1
fi

for scheme in "${SPARKLE_TOOL_SCHEMES[@]}"; do
  xcodebuild -project "$SPARKLE_PROJECT" -scheme "$scheme" -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" build
done

SIGN_UPDATE="$SPARKLE_TOOL_DIR/sign_update"
GENERATE_APPCAST="$SPARKLE_TOOL_DIR/generate_appcast"
GENERATE_KEYS="$SPARKLE_TOOL_DIR/generate_keys"

if [[ ! -x "$SIGN_UPDATE" || ! -x "$GENERATE_APPCAST" || ! -x "$GENERATE_KEYS" ]]; then
  echo "Sparkle CLI tools are not available at $SPARKLE_TOOL_DIR." >&2
  echo "The release script attempted to build generate_keys, sign_update, and generate_appcast first." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete."
  echo "Archive: $ARCHIVE_PATH"
  echo "Zip: $ARCHIVE_ZIP"
  echo "Appcast template: $APPCAST_TEMPLATE"
  echo "Sparkle tools: $SPARKLE_TOOL_DIR"
  exit 0
fi

rm -rf "$EXPORT_PATH"
mkdir -p "$EXPORT_PATH"
cp -R "$APP_PATH" "$EXPORT_PATH/"
codesign --force --deep --entitlements "$ENTITLEMENTS_FILE" --sign "$AUTOSWITCH_SIGNING_IDENTITY" "$APP_BUNDLE"

rm -f "$ARCHIVE_ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_BUNDLE" "$ARCHIVE_ZIP"

if [[ -n "${AUTOSWITCH_ED_PRIVATE_KEY:-}" ]]; then
  if [[ ! -f "$AUTOSWITCH_ED_PRIVATE_KEY" ]]; then
    echo "Sparkle private key not found: $AUTOSWITCH_ED_PRIVATE_KEY" >&2
    exit 1
  fi
  SIGNATURE="$("$SIGN_UPDATE" --ed-key-file "$AUTOSWITCH_ED_PRIVATE_KEY" -p "$ARCHIVE_ZIP")"
else
  SIGNATURE="$("$SIGN_UPDATE" -p "$ARCHIVE_ZIP")"
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
ARCHIVE_SIZE="$(stat -f%z "$ARCHIVE_ZIP")"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
ARCHIVE_NAME="$(basename "$ARCHIVE_ZIP")"
ARCHIVE_URL="https://github.com/${AUTOSWITCH_REPO}/releases/download/${AUTOSWITCH_RELEASE_TAG}/${ARCHIVE_NAME}"

APPCAST_CONTENT="$(<"$APPCAST_TEMPLATE")"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{FEED_URL\}\}/$(xml_escape "$AUTOSWITCH_FEED_URL")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{VERSION\}\}/$(xml_escape "$APP_VERSION")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{SHORT_VERSION\}\}/$(xml_escape "$SHORT_VERSION")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{PUB_DATE\}\}/$(xml_escape "$PUB_DATE")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{ARCHIVE_URL\}\}/$(xml_escape "$ARCHIVE_URL")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{ARCHIVE_SIZE\}\}/$(xml_escape "$ARCHIVE_SIZE")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{ED_SIGNATURE\}\}/$(xml_escape "$SIGNATURE")}"
APPCAST_CONTENT="${APPCAST_CONTENT//\{\{RELEASE_NOTES_URL\}\}/$(xml_escape "$AUTOSWITCH_RELEASE_NOTES_URL")}"
printf '%s\n' "$APPCAST_CONTENT" > "$APPCAST_OUTPUT"

echo "Wrote appcast to $APPCAST_OUTPUT"

if command -v gh >/dev/null 2>&1; then
  gh release create "$AUTOSWITCH_RELEASE_TAG" "$ARCHIVE_ZIP" --repo "$AUTOSWITCH_REPO" --notes "AutoSwitch ${SHORT_VERSION}"
else
  echo "GitHub CLI not found; upload $ARCHIVE_ZIP manually." >&2
fi
