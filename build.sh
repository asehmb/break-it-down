#!/bin/bash
# Builds "Break It Down.app" into ./build. Usage: ./build.sh   (add --run to open it after)
set -euo pipefail
cd "$(dirname "$0")"

echo "› Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/BreakItDown"
[ -x "$BIN" ] || { echo "✗ Build failed"; exit 1; }

APP="build/Break It Down.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BreakItDown"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon from Resources/icon.png
if [ -f Resources/icon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP"

if [ "${1:-}" = "--run" ]; then
  open "$APP"
fi
