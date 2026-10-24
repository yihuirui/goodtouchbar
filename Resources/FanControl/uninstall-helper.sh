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
HOST_ARM=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || printf unknown)
TRANSLATED=$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || printf unknown)
[ "$HOST_ARM" = 0 ] && [ "$TRANSLATED" = 0 ] || fail "未确认 Intel 原生主机，禁止操作 Intel 风扇辅助服务"
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

[ "$(/usr/bin/id -u)" -eq 0 ] || fail "需要系统管理员授权"
case "$CLIENT_UID" in ''|*[!0-9]*) fail "用户标识无效";; esac
[ "$CLIENT_UID" -gt 0 ] && [ "$(/usr/bin/stat -f %u /dev/console)" = "$CLIENT_UID" ] || fail "请由当前桌面用户卸载"
UNINSTALL_SUCCESS=0
STOPPED=0
cleanup_uninstall() {
    code=$?
    set +e
    trap - EXIT HUP INT TERM
    if [ "$UNINSTALL_SUCCESS" -ne 1 ] && [ "$STOPPED" -eq 1 ] && [ -f "$PLIST" ]; then
        if ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true; fi
    fi
    release_lock
    exit "$code"
}
trap cleanup_uninstall EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
secure_dir /Library
secure_dir /Library/PrivilegedHelperTools
secure_dir /Library/LaunchDaemons
secure_dir '/Library/Application Support'
acquire_lock
if [ -e "$APP_SUPPORT" ]; then secure_dir "$APP_SUPPORT"; fi
if [ -e "$STATE" ]; then secure_dir "$STATE"; fi
secure_file_if_present "$HELPER"; secure_file_if_present "$PLIST"; secure_file_if_present "$POLICY"; secure_file_if_present "$PENDING"
STOPPED=1
stop_service
restore_existing
# Do not remove the recovery executable while any marker remains.
if [ -e "$PENDING" ]; then fail "恢复标记仍存在，保留服务文件供恢复与调查"; fi
/bin/rm -f "$HELPER" "$PLIST" "$POLICY"
/bin/rmdir "$STATE" 2>/dev/null || true
UNINSTALL_SUCCESS=1
printf '%s\n' 'PASS: 已解除本工具接管并卸载控制服务；运行日志保留。'
