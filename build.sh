#!/bin/bash
# Assembles ScreenMask.app. SwiftPM only emits a bare executable, and a bare
# executable can't behave like a real Mac app (menu bar, focus, file panels),
# so the bundle is put together by hand around it.
set -euo pipefail

CONFIG="${1:-release}"
cd "$(dirname "$0")"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
# Named with the space: the Dock and Finder label an app by its bundle
# filename, so "ScreenMask.app" would show as "ScreenMask" no matter what
# CFBundleName says. The executable inside keeps the compact name.
APP="$BIN/Screen Mask.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ScreenMask" "$APP/Contents/MacOS/ScreenMask"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The iconset stays the source of truth; the .icns is generated, not committed.
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature; without one the bundle is killed on launch on Apple silicon.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "$APP"
