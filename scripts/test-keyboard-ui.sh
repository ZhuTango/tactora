#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift Sources/WallpaperApp/{ToolIcon,AppLanguage,OCR,TextToolsShortcut,AppSwitcher,WindowManager,ClipboardWindow,CalendarTool,ClipboardSettingsWindow,KeepAwake,KeyboardManager,KeyboardHelperBridge,KeyboardSettingsView}.swift scripts/KeyboardTestSupport.swift scripts/KeyboardUIChecks.swift -o .build/keyboard-ui-checks
.build/keyboard-ui-checks "$@"
