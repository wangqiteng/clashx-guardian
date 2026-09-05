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
STAGE_RESOURCES="$STAGE_BUNDLE/Contents/Resources"
STAGE_BINARY="$STAGE_MACOS/$APP_NAME"
STAGE_PLIST="$STAGE_BUNDLE/Contents/Info.plist"
STAGE_ICONSET="$STAGE_ROOT/AppIcon.iconset"
trap 'rm -rf "$STAGE_ROOT"' EXIT

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
mkdir -p "$BUILD_DIR" "$STAGE_MACOS" "$STAGE_RESOURCES" "$STAGE_ICONSET"
clang -fobjc-arc -Wall -Wextra -Werror -I"$ROOT_DIR/Sources" \
  -framework Cocoa -framework UserNotifications -framework ApplicationServices \
  "$ROOT_DIR/Sources/ClashXGuardianStatus/main.m" \
  "$ROOT_DIR/Sources/GuardianStartPolicy.m" \
  "$ROOT_DIR/Sources/IKuuuNodeParser.m" \
  "$ROOT_DIR/Sources/IKuuuAccessibilityAdapter.m" \
  "$ROOT_DIR/Sources/IKuuuRequestCoordinator.m" -o "$STAGE_BINARY"
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
  "$ROOT_DIR/Tests/GuardianStartPolicyTests.m" \
  "$ROOT_DIR/Sources/GuardianStartPolicy.m" -o "$STAGE_ROOT/GuardianStartPolicyTests"
"$STAGE_ROOT/GuardianStartPolicyTests"
clang -fobjc-arc -Wall -Wextra -Werror -I"$ROOT_DIR/Sources" -framework Foundation \
  "$ROOT_DIR/Tests/IKuuuNodeParserTests.m" \
  "$ROOT_DIR/Sources/IKuuuNodeParser.m" -o "$STAGE_ROOT/IKuuuNodeParserTests"
"$STAGE_ROOT/IKuuuNodeParserTests"
clang -fobjc-arc -Wall -Wextra -Werror -I"$ROOT_DIR/Sources" \
  -framework Cocoa -framework ApplicationServices \
  "$ROOT_DIR/Tests/IKuuuAccessibilityAdapterTests.m" \
  "$ROOT_DIR/Sources/IKuuuAccessibilityAdapter.m" \
  "$ROOT_DIR/Sources/IKuuuNodeParser.m" -o "$STAGE_ROOT/IKuuuAccessibilityAdapterTests"
"$STAGE_ROOT/IKuuuAccessibilityAdapterTests"
clang -fobjc-arc -Wall -Wextra -Werror -I"$ROOT_DIR/Sources" \
  -framework Cocoa -framework ApplicationServices \
  "$ROOT_DIR/Tests/IKuuuRequestCoordinatorTests.m" \
  "$ROOT_DIR/Sources/IKuuuRequestCoordinator.m" \
  "$ROOT_DIR/Sources/IKuuuAccessibilityAdapter.m" \
  "$ROOT_DIR/Sources/IKuuuNodeParser.m" -o "$STAGE_ROOT/IKuuuRequestCoordinatorTests"
"$STAGE_ROOT/IKuuuRequestCoordinatorTests"
"$STAGE_BINARY" --self-test "$ROOT_DIR/Tests/fixtures/healthy-status.json"
"$STAGE_BINARY" --self-test "$ROOT_DIR/Tests/fixtures/switching-status.json"
install -m 0755 "$STAGE_BINARY" "$BUILD_DIR/$APP_NAME"

ICON_SOURCE="$STAGE_ROOT/GuardianAppIcon.png"
"$STAGE_BINARY" --render-app-icon "$ICON_SOURCE"
make_icon() {
  local pixels="$1" output="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$STAGE_ICONSET/$output" >/dev/null
}
make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
/usr/bin/perl "$ROOT_DIR/script/build_icns.pl" "$STAGE_ICONSET" "$STAGE_RESOURCES/AppIcon.icns"

cat >"$STAGE_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>2.4.2</string>
  <key>CFBundleVersion</key><string>10</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$STAGE_PLIST" >/dev/null
if [[ ! -f "$STAGE_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
  echo "build verification failed: AppIcon.icns is missing from the app bundle" >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleIconFile raw "$STAGE_PLIST")" != "AppIcon" ]]; then
  echo "build verification failed: CFBundleIconFile does not reference AppIcon" >&2
  exit 1
fi
VERIFY_ICONSET="$STAGE_ROOT/VerifiedAppIcon.iconset"
/usr/bin/iconutil -c iconset "$STAGE_RESOURCES/AppIcon.icns" -o "$VERIFY_ICONSET"
if [[ ! -f "$VERIFY_ICONSET/icon_512x512@2x.png" ]]; then
  echo "build verification failed: AppIcon.icns does not contain its 1024px representation" >&2
  exit 1
fi
xattr -cr "$STAGE_BUNDLE"
codesign --force --deep --sign - "$STAGE_BUNDLE" >/dev/null
codesign --verify --deep --strict "$STAGE_BUNDLE"
rm -rf "$APP_BUNDLE"
/usr/bin/ditto --norsrc --noextattr "$STAGE_BUNDLE" "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE"
/usr/bin/cmp "$STAGE_BINARY" "$APP_BINARY"
/usr/bin/cmp "$STAGE_PLIST" "$INFO_PLIST"
/usr/bin/cmp "$STAGE_RESOURCES/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

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
