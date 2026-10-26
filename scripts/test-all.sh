#!/bin/zsh
# 全量回归：把此前散落、以及从未被任何脚本执行的测试全部串起来。
#
# 串行执行。风扇与传感器那套用例会拉起 python 假传感器，和编译抢 CPU 时会变慢，
# 所以这里不用并行，也不要和 build-app.sh 同时跑。
# （ControlsCheck 里等待传感器样本最多 10 秒并立即检查条件，不依赖固定 sleep。）
set -euo pipefail

SOURCE_ROOT="${0:A:h:h}"
cd "$SOURCE_ROOT"

run() {
    print ""
    print "=== $1 ==="
    shift
    "$@"
}

run "AI 速度解析器（43 项）" /bin/zsh scripts/test-agent-speed.sh
run "监控、显示配置与温度（28 + 迁移 + 22 项）" /bin/zsh scripts/test-monitoring.sh
run "控件与原生设置交互" /bin/zsh scripts/test-controls.sh
run "面板与 Touch Bar 页" /bin/zsh scripts/test-dashboard.sh
run "状态栏详情弹出面板与浅深主题预览" /bin/zsh scripts/test-status-details.sh
run "风扇控制模拟（无真实写入）" /bin/zsh scripts/test-fan-control.sh
run "稳定性与重试状态" /bin/zsh scripts/test-stability.sh
run "重试策略、会话绑定、操作状态机、调试端口" /bin/zsh scripts/test-retry.sh

print ""
print "=== 全部回归通过 ==="
print "真机只读校验需单独运行：/bin/zsh scripts/test-hardware.sh"
