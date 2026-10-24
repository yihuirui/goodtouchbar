#!/bin/zsh
set -euo pipefail

LABEL="io.github.yihuirui.goodtouchbar"
AGENT_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
if [[ ! -e "$AGENT_PATH" ]]; then
    print "GoodTouchBar 启动项不存在：$AGENT_PATH"
    exit 0
fi
[[ -f "$AGENT_PATH" && ! -L "$AGENT_PATH" ]] || { print -u2 "拒绝非普通启动项文件：$AGENT_PATH"; exit 1; }
/usr/bin/plutil -lint "$AGENT_PATH" >/dev/null
FOUND_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PATH")
PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT_PATH")
[[ "$FOUND_LABEL" == "$LABEL" && "$PROGRAM" == "/Applications/goodtouchbar.app/Contents/MacOS/GoodTouchBar" ]] || {
    print -u2 "启动项内容不匹配，未停止服务或删除文件。"
    exit 1
}
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm "$AGENT_PATH"
print "已移除 goodtouchbar 启动项；用户数据和日志已保留。"
