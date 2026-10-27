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
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
