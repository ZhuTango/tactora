#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/ClipboardWindow.swift Sources/WallpaperApp/ClipboardSettingsWindow.swift scripts/ClipboardUIChecks.swift -o .build/clipboard-ui-checks
.build/clipboard-ui-checks
