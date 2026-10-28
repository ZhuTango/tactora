#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${OUTPUT_APP:-dist/轻工具.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p .build
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O -whole-module-optimization Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift Sources/WallpaperApp/*.swift -o "$APP/Contents/MacOS/MacBGLive"
xcrun swift scripts/icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Pass a stable code-signing identity to retain TCC identity across builds.
# Ad-hoc builds necessarily require fresh user authorization after updates.
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
