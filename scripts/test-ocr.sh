#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/*.swift scripts/OCRChecks.swift -o .build/ocr-checks
.build/ocr-checks
