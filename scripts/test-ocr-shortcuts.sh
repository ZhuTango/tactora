#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift scripts/OCRShortcutChecks.swift -o .build/ocr-shortcut-checks
.build/ocr-shortcut-checks "$@"
