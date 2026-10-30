#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift Sources/WallpaperApp/ToolIcon.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/OCR.swift Sources/WallpaperApp/TextToolsShortcut.swift Sources/WallpaperApp/AppSwitcher.swift Sources/WallpaperApp/WindowManager.swift Sources/WallpaperApp/ClipboardWindow.swift Sources/WallpaperApp/ClipboardSettingsWindow.swift Sources/WallpaperApp/KeepAwake.swift scripts/KeepAwakeChecks.swift -o .build/keep-awake-checks
.build/keep-awake-checks
