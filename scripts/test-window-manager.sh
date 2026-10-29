#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/WindowLayout.swift scripts/WindowLayoutChecks.swift -o .build/window-layout-checks
.build/window-layout-checks
xcrun swiftc scripts/WindowManagerFixture.swift -o .build/window-fixture
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/AppSwitcher.swift Sources/WallpaperApp/ClipboardWindow.swift Sources/WallpaperApp/ClipboardSettingsWindow.swift Sources/WallpaperApp/KeepAwake.swift Sources/WallpaperApp/WindowManager.swift scripts/WindowManagerSmokeChecks.swift -o .build/window-smoke-checks
# Fixture closes itself after 25 seconds; no user's app windows are modified.
.build/window-fixture > .build/window-fixture.log 2>&1 &
fixture_pid=$!
.build/window-smoke-checks "$fixture_pid" "$@"
