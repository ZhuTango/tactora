#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun swiftc -parse-as-library Sources/ToolCore/QuickCurrency.swift scripts/CurrencyChecks.swift -o .build/currency-checks
.build/currency-checks
xcrun swiftc -parse-as-library Sources/ToolCore/QuickCalculator.swift scripts/QuickCalculatorChecks.swift -o .build/calculator-checks
.build/calculator-checks
xcrun swiftc -parse-as-library Sources/ToolCore/AppSearchIndex.swift Sources/ToolCore/QuickActionHighlightIndex.swift Sources/ToolCore/QuickActions.swift scripts/QuickActionChecks.swift -o .build/quick-action-checks
.build/quick-action-checks
app_sources=()
for source in Sources/WallpaperApp/*.swift; do
    if [[ "$source" != Sources/WallpaperApp/main.swift ]]; then app_sources+=("$source"); fi
done
xcrun swiftc -parse-as-library Sources/WallpaperCore/*.swift Sources/ToolCore/*.swift "${app_sources[@]}" scripts/QuickActionUIChecks.swift -o .build/quick-action-ui-checks
.build/quick-action-ui-checks
