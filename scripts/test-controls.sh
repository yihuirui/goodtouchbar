#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-controls-tests.XXXXXX)}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
swift build --disable-sandbox --triple "$TARGET_TRIPLE" --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"
TASK_PRODUCTS="$TEST_PRODUCTS"
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" -I "$TASK_PRODUCTS/Modules")
TASK_SYSTEM_OBJECTS=("$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o)
"${TASK_SWIFTC[@]}" "${TASK_SYSTEM_OBJECTS[@]}" Sources/TouchBarLearning/PluginConfiguration.swift Sources/TouchBarLearning/TouchBarPresets.swift Sources/TouchBarLearning/PluginSettingsWindow.swift Sources/TouchBarLearning/SystemMetricsMonitor.swift Sources/TouchBarLearning/PerformanceDashboard.swift Sources/TouchBarLearning/MonitorSettingsWindow.swift Sources/TouchBarLearning/RuntimeConfiguration.swift Tests/ControlsCheck.swift -o "$TASK_BUILD_DIR/ControlsCheck"
"$TASK_BUILD_DIR/ControlsCheck"
"${TASK_SWIFTC[@]}" "${TASK_SYSTEM_OBJECTS[@]}" Sources/TouchBarLearning/PluginConfiguration.swift Sources/TouchBarLearning/TouchBarPresets.swift Sources/TouchBarLearning/PluginSettingsWindow.swift Sources/TouchBarLearning/SystemMetricsMonitor.swift Sources/TouchBarLearning/PerformanceDashboard.swift Sources/TouchBarLearning/MonitorSettingsWindow.swift Sources/TouchBarLearning/RuntimeConfiguration.swift Tests/SettingsInteractionCheck.swift -o "$TASK_BUILD_DIR/SettingsInteractionCheck"
"$TASK_BUILD_DIR/SettingsInteractionCheck"
