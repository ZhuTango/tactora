#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
for source in Sources/WallpaperApp/*.swift; do
    [[ "$source" == */main.swift ]] || sources+=("$source")
done
xcrun swiftc -parse-as-library Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift "${sources[@]}" scripts/ScreenshotChecks.swift -o .build/screenshot-checks
.build/screenshot-checks

xcrun swiftc -parse-as-library Sources/ToolCore/ToolFeatures.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/ScreenshotSelection.swift Sources/WallpaperApp/ScreenshotWindow.swift Sources/WallpaperApp/ScreenshotAppearance.swift Sources/WallpaperApp/ScreenshotRecording.swift Sources/WallpaperApp/ScreenshotScroll.swift Sources/WallpaperApp/ScreenshotSession.swift Sources/WallpaperApp/ScreenshotRecordingResult.swift scripts/ScreenshotCursorChecks.swift -o .build/screenshot-cursor-checks
.build/screenshot-cursor-checks

xcrun swiftc -parse-as-library Sources/ToolCore/ToolFeatures.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/ScreenshotSelection.swift Sources/WallpaperApp/ScreenshotWindow.swift Sources/WallpaperApp/ScreenshotAppearance.swift Sources/WallpaperApp/ScreenshotRecording.swift Sources/WallpaperApp/ScreenshotScroll.swift Sources/WallpaperApp/ScreenshotSession.swift Sources/WallpaperApp/ScreenshotRecordingResult.swift scripts/ScreenshotAnnotationChecks.swift -o .build/screenshot-annotation-checks
.build/screenshot-annotation-checks

xcrun swiftc -parse-as-library Sources/ToolCore/ToolFeatures.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/ScreenshotSelection.swift Sources/WallpaperApp/ScreenshotWindow.swift Sources/WallpaperApp/ScreenshotAppearance.swift Sources/WallpaperApp/ScreenshotRecording.swift Sources/WallpaperApp/ScreenshotScroll.swift Sources/WallpaperApp/ScreenshotSession.swift Sources/WallpaperApp/ScreenshotRecordingResult.swift scripts/ScreenshotExtrasChecks.swift -o .build/screenshot-extras-checks
.build/screenshot-extras-checks
