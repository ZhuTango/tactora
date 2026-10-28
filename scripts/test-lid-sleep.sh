#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/LidSleepPolicy.swift scripts/LidSleepChecks.swift -o .build/lid-checks
.build/lid-checks
xcrun swiftc -parse-as-library Sources/ToolCore/LidSleepPolicy.swift Sources/WallpaperApp/LidDisplaySleep.swift scripts/LidMonitorChecks.swift -o .build/lid-monitor-checks
.build/lid-monitor-checks
