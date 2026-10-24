#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-stability-tests.XXXXXX)}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
TASK_PRODUCTS="$TEST_PRODUCTS"
swift build --disable-sandbox --triple "$TARGET_TRIPLE" --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" -I "$TASK_PRODUCTS/Modules")
"${TASK_SWIFTC[@]}" Sources/TouchBarLearning/AgentSpeedMonitor.swift Tests/AgentSpeedCheck.swift -o "$TASK_BUILD_DIR/AgentSpeedCheck"
"$TASK_BUILD_DIR/AgentSpeedCheck"
"${TASK_SWIFTC[@]}" "$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o Sources/TouchBarLearning/PluginConfiguration.swift Sources/TouchBarLearning/TouchBarPresets.swift Sources/TouchBarLearning/SystemMetricsMonitor.swift Sources/TouchBarLearning/PerformanceDashboard.swift Sources/TouchBarLearning/MonitorSettingsWindow.swift Sources/TouchBarLearning/RuntimeConfiguration.swift Sources/TouchBarLearning/HealthMonitor.swift Tests/DisplayConfigurationCheck.swift -o "$TASK_BUILD_DIR/DisplayConfigurationCheck"
"$TASK_BUILD_DIR/DisplayConfigurationCheck"
"${TASK_SWIFTC[@]}" "$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o "$TASK_PRODUCTS"/FanControlCore.build/*.swift.o "$TASK_PRODUCTS"/FanHardware.build/*.swift.o Tests/StabilityProcessCheck.swift -o "$TASK_BUILD_DIR/StabilityProcessCheck"
"$TASK_BUILD_DIR/StabilityProcessCheck"
"${TASK_SWIFTC[@]}" "$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o Sources/TouchBarLearning/UsageMonitors.swift Sources/TouchBarLearning/AgentSpeedMonitor.swift Sources/TouchBarLearning/WorkBuddyRetryMonitor.swift Sources/TouchBarLearning/CodexActivityMonitor.swift Tests/StabilityMonitorCheck.swift -o "$TASK_BUILD_DIR/StabilityMonitorCheck"
"$TASK_BUILD_DIR/StabilityMonitorCheck"
node --test Tests/*.test.mjs
