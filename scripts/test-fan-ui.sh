#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/{FanControl,FanSMC,FanHelperProtocol,ToolFeatures}.swift Sources/WallpaperApp/{AppLanguage,FanControlManager,FanSettingsView}.swift scripts/FanUIChecks.swift -o .build/fan-ui-checks
.build/fan-ui-checks
xcrun swiftc -parse-as-library Sources/ToolCore/{FanControl,FanSMC,FanHelperProtocol,ToolFeatures}.swift Sources/WallpaperApp/FanControlManager.swift scripts/FanRegistrationChecks.swift -o .build/fan-registration-checks
.build/fan-registration-checks
