#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift Sources/WallpaperApp/ToolIcon.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/AppSwitcher.swift Sources/WallpaperApp/WindowManager.swift Sources/WallpaperApp/ClipboardWindow.swift Sources/WallpaperApp/ClipboardSettingsWindow.swift Sources/WallpaperApp/KeepAwake.swift scripts/ClipboardUIChecks.swift -o .build/clipboard-ui-checks
.build/clipboard-ui-checks | tee .build/clipboard-ui-last.log
grep -q "^PASS: immediate typing search" .build/clipboard-ui-last.log
