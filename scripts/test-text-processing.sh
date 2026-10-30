#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/TextProcessing.swift scripts/TextProcessingChecks.swift -o .build/text-processing-checks
.build/text-processing-checks
