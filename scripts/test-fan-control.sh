#!/bin/zsh
# Safe simulation suite: no root installation, system Mach service or SMC access.
# Override TASK_BUILD_DIR to reuse a Debug build and TASK_MODULE_CACHE to reuse
# a compiler cache. Both paths must stay in a macOS temporary directory.
set -euo pipefail
umask 077

SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"

if (( EUID == 0 )); then
    print -u2 "Run these fixture checks as your normal user, without sudo."
    exit 2
fi

require_temporary_path() {
    case "$1" in
        /private/tmp/*|/private/var/folders/*/T/*) ;;
        *) print -u2 "Test output must be under a temporary directory: $1"; exit 2 ;;
    esac
}

TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-fan-control-tests.XXXXXX)}"
TASK_BUILD_DIR="${TASK_BUILD_DIR:A}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:A}"
require_temporary_path "$TASK_BUILD_DIR"
require_temporary_path "$TASK_MODULE_CACHE"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
TASK_TEST_DIR="$TASK_BUILD_DIR/fan-control-checks"
mkdir -p "$TASK_TEST_DIR" "$TASK_MODULE_CACHE"

print "Building Debug products; this does not run or install the helper."
swift build --disable-sandbox --configuration debug \
    --triple "$TARGET_TRIPLE" --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"

TASK_PRODUCTS="$TEST_PRODUCTS"
TASK_CORE_OBJECTS=("$TASK_PRODUCTS"/FanControlCore.build/*.swift.o)
TASK_SYSTEM_OBJECTS=("$TASK_PRODUCTS"/SystemMonitoring.build/*.swift.o)
TASK_HARDWARE_OBJECTS=("$TASK_PRODUCTS"/FanHardware.build/*.swift.o)
TASK_LIBRARY_OBJECTS=("${TASK_CORE_OBJECTS[@]}" "${TASK_SYSTEM_OBJECTS[@]}" "${TASK_HARDWARE_OBJECTS[@]}")
TASK_SECURITY_SOURCES=(Sources/GoodTouchFanHelper/ClientPolicy.swift Sources/GoodTouchFanHelper/SecureStorage.swift)
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" \
    -target "$TARGET_TRIPLE" -I "$TASK_PRODUCTS/Modules")

print "Running 35 Core state-machine checks with fake hardware."
"${TASK_SWIFTC[@]}" "${TASK_CORE_OBJECTS[@]}" Tests/FanControlCheck.swift \
    -o "$TASK_TEST_DIR/FanControlCheck"
"$TASK_TEST_DIR/FanControlCheck"

print "Running 18 pure hardware encoding checks."
"${TASK_SWIFTC[@]}" "${TASK_LIBRARY_OBJECTS[@]}" Tests/FanHardwareCheck.swift \
    -o "$TASK_TEST_DIR/FanHardwareCheck"
"$TASK_TEST_DIR/FanHardwareCheck"

print "Running 12 security policy and temporary-file checks."
"${TASK_SWIFTC[@]}" "${TASK_LIBRARY_OBJECTS[@]}" "${TASK_SECURITY_SOURCES[@]}" \
    Tests/FanSecurityCheck.swift -o "$TASK_TEST_DIR/FanSecurityCheck"
"$TASK_TEST_DIR/FanSecurityCheck"

print "Running log metadata and temporary-file ACL checks."
"${TASK_SWIFTC[@]}" "${TASK_LIBRARY_OBJECTS[@]}" "${TASK_SECURITY_SOURCES[@]}" \
    Sources/GoodTouchFanHelper/FanEventLog.swift Tests/FanLogCheck.swift \
    -o "$TASK_TEST_DIR/FanLogCheck"
"$TASK_TEST_DIR/FanLogCheck"

print "Running 20 client/window checks with injected transport and installer."
"${TASK_SWIFTC[@]}" "${TASK_LIBRARY_OBJECTS[@]}" \
    Sources/TouchBarLearning/FanControlClient.swift Sources/TouchBarLearning/FanControlWindow.swift \
    Tests/FanUIClientCheck.swift -o "$TASK_TEST_DIR/FanUIClientCheck"
"$TASK_TEST_DIR/FanUIClientCheck"

print "Running 47 native input editing checks with held fake RPCs and a hidden window."
"${TASK_SWIFTC[@]}" "${TASK_LIBRARY_OBJECTS[@]}" \
    Sources/TouchBarLearning/FanControlClient.swift Sources/TouchBarLearning/FanControlWindow.swift \
    Tests/FanInputEditingCheck.swift -o "$TASK_TEST_DIR/FanInputEditingCheck"
"$TASK_TEST_DIR/FanInputEditingCheck"

print "Running anonymous XPC roundtrips with fake hardware and exact-code authentication."
"${TASK_SWIFTC[@]}" "${TASK_LIBRARY_OBJECTS[@]}" "${TASK_SECURITY_SOURCES[@]}" \
    Tests/FanXPCCheck.swift -o "$TASK_TEST_DIR/FanXPCCheck"
# Hardened runtime makes audit-token code validation exercise the same code path
# as the packaged App. This signs only the temporary test binary.
/usr/bin/codesign --force --options runtime --identifier io.github.yihuirui.goodtouchbar \
    --sign - "$TASK_TEST_DIR/FanXPCCheck"
"$TASK_TEST_DIR/FanXPCCheck"

print "Running 28 installer fixture checks; no --app or installation operation is used."
python3 Tests/InstallerCheck.py

# FanReadOnlyCheck is intentionally outside this simulation suite.
print "All fan-control simulation checks passed. Temporary outputs: $TASK_TEST_DIR"
