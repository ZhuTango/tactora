#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/TextProcessing.swift Sources/ToolCore/TextWorkbench.swift scripts/TextWorkbenchChecks.swift -o .build/text-workbench-checks
.build/text-workbench-checks
