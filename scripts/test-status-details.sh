#!/bin/zsh
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d "/private/tmp/goodtouchbar-031-status-details-${TEST_ARCH:-$(/usr/bin/uname -m)}.XXXXXX")}" 
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/module-cache}"
. "$SOURCE_ROOT/scripts/test-architecture.zsh"
mkdir -p "$TASK_MODULE_CACHE"
if [[ "${STATUS_DETAILS_CAPTURE_PREVIEWS:-0}" == "1" ]]; then
    PREVIEW_ROOT="${STATUS_DETAILS_PREVIEW_ROOT:-/private/tmp/goodtouchbar-031-preview}"
    if [[ -z "${STATUS_DETAILS_PREVIEW_DIR:-}" ]]; then
        mkdir -p "$PREVIEW_ROOT"
        STATUS_DETAILS_PREVIEW_DIR="$(/usr/bin/mktemp -d "$PREVIEW_ROOT/$TEST_ARCH.XXXXXX")"
    else
        mkdir -p "$STATUS_DETAILS_PREVIEW_DIR"
    fi
    export STATUS_DETAILS_PREVIEW_DIR STATUS_DETAILS_CAPTURE_PREVIEWS=1
fi
TASK_SWIFTC=(swiftc -parse-as-library -module-cache-path "$TASK_MODULE_CACHE" -target "$TARGET_TRIPLE")
"${TASK_SWIFTC[@]}" \
    Sources/TouchBarLearning/StatusDetailsPopover.swift \
    Tests/StatusDetailsCheck.swift \
    -o "$TASK_BUILD_DIR/StatusDetailsCheck"
"$TASK_BUILD_DIR/StatusDetailsCheck"
