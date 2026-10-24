#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-agent-speed-tests.XXXXXX)}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
mkdir -p "$TASK_BUILD_DIR"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
# 解析器自成一体，不依赖其它监控模块，可以单独编译。
swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" \
	Sources/TouchBarLearning/AgentSpeedMonitor.swift \
	Tests/AgentSpeedCheck.swift \
	-o "$TASK_BUILD_DIR/AgentSpeedCheck"
"$TASK_BUILD_DIR/AgentSpeedCheck"
