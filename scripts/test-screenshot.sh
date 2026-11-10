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

xcrun swiftc -parse-as-library Sources/ToolCore/ToolFeatures.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/ScreenshotSelection.swift Sources/WallpaperApp/ScreenshotWindow.swift scripts/ScreenshotCursorChecks.swift -o .build/screenshot-cursor-checks
.build/screenshot-cursor-checks

xcrun swiftc -parse-as-library Sources/ToolCore/ToolFeatures.swift Sources/WallpaperApp/AppLanguage.swift Sources/WallpaperApp/ScreenshotSelection.swift Sources/WallpaperApp/ScreenshotWindow.swift scripts/ScreenshotAnnotationChecks.swift -o .build/screenshot-annotation-checks
.build/screenshot-annotation-checks
