#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/CalendarMonth.swift scripts/CalendarChecks.swift -o .build/calendar-checks
.build/calendar-checks
xcrun swiftc -parse-as-library Sources/ToolCore/{CalendarMonth,CalendarNotes,ToolFeatures}.swift Sources/WallpaperApp/{AppLanguage,CalendarTool,CalendarNotesView}.swift scripts/CalendarUIChecks.swift -o .build/calendar-ui-checks
.build/calendar-ui-checks

xcrun swiftc -parse-as-library Sources/ToolCore/CalendarNotes.swift scripts/CalendarNotesChecks.swift -o .build/calendar-notes-checks
.build/calendar-notes-checks
