#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/KeyboardControl.swift Sources/ToolCore/ToolFeatures.swift scripts/KeyboardTestSupport.swift scripts/KeyboardChecks.swift -o .build/keyboard-checks
.build/keyboard-checks
