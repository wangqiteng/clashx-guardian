#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClashXGuardianStatus"
DISPLAY_NAME="ClashX Guardian Status"
BUNDLE_ID="com.local.ClashXGuardianStatus"
MIN_SYSTEM_VERSION="13.0"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$ROOT_DIR/dist/$DISPLAY_NAME.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
STAGE_ROOT="$(/usr/bin/mktemp -d /private/tmp/clashx-guardian-build.XXXXXX)"
STAGE_BUNDLE="$STAGE_ROOT/$DISPLAY_NAME.app"
STAGE_MACOS="$STAGE_BUNDLE/Contents/MacOS"
STAGE_BINARY="$STAGE_MACOS/$APP_NAME"
STAGE_PLIST="$STAGE_BUNDLE/Contents/Info.plist"
trap 'rm -rf "$STAGE_ROOT"' EXIT

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$BUILD_DIR" "$STAGE_MACOS"
clang -fobjc-arc -Wall -Wextra -Werror \
  -framework Cocoa -framework UserNotifications \
  "$ROOT_DIR/Sources/ClashXGuardianStatus/main.m" -o "$STAGE_BINARY"
"$STAGE_BINARY" --self-test "$ROOT_DIR/Tests/fixtures/healthy-status.json"
"$STAGE_BINARY" --self-test "$ROOT_DIR/Tests/fixtures/switching-status.json"
install -m 0755 "$STAGE_BINARY" "$BUILD_DIR/$APP_NAME"

cat >"$STAGE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.1.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$STAGE_PLIST" >/dev/null
xattr -cr "$STAGE_BUNDLE"
codesign --force --deep --sign - "$STAGE_BUNDLE" >/dev/null
codesign --verify --deep --strict "$STAGE_BUNDLE"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto --norsrc --noextattr "$STAGE_BUNDLE" "$APP_BUNDLE"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  run) open_app ;;
  --build|build) ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 2; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
