#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-dashboard-tests.XXXXXX)}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
swift build --disable-sandbox --triple "$TARGET_TRIPLE" --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"
TASK_PRODUCTS="$TEST_PRODUCTS"
TASK_SYSTEM_OBJECTS=("$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o)
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" -I "$TASK_PRODUCTS/Modules")
"${TASK_SWIFTC[@]}" "${TASK_SYSTEM_OBJECTS[@]}" Sources/TouchBarLearning/PerformanceDashboard.swift Tests/DashboardCheck.swift -o "$TASK_BUILD_DIR/DashboardCheck"
"$TASK_BUILD_DIR/DashboardCheck"
"${TASK_SWIFTC[@]}" -D DASHBOARD_TESTING "${TASK_SYSTEM_OBJECTS[@]}" "$TASK_PRODUCTS"/FanControlCore.build/*.swift.o "$TASK_PRODUCTS"/FanHardware.build/*.swift.o Sources/TouchBarLearning/*.swift Tests/TouchBarPageCheck.swift -o "$TASK_BUILD_DIR/TouchBarPageCheck"
"$TASK_BUILD_DIR/TouchBarPageCheck"
