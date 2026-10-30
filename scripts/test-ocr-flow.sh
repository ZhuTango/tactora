#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
sources=()
for source in Sources/WallpaperApp/*.swift; do
    [[ "$source" == */main.swift ]] || sources+=("$source")
done
xcrun swiftc -parse-as-library Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift "${sources[@]}" scripts/OCRFlowChecks.swift -o .build/ocr-flow-checks
.build/ocr-flow-checks
