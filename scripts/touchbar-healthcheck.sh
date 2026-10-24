#!/bin/zsh

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${APP_DIR:-/Applications/goodtouchbar.app}"
HEALTH_FILE="${HOME}/Library/Application Support/GoodTouchBar/health.json"
MODE="all"
failures=0
global_presented="unknown"

case "${1:-}" in
    ""|--all) MODE="all" ;;
    --build) MODE="build" ;;
    --runtime) MODE="runtime" ;;
    *)
        print -u2 "用法：$0 [--build|--runtime|--all]"
        exit 2
        ;;
esac

pass() { print "PASS: $*"; }
warn() { print "WARN: $*"; }
fail() { print "FAIL: $*"; failures=$((failures + 1)); }

app_process_running() {
    if pgrep -x "GoodTouchBar" >/dev/null 2>&1; then
        return 0
    fi

    launchctl print "gui/$(id -u)/io.github.yihuirui.goodtouchbar" 2>/dev/null \
        | grep -q "state = running"
}

if [[ "$MODE" == "all" || "$MODE" == "build" ]]; then
    if [[ -x "$ROOT_DIR/scripts/validate-build.sh" ]]; then
        if "$ROOT_DIR/scripts/validate-build.sh" "$APP_DIR"; then
            pass "构建产物可用"
        else
            fail "构建产物校验失败"
        fi
    else
        fail "找不到构建校验脚本"
    fi
fi

if [[ "$MODE" == "all" || "$MODE" == "runtime" ]]; then
    if app_process_running; then
        pass "GoodTouchBar 进程正在运行"
    else
        fail "GoodTouchBar 进程未运行"
    fi

    if pgrep -x "TouchBarServer" >/dev/null 2>&1; then
        pass "系统 TouchBarServer 正常"
    else
        warn "未检测到 TouchBarServer，可能是当前机器没有 Touch Bar 或系统服务尚未启动"
    fi

    if [[ -f "$HEALTH_FILE" ]]; then
        health_status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HEALTH_FILE" | head -1)
        health_mtime=$(stat -f %m "$HEALTH_FILE" 2>/dev/null || print 0)
        now=$(date +%s)
        health_age=$((now - health_mtime))

        if [[ "$health_status" == "healthy" && "$health_age" -le 45 ]]; then
            pass "健康报告新鲜且状态为 healthy（${health_age}s）"
        elif [[ "$health_status" == "waiting" && "$health_age" -le 45 ]]; then
            warn "健康报告显示 waiting（${health_age}s），Touch Bar 控件或实验全局模式仍在初始化"
        else
            fail "健康报告异常：status=${health_status:-unknown}, age=${health_age}s"
        fi

        health_schema=$(sed -n 's/.*"schemaVersion"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        pomodoro_phase=$(sed -n 's/.*"pomodoroPhase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HEALTH_FILE" | head -1)
        pomodoro_count=$(sed -n 's/.*"pomodoroCompletedToday"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        codex_status=$(sed -n 's/.*"codexStatus"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HEALTH_FILE" | head -1)
        quota_remaining=$(sed -n 's/.*"quotaRemainingPercent"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        quota_minimum=$(sed -n 's/.*"quotaMinimumRemainingPercent"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        workbuddy_status=$(sed -n 's/.*"workbuddyStatus"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HEALTH_FILE" | head -1)
        today_tokens=$(sed -n 's/.*"todayTokens"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        token_stale=$(sed -n 's/.*"todayTokensStale"[[:space:]]*:[[:space:]]*//p' "$HEALTH_FILE" | sed 's/[[:space:],].*//' | head -1)
        layout_mode=$(sed -n 's/.*"touchBarLayoutMode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HEALTH_FILE" | head -1)
        layout_visible=$(sed -n 's/.*"touchBarVisibleItemCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        layout_resolved=$(sed -n 's/.*"touchBarResolvedItemCount"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HEALTH_FILE" | head -1)
        global_enabled=$(sed -n 's/.*"globalTouchBarEnabled"[[:space:]]*:[[:space:]]*//p' "$HEALTH_FILE" | sed 's/[[:space:],].*//' | head -1)
        global_supported=$(sed -n 's/.*"globalTouchBarSupported"[[:space:]]*:[[:space:]]*//p' "$HEALTH_FILE" | sed 's/[[:space:],].*//' | head -1)
        global_presented=$(sed -n 's/.*"globalTouchBarPresented"[[:space:]]*:[[:space:]]*//p' "$HEALTH_FILE" | sed 's/[[:space:],].*//' | head -1)
        global_visible=$(sed -n 's/.*"globalTouchBarActuallyVisible"[[:space:]]*:[[:space:]]*//p' "$HEALTH_FILE" | sed 's/[[:space:],].*//' | head -1)
        if [[ "$health_schema" == "4" || "$health_schema" == "5" || "$health_schema" == "6" || "$health_schema" == "7" || "$health_schema" == "8" ]]; then
            pass "功能快照可用：pomodoro=${pomodoro_phase:-unknown}, 今日完成=${pomodoro_count:-0}, codex=${codex_status:-unknown}, quota=${quota_remaining:-unknown}% (min=${quota_minimum:-unknown}%), workbuddy=${workbuddy_status:-unknown}, todayTokens=${today_tokens:-unknown}, tokenStale=${token_stale:-unknown}, layout=${layout_mode:-unknown} ${layout_visible:-?}/${layout_resolved:-?}, globalEnabled=${global_enabled:-unknown}, globalSupported=${global_supported:-unknown}, globalPresented=${global_presented:-unknown}, globalVisible=${global_visible:-unknown}"
        else
            warn "健康报告版本较旧：schemaVersion=${health_schema:-unknown}"
        fi
    else
        fail "找不到健康报告：$HEALTH_FILE"
    fi

    if [[ -d "/Applications/BetterTouchTool.app" ]]; then
        if pgrep -x "BetterTouchTool" >/dev/null 2>&1; then
            warn "BetterTouchTool 正在运行，可能与实验全局 Touch Bar 竞争显示层"
        elif [[ "$global_presented" == "true" ]]; then
            pass "BetterTouchTool 未运行，实验全局 Touch Bar 已独立接管"
        else
            warn "BetterTouchTool 未运行，实验全局 Touch Bar 尚未确认接管"
        fi
    elif [[ "$global_presented" == "true" ]]; then
        pass "未安装 BetterTouchTool，实验全局 Touch Bar 已独立接管"
    else
        warn "未安装 BetterTouchTool"
    fi
fi

if (( failures > 0 )); then
    exit 1
fi
