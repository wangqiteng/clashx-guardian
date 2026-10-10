#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTNET_BIN="${DOTNET:-dotnet}"
RID="${1:-win-x64}"
case "$RID" in win-x64|win-arm64) ;; *) echo "Unsupported runtime: $RID" >&2; exit 2 ;; esac
VERSION="0.1.0-preview"
PACKAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ikuuu-guardian-win.XXXXXX")"
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
PACKAGE_DIR="$PACKAGE_ROOT/IKuuu-Guardian-$VERSION-$RID"
"$DOTNET_BIN" run --project "$ROOT_DIR/Windows/Guardian.Tests/Guardian.Tests.csproj" -c Release
"$DOTNET_BIN" publish "$ROOT_DIR/Windows/Guardian.Windows/Guardian.Windows.csproj" -c Release -r "$RID" \
  --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:DebugType=None -p:DebugSymbols=false -o "$PACKAGE_DIR"
cp "$ROOT_DIR/Windows/README.md" "$PACKAGE_DIR/README.md"
mkdir -p "$ROOT_DIR/outputs"
ARCHIVE="$ROOT_DIR/outputs/IKuuu-Guardian-v$VERSION-$RID.zip"
(cd "$PACKAGE_ROOT" && zip -qr "$PACKAGE_ROOT/release.zip" "$(basename "$PACKAGE_DIR")")
mv "$PACKAGE_ROOT/release.zip" "$ARCHIVE"
if command -v shasum >/dev/null; then
  (cd "$ROOT_DIR/outputs" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
else
  (cd "$ROOT_DIR/outputs" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
fi
echo "$ARCHIVE"
