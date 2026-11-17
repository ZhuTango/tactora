#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -O -parse-as-library Sources/WallpaperApp/ScreenshotScroll.swift Sources/WallpaperApp/ScreenshotRecording.swift scripts/ScreenshotScrollPerformanceChecks.swift -o .build/screenshot-scroll-performance-checks
.build/screenshot-scroll-performance-checks
