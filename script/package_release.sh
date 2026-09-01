#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-2.3.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/outputs/clashx-guardian"
APP_NAME="ClashX Guardian Status.app"
ARCHIVE="$ROOT_DIR/outputs/ClashX-Guardian-v${VERSION}-macOS.zip"
RELEASE_ROOT="$(/usr/bin/mktemp -d /private/tmp/clashx-guardian-release.XXXXXX)"
RELEASE_DIR="$RELEASE_ROOT/clashx-guardian"
TEMP_ARCHIVE="$RELEASE_ROOT/$(basename "$ARCHIVE")"
trap 'rm -rf "$RELEASE_ROOT"' EXIT

"$ROOT_DIR/script/build_and_run.sh" --build

mkdir -p "$RELEASE_DIR"
/bin/cp -R "$PACKAGE_DIR/." "$RELEASE_DIR/"
rm -rf "$RELEASE_DIR/$APP_NAME"
/bin/cp -R "$ROOT_DIR/dist/$APP_NAME" "$RELEASE_DIR/$APP_NAME"
mkdir -p "$RELEASE_DIR/Source"
install -m 0644 "$ROOT_DIR/Sources/ClashXGuardianStatus/main.m" "$RELEASE_DIR/Source/ClashXGuardianStatus.m"
install -m 0644 "$ROOT_DIR/Sources/GuardianStartPolicy.h" "$RELEASE_DIR/Source/GuardianStartPolicy.h"
install -m 0644 "$ROOT_DIR/Sources/GuardianStartPolicy.m" "$RELEASE_DIR/Source/GuardianStartPolicy.m"
mkdir -p "$RELEASE_DIR/Tests"
install -m 0644 "$ROOT_DIR/Tests/GuardianStartPolicyTests.m" "$RELEASE_DIR/Tests/GuardianStartPolicyTests.m"
chmod 0755 "$RELEASE_DIR/clashx-guardian.pl" "$RELEASE_DIR/install.sh" "$RELEASE_DIR/uninstall.sh"
xattr -cr "$RELEASE_DIR"
codesign --force --deep --sign - "$RELEASE_DIR/$APP_NAME" >/dev/null
codesign --verify --deep --strict "$RELEASE_DIR/$APP_NAME"

rm -f "$ARCHIVE" "$ARCHIVE.sha256"
(cd "$RELEASE_ROOT" && /usr/bin/zip -qry -X "$TEMP_ARCHIVE" "$(basename "$RELEASE_DIR")")

if /usr/bin/zipinfo -1 "$TEMP_ARCHIVE" | /usr/bin/grep -E '/(config[.]conf|runtime-state[.]json|status[.]json|[^/]*[.]log)$' >/dev/null; then
  echo "release verification failed: private runtime file found in archive" >&2
  exit 1
fi

install -m 0644 "$TEMP_ARCHIVE" "$ARCHIVE"
(cd "$(dirname "$ARCHIVE")" && /usr/bin/shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
echo "$ARCHIVE"
