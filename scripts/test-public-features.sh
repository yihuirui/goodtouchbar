#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:?set TASK_BUILD_DIR to a temporary directory}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
mkdir -p "$TASK_MODULE_CACHE"
. "$ROOT/scripts/test-architecture.zsh"
PRODUCTS="$TEST_PRODUCTS"

swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" \
    -I "$PRODUCTS/Modules" "$PRODUCTS"/SystemMonitoring.build/*.swift.o \
    Sources/TouchBarLearning/PluginConfiguration.swift \
    Sources/TouchBarLearning/TouchBarPresets.swift \
    Sources/TouchBarLearning/RuntimeConfiguration.swift \
    Sources/TouchBarLearning/SystemControls.swift \
    Tests/PresetsCheck.swift -o "$TASK_BUILD_DIR/PresetsCheck"
"$TASK_BUILD_DIR/PresetsCheck"
