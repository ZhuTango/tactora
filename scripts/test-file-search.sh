#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -O -parse-as-library Sources/ToolCore/QuickActionHighlightIndex.swift Sources/ToolCore/FileSearch.swift scripts/FileSearchChecks.swift -o .build/file-search-checks
.build/file-search-checks
xcrun swiftc -parse-as-library Sources/ToolCore/QuickActionHighlightIndex.swift Sources/ToolCore/FileSearch.swift Sources/WallpaperApp/FileSearchIndex.swift scripts/FileIndexChecks.swift -o .build/file-index-checks
.build/file-index-checks
