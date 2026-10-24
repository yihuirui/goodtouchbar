#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="/Applications/goodtouchbar.app"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/GoodTouchBar"
LABEL="io.github.yihuirui.goodtouchbar"
USER_HOME="${HOME}"
AGENT_DIR="$USER_HOME/Library/LaunchAgents"
LOG_DIR="$USER_HOME/Library/Logs/GoodTouchBar"
AGENT_PATH="$AGENT_DIR/$LABEL.plist"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
    print -u2 "找不到已部署的应用：$APP_BUNDLE"
    print -u2 "请先把对应版本部署到 /Applications/goodtouchbar.app"
    exit 1
fi

mkdir -p "$AGENT_DIR" "$LOG_DIR"
[[ -d "$AGENT_DIR" && ! -L "$AGENT_DIR" ]] || { print -u2 "启动项目录不安全：$AGENT_DIR"; exit 1; }
[[ -d "$LOG_DIR" && ! -L "$LOG_DIR" ]] || { print -u2 "日志目录不安全：$LOG_DIR"; exit 1; }
if [[ -e "$AGENT_PATH" || -L "$AGENT_PATH" ]]; then
    [[ -f "$AGENT_PATH" && ! -L "$AGENT_PATH" ]] || { print -u2 "拒绝非普通启动项文件：$AGENT_PATH"; exit 1; }
    /usr/bin/plutil -lint "$AGENT_PATH" >/dev/null
    EXISTING_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$AGENT_PATH")
    EXISTING_PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$AGENT_PATH")
    [[ "$EXISTING_LABEL" == "$LABEL" && "$EXISTING_PROGRAM" == "$APP_EXECUTABLE" ]] || {
        print -u2 "已有启动项不属于 goodtouchbar，未覆盖它。"
        exit 1
    }
fi
AGENT_TEMP=$(mktemp "$AGENT_DIR/.goodtouchbar-launchagent.XXXXXX")
cleanup() { [[ -z "${AGENT_TEMP:-}" ]] || rm -f "$AGENT_TEMP"; }
trap cleanup EXIT HUP INT TERM

cat > "$AGENT_TEMP" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_EXECUTABLE</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/stderr.log</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$AGENT_TEMP" >/dev/null
chmod 600 "$AGENT_TEMP"
mv -f "$AGENT_TEMP" "$AGENT_PATH"
AGENT_TEMP=""
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT_PATH"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

print "已安装并启动：$AGENT_PATH"
print "应用崩溃时 launchd 会自动重启；从菜单正常退出不会被强制拉回。"
