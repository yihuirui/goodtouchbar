#!/bin/sh
# Local-build installer: root-owned exact-code policy, no passwords stored.
set -eu
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
LABEL=io.github.yihuirui.goodtouchbar.fan-helper
HELPER=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist
STATE='/Library/Application Support/GoodTouchBar/FanControl'
APP_SUPPORT='/Library/Application Support/GoodTouchBar'
POLICY="$STATE/client-policy.json"
PENDING="$STATE/pending-fans.json"
ROOT_UID=0
LOCK=/Library/PrivilegedHelperTools/.goodtouchbar-fan-install.lock
LOCK_HELD=0
LOCK_ID=''
APP_PATH=${1:-}
CLIENT_UID=${2:-}
fail() { printf '%s\n' "ERROR: $*" >&2; exit 1; }
# Refuse path tricks before elevated filesystem work.
reject_acl() {
    acl_listing=$(/bin/ls -lde "$1" 2>/dev/null) || fail "无法读取 ACL: $1"
    if printf '%s\n' "$acl_listing" | /usr/bin/awk '/^[[:space:]]*[0-9]+:/{found=1} END {exit !found}'; then
        fail "拒绝扩展 ACL: $1"
    fi
}
secure_dir() {
    p=$1
    [ ! -L "$p" ] || fail "拒绝符号链接目录: $p"
    if [ ! -e "$p" ]; then /bin/mkdir -m 700 "$p"; fi
    [ -d "$p" ] || fail "不是目录: $p"
    [ "$(/usr/bin/stat -f %u "$p")" = "$ROOT_UID" ] || fail "目录不是 root 所有: $p"
    mode=$(/usr/bin/stat -f %Lp "$p")
    [ $((0$mode & 0022)) -eq 0 ] || fail "目录可被其他用户修改: $p"
    reject_acl "$p"
}
secure_file_if_present() {
    p=$1
    [ ! -L "$p" ] || fail "拒绝符号链接: $p"
    if [ -e "$p" ]; then
        [ -f "$p" ] && [ "$(/usr/bin/stat -f %u "$p")" = "$ROOT_UID" ] || fail "文件不是 root 普通文件: $p"
        [ "$(/usr/bin/stat -f %l "$p")" = 1 ] || fail "拒绝硬链接文件: $p"
        mode=$(/usr/bin/stat -f %Lp "$p")
        [ $((0$mode & 0022)) -eq 0 ] || fail "文件可被其他用户修改: $p"
        reject_acl "$p"
    fi
}
# Both installers share the same root-only lock. A failed/stale lock is never
# reclaimed automatically: that could race a still-live installer or recovery.
acquire_lock() {
    [ ! -L "$LOCK" ] || fail "安装锁路径为符号链接，请由管理员检查"
    /bin/mkdir -m 700 "$LOCK" 2>/dev/null || fail "已有安装或卸载操作，或遗留安装锁；请待操作结束，遗留锁需由管理员核实后清理"
    LOCK_HELD=1
    LOCK_ID=$(/usr/bin/stat -f '%d:%i' "$LOCK")
    secure_dir "$LOCK"
}
release_lock() {
    if [ "$LOCK_HELD" -eq 1 ]; then
        if [ ! -L "$LOCK" ] && [ "$(/usr/bin/stat -f '%d:%i' "$LOCK" 2>/dev/null)" = "$LOCK_ID" ]; then
            /bin/rmdir "$LOCK" 2>/dev/null || printf '%s\n' '安装锁未能清理，请由管理员检查。' >&2
        else
            printf '%s\n' '安装锁发生变化，未自动删除，请由管理员检查。' >&2
        fi
        LOCK_HELD=0
    fi
}
stop_service() {
    old_pid=$(/bin/launchctl print "system/$LABEL" 2>/dev/null | /usr/bin/awk '/^[[:space:]]*pid =/{print $3; exit}')
    case "$old_pid" in *[!0-9]*) fail "无法确认旧服务进程";; esac
    /bin/launchctl kill SIGTERM "system/$LABEL" 2>/dev/null || true
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        fail "旧服务未能停止，保留原服务和恢复记录"
    fi
    if [ -n "$old_pid" ]; then
        attempts=0
        while /bin/kill -0 "$old_pid" 2>/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 75 ] || fail "旧服务进程仍未退出，已阻止并行恢复与覆盖"
            /bin/sleep 0.2
        done
    fi
}
restore_existing() {
    if [ -x "$HELPER" ]; then
        # Only the owned recovery marker is restored. No arbitrary SMC writes.
        /usr/bin/perl -e 'alarm 15; exec @ARGV' "$HELPER" --restore-and-exit || fail "风扇恢复自动失败，保留现有服务文件，请勿继续卸载或覆盖"
    elif [ -e "$PENDING" ]; then
        fail "恢复标记存在但服务程序缺失，需要先修复服务"
    fi
}

PREFLIGHT=0
if [ "$APP_PATH" = --preflight ]; then
    PREFLIGHT=1; shift; APP_PATH=${1:-}; CLIENT_UID=${2:-}
fi
[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] && [ ! -L "$APP_PATH" ] || fail "应用路径无效"
case "$CLIENT_UID" in ''|*[!0-9]*) fail "用户标识无效";; esac
[ "$CLIENT_UID" -gt 0 ] || fail "不接受 root 作为客户端"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")
[ "$BUNDLE_ID" = io.github.yihuirui.goodtouchbar ] || fail "应用标识不匹配"
SOURCE_HELPER="$APP_PATH/Contents/Library/LaunchServices/$LABEL"
[ -f "$SOURCE_HELPER" ] && [ ! -L "$SOURCE_HELPER" ] && [ -x "$SOURCE_HELPER" ] || fail "控制服务缺失"
/usr/bin/codesign --verify --deep --strict "$APP_PATH" || fail "应用签名验证失败"
/usr/bin/codesign --verify --strict "$SOURCE_HELPER" || fail "控制服务签名验证失败"
HELPER_ID=$(/usr/bin/codesign -dv --verbose=4 "$SOURCE_HELPER" 2>&1 | /usr/bin/awk -F= '/^Identifier=/{print $2}')
[ "$HELPER_ID" = "$LABEL" ] || fail "控制服务标识不匹配"
[ "$(/usr/bin/lipo -archs "$SOURCE_HELPER")" = x86_64 ] || fail "控制服务必须是 x86_64"
SIGNING=$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1)
CDHASH=$(printf '%s\n' "$SIGNING" | /usr/bin/awk -F= '/^CDHash=/{print $2}')
case "$CDHASH" in ''|*[!0-9a-fA-F]*) fail "无法读取程序签名哈希";; esac
[ "${#CDHASH}" -eq 40 ] || fail "签名哈希长度无效"
REQUIREMENT="identifier \"io.github.yihuirui.goodtouchbar\" and cdhash H\"$CDHASH\""
/usr/bin/codesign --verify --strict -R "=$REQUIREMENT" "$APP_PATH" || fail "客户端签名条件无法匹配"
if [ "$PREFLIGHT" -eq 1 ]; then
    printf '%s\n' "PASS: 签名、客户端哈希、服务资源和用户标识预检；未安装系统文件"
    exit 0
fi
HOST_ARM=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || printf unknown)
TRANSLATED=$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || printf unknown)
[ "$HOST_ARM" = 0 ] && [ "$TRANSLATED" = 0 ] || fail "未确认 Intel 原生主机，禁止安装或升级 Intel 风扇辅助服务"
[ "$(/usr/bin/id -u)" -eq 0 ] || fail "需要系统管理员授权"
[ "$(/usr/bin/stat -f %u /dev/console)" = "$CLIENT_UID" ] || fail "请由当前登录的桌面用户安装"
STAGE=''
SUCCESS=0
REPLACED=0
STOPPED=0
OLD_HELPER=0; OLD_POLICY=0; OLD_PLIST=0
cleanup() {
    code=$?
    set +e
    trap - EXIT HUP INT TERM
    if [ "$SUCCESS" -ne 1 ] && [ "$REPLACED" -eq 1 ]; then
        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
        if [ "$OLD_HELPER" -eq 1 ]; then /usr/bin/install -o root -g wheel -m 755 "$STAGE/old-helper" "$HELPER"; else /bin/rm -f "$HELPER"; fi
        if [ "$OLD_POLICY" -eq 1 ]; then /usr/bin/install -o root -g wheel -m 600 "$STAGE/old-policy" "$POLICY"; else /bin/rm -f "$POLICY"; fi
        if [ "$OLD_PLIST" -eq 1 ]; then
            /usr/bin/install -o root -g wheel -m 644 "$STAGE/old-plist" "$PLIST"
            /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true
        else /bin/rm -f "$PLIST"; fi
        printf '%s\n' '安装未完成，已尝试回滚原服务；本次没有接管风扇。' >&2
    fi
    if [ "$SUCCESS" -ne 1 ] && [ "$STOPPED" -eq 1 ] && [ "$OLD_PLIST" -eq 1 ]; then
        if ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
            /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true
        fi
    fi
    [ -z "$STAGE" ] || /bin/rm -rf "$STAGE"
    release_lock
    exit "$code"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
secure_dir /Library
secure_dir /Library/PrivilegedHelperTools
secure_dir /Library/LaunchDaemons
secure_dir '/Library/Application Support'
secure_dir "$APP_SUPPORT"
acquire_lock
secure_dir "$STATE"
/bin/chmod 700 "$STATE"
secure_file_if_present "$HELPER"; secure_file_if_present "$PLIST"; secure_file_if_present "$POLICY"; secure_file_if_present "$PENDING"
reject_acl /private/var/tmp
STAGE=$(/usr/bin/mktemp -d /private/var/tmp/goodtouchbar-fan-install.XXXXXX)
secure_dir "$STAGE"
# Read all install inputs from a private root-owned snapshot after signature verification.
/usr/bin/ditto "$APP_PATH" "$STAGE/goodtouchbar.app"
SNAPSHOT="$STAGE/goodtouchbar.app"
/usr/bin/codesign --verify --deep --strict -R "=$REQUIREMENT" "$SNAPSHOT" || fail "复制后签名不一致"
SOURCE_HELPER="$SNAPSHOT/Contents/Library/LaunchServices/$LABEL"
/usr/bin/codesign --verify --strict "$SOURCE_HELPER" || fail "服务签名无效"
[ "$(/usr/bin/lipo -archs "$SOURCE_HELPER")" = x86_64 ] || fail "服务架构不正确"
[ ! -e "$HELPER" ] || { /bin/cp -p "$HELPER" "$STAGE/old-helper"; OLD_HELPER=1; }
[ ! -e "$POLICY" ] || { /bin/cp -p "$POLICY" "$STAGE/old-policy"; OLD_POLICY=1; }
[ ! -e "$PLIST" ] || { /bin/cp -p "$PLIST" "$STAGE/old-plist"; OLD_PLIST=1; }
STOPPED=1
stop_service
restore_existing
cat > "$STAGE/policy.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>version</key><integer>1</integer>
<key>clientUID</key><integer>$CLIENT_UID</integer>
<key>clientRequirement</key><string>$REQUIREMENT</string>
</dict></plist>
EOF
/usr/bin/plutil -convert json -o "$STAGE/policy.json" "$STAGE/policy.plist"
cat > "$STAGE/launchd.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$HELPER</string></array>
<key>MachServices</key><dict><key>$LABEL</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
<key>ExitTimeOut</key><integer>8</integer>
<key>UserName</key><string>root</string>
<key>GroupName</key><string>wheel</string>
<key>Umask</key><integer>63</integer>
</dict></plist>
EOF
/usr/bin/plutil -lint "$STAGE/launchd.plist" >/dev/null
REPLACED=1
/usr/bin/install -o root -g wheel -m 755 "$SOURCE_HELPER" "$HELPER"
/usr/bin/install -o root -g wheel -m 600 "$STAGE/policy.json" "$POLICY"
/usr/bin/install -o root -g wheel -m 644 "$STAGE/launchd.plist" "$PLIST"
/bin/chmod -N "$HELPER" "$POLICY" "$PLIST"
"$HELPER" --validate-policy || fail "客户端绑定策略校验失败"
/bin/launchctl bootstrap system "$PLIST" || fail "服务启动失败"
/bin/launchctl print "system/$LABEL" >/dev/null || fail "服务注册失败"
SUCCESS=1
printf '%s\n' 'PASS: 风扇控制服务已安装；本工具尚未接管风扇，请回到 App 检查服务状态。'
