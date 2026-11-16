#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/LaunchFixture.app/Contents/MacOS
xcrun swiftc scripts/fixtures/AppLaunchFixture.swift -o .build/LaunchFixture.app/Contents/MacOS/LaunchFixture
python3 - <<'PY'
import plistlib
from pathlib import Path
Path('.build/LaunchFixture.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.tango.tactora.launch-check',
    'CFBundleExecutable': 'LaunchFixture', 'CFBundleName': 'LaunchFixture',
    'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
PY
app_sources=()
for source in Sources/WallpaperApp/*.swift; do
    if [[ "$source" != Sources/WallpaperApp/main.swift ]]; then app_sources+=("$source"); fi
done
xcrun swiftc -parse-as-library Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift "${app_sources[@]}" scripts/AppLaunchChecks.swift -o .build/app-launch-checks
.build/app-launch-checks "$PWD/.build/LaunchFixture.app"
