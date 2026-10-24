#!/bin/zsh
# 自动重试与调试端口模块的单元测试。
# 纯 JS 逻辑，不启动 WorkBuddy、不连端口、不读写真实用户状态。
set -euo pipefail
SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"

NODE_BIN=""
for candidate in /usr/local/bin/node /opt/homebrew/bin/node "$HOME/.local/bin/node"; do
    [[ -x "$candidate" ]] && { NODE_BIN="$candidate"; break }
done
if [[ -z "$NODE_BIN" ]]; then
    NODE_BIN="$(command -v node 2>/dev/null || true)"
fi
if [[ -z "$NODE_BIN" ]]; then
    print -u2 "需要 Node.js 22 或更新版本（/usr/local/bin/node、/opt/homebrew/bin/node、~/.local/bin/node）"
    exit 2
fi

version="$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')"
if (( version < 22 )); then
    print -u2 "Node.js 版本过低：$("$NODE_BIN" -v)，需要 22+"
    exit 2
fi

print "Node $("$NODE_BIN" -v)：运行重试策略、会话绑定、操作状态机与端口选择测试"
"$NODE_BIN" --test Tests/background-policy.test.mjs \
    Tests/background-session.test.mjs \
    Tests/legacy-owner.test.mjs \
    Tests/monitor-actions.test.mjs \
    Tests/cdp-port.test.mjs
