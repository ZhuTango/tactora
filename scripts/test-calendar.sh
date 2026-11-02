#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/CalendarMonth.swift scripts/CalendarChecks.swift -o .build/calendar-checks
.build/calendar-checks
xcrun swiftc -parse-as-library Sources/ToolCore/{CalendarMonth,ToolFeatures}.swift Sources/WallpaperApp/{AppLanguage,CalendarTool}.swift scripts/CalendarUIChecks.swift -o .build/calendar-ui-checks
.build/calendar-ui-checks
