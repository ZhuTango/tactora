#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${OUTPUT_APP:-dist/轻工具.app}"
# Refuse accidental identity changes before compiling or touching the output.
identity_file="$HOME/Library/Application Support/Light Tools Signing/identity.sha1"
if [[ -z "${SIGNING_IDENTITY:-}" && -f "$identity_file" ]]; then
    SIGNING_IDENTITY="$(cat "$identity_file")"
fi
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    if [[ "${ALLOW_ADHOC_SIGNING:-0}" == 1 ]]; then SIGNING_IDENTITY="-"
    else
        echo 'No stable signing identity. Configure SIGNING_IDENTITY or install the local signing certificate. For disposable builds only: ALLOW_ADHOC_SIGNING=1.' >&2
        exit 1
    fi
fi
if [[ "$SIGNING_IDENTITY" == '-' && "${ALLOW_ADHOC_SIGNING:-0}" != 1 ]]; then
    echo 'Ad-hoc signing changes Accessibility identity on every build. Explicitly set ALLOW_ADHOC_SIGNING=1 for disposable builds.' >&2
    exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p .build
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -O -whole-module-optimization Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift Sources/WallpaperApp/*.swift -o "$APP/Contents/MacOS/MacBGLive"
xcrun swiftc Sources/WallpaperApp/ToolIcon.swift scripts/icon.swift -o .build/icon-builder
.build/icon-builder .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Default designated requirement is certificate-bound for a real signing identity.
# Never replace it with an identifier-only requirement (which would weaken trust).
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict "$APP"
printf 'Built: %s/%s\n' "$PWD" "$APP"
