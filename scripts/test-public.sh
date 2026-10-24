#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
TASK_BUILD_DIR="${TASK_BUILD_DIR:-$(mktemp -d /private/tmp/goodtouchbar-public-tests.XXXXXX)}"
TASK_MODULE_CACHE="${TASK_MODULE_CACHE:-$TASK_BUILD_DIR/test-module-cache}"
case "$TASK_BUILD_DIR" in /private/tmp/*|/private/var/folders/*/T/*) ;; *) print -u2 "测试目录必须位于临时目录：$TASK_BUILD_DIR"; exit 2 ;; esac
mkdir -p "$TASK_MODULE_CACHE"
export TASK_BUILD_DIR TASK_MODULE_CACHE
. "$ROOT/scripts/test-architecture.zsh"

swift build --disable-sandbox --configuration debug --triple "$TARGET_TRIPLE" \
    --scratch-path "$TASK_BUILD_DIR" -Xswiftc -module-cache-path -Xswiftc "$TASK_MODULE_CACHE"
/bin/zsh scripts/test-public-features.sh
/bin/zsh scripts/test-all.sh
print "PASS: goodtouchbar public source test entry completed; no app, service, or hardware operation was started."
