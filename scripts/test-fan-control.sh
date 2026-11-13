#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/FanControl.swift Sources/ToolCore/FanSMC.swift Sources/ToolCore/ToolFeatures.swift scripts/FanControlChecks.swift -o .build/fan-control-checks
.build/fan-control-checks
xcrun swiftc -parse-as-library Sources/ToolCore/FanControl.swift scripts/FanEngineChecks.swift -o .build/fan-engine-checks
.build/fan-engine-checks

xcrun swiftc -D FAN_SERVICE_TEST -parse-as-library Sources/ToolCore/{FanControl,FanSMC,FanHelperProtocol}.swift Sources/FanHelper/main.swift scripts/FanServiceChecks.swift -o .build/fan-service-checks
.build/fan-service-checks > .build/fan-service-checks.log
grep -q "Delayed first connection survives" .build/fan-service-checks.log
cat .build/fan-service-checks.log
