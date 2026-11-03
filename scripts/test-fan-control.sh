#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/FanControl.swift Sources/ToolCore/FanSMC.swift Sources/ToolCore/ToolFeatures.swift scripts/FanControlChecks.swift -o .build/fan-control-checks
.build/fan-control-checks
xcrun swiftc -parse-as-library Sources/ToolCore/FanControl.swift scripts/FanEngineChecks.swift -o .build/fan-engine-checks
.build/fan-engine-checks
