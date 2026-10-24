#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-monitoring-tests.XXXXXX)}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
swift build --disable-sandbox --triple "$TARGET_TRIPLE" --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"
TASK_PRODUCTS="$TEST_PRODUCTS"
TASK_OBJECTS=("$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o)
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" -I "$TASK_PRODUCTS/Modules")
"${TASK_SWIFTC[@]}" "${TASK_OBJECTS[@]}" Tests/MonitoringCheck.swift -o "$TASK_BUILD_DIR/MonitoringCheck"
"$TASK_BUILD_DIR/MonitoringCheck"
"${TASK_SWIFTC[@]}" "${TASK_OBJECTS[@]}" Sources/TouchBarLearning/PluginConfiguration.swift Sources/TouchBarLearning/TouchBarPresets.swift Sources/TouchBarLearning/SystemMetricsMonitor.swift Sources/TouchBarLearning/PerformanceDashboard.swift Sources/TouchBarLearning/MonitorSettingsWindow.swift Sources/TouchBarLearning/RuntimeConfiguration.swift Sources/TouchBarLearning/HealthMonitor.swift Tests/DisplayConfigurationCheck.swift -o "$TASK_BUILD_DIR/DisplayConfigurationCheck"
"$TASK_BUILD_DIR/DisplayConfigurationCheck"
"${TASK_SWIFTC[@]}" "${TASK_OBJECTS[@]}" Tests/CoreTemperatureCheck.swift -o "$TASK_BUILD_DIR/CoreTemperatureCheck"
"$TASK_BUILD_DIR/CoreTemperatureCheck"
"${TASK_SWIFTC[@]}" "${TASK_OBJECTS[@]}" Tests/DeviceCapabilitiesCheck.swift -o "$TASK_BUILD_DIR/DeviceCapabilitiesCheck"
"$TASK_BUILD_DIR/DeviceCapabilitiesCheck"
