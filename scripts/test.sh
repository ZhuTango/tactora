#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift Tests/*.swift -o .build/checks
.build/checks "$@"
