#!/bin/zsh
# Opt-in read-only check: reads Mach metrics, thermal zones and fan RPM only.
set -euo pipefail
umask 077
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
if (( EUID == 0 )); then print -u2 "请用普通用户运行，不要 sudo。"; exit 2; fi
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-hardware-tests.XXXXXX)}"
TASK_BUILD_DIR="${TASK_BUILD_DIR:A}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
mkdir -p "$TASK_BUILD_DIR" "$TASK_MODULE_CACHE"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
swift build --disable-sandbox --configuration debug --triple "$TARGET_TRIPLE" --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"
TASK_PRODUCTS="$TEST_PRODUCTS"
TASK_SYSTEM_OBJECTS=("$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o)
TASK_CORE_OBJECTS=("$TASK_PRODUCTS"/FanControlCore.build/*.swift.o)
TASK_HARDWARE_OBJECTS=("$TASK_PRODUCTS"/FanHardware.build/*.swift.o)
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE" -I "$TASK_PRODUCTS/Modules")

HOST_ARM=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || print unknown)
TRANSLATED=$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || print unknown)
if [[ "$TEST_ARCH" == x86_64 && "$HOST_ARM" == 0 && "$TRANSLATED" == 0 ]]; then
    print "Intel 原生环境：执行只读风扇硬件探测"
    "${TASK_SWIFTC[@]}" "${TASK_CORE_OBJECTS[@]}" "${TASK_SYSTEM_OBJECTS[@]}" "${TASK_HARDWARE_OBJECTS[@]}" Tests/FanReadOnlyCheck.swift -o "$TASK_BUILD_DIR/FanReadOnlyCheck"
    "$TASK_BUILD_DIR/FanReadOnlyCheck"
else
    print "未确认 Intel 原生环境：跳过 Intel 风扇控制硬件读取；不连接 helper、不写入风扇"
fi

SENSOR_BINARY="$TASK_PRODUCTS/GoodTouchSensors"
[[ -x "$SENSOR_BINARY" ]] || { print -u2 "缺少传感器程序：$SENSOR_BINARY"; exit 1; }
"${TASK_SWIFTC[@]}" "${TASK_SYSTEM_OBJECTS[@]}" Tests/SensorReadOnlyCheck.swift -o "$TASK_BUILD_DIR/SensorReadOnlyCheck"
"$TASK_BUILD_DIR/SensorReadOnlyCheck" "$SENSOR_BINARY"
print "真机只读校验通过。临时输出：$TASK_BUILD_DIR"
