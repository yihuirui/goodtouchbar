import AppKit

@main
@MainActor
struct StatusDetailsPreviewApp {
    private static var windows: [NSWindow] = []
    private static var lifetimeTimer: Timer?

    static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        let previews = [
            makeWindow(
                title: "goodtouchbar Preview · Light · current data",
                appearance: .aqua,
                snapshot: lightSnapshot
            ),
            makeWindow(
                title: "goodtouchbar Preview · Dark · expired quota + long WB status",
                appearance: .darkAqua,
                snapshot: darkSnapshot
            ),
        ]
        windows = previews

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let windowSize = NSSize(width: 416, height: 620)
        let gap: CGFloat = 16
        let left = max(screen.minX, screen.midX - windowSize.width - gap / 2)
        let right = min(screen.maxX - windowSize.width, screen.midX + gap / 2)
        let originY = max(screen.minY, screen.maxY - windowSize.height - 36)
        previews[0].setFrame(NSRect(origin: NSPoint(x: left, y: originY), size: windowSize), display: true)
        previews[1].setFrame(NSRect(origin: NSPoint(x: right, y: originY), size: windowSize), display: true)
        previews.forEach { $0.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)

        lifetimeTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
            NSApp.terminate(nil)
        }
        NSApp.run()
        _ = lifetimeTimer
    }

    private static func makeWindow(
        title: String,
        appearance: NSAppearance.Name,
        snapshot: StatusDetailsSnapshot
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 416, height: 620)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.appearance = NSAppearance(named: appearance)
        window.contentViewController = StatusDetailsViewController(snapshot: snapshot)
        window.minSize = NSSize(width: 416, height: 360)
        window.maxSize = NSSize(width: 416, height: 900)
        return window
    }

    private static var lightSnapshot: StatusDetailsSnapshot {
        StatusDetailsSnapshot(
            modeLabel: "Touch Bar 模式",
            quotaWindows: [
                .init(title: "5 小时", remainingPercent: 68, resetText: "重置于 2 小时后"),
                .init(title: "7 天", remainingPercent: 82, resetText: "重置于 4 天后"),
            ],
            quotaIsStale: false,
            quotaAwaitingReset: false,
            quotaUpdatedText: "更新于刚刚",
            tokenShortText: "12万",
            tokenExactText: "完整值 123,456",
            tokenUpdatedText: "更新于刚刚",
            tokenIsStale: false,
            chatGPT: StatusDetailsPresentation.service(
                name: "ChatGPT", state: "running", sourceTitle: "进行中", detail: "正在生成回答"
            ),
            workBuddy: StatusDetailsPresentation.service(
                name: "WorkBuddy", state: "completed", sourceTitle: "已完成", detail: "最近会话已完成"
            ),
            canStartWorkBuddy: true,
            canUpdateWorkBuddy: true,
            canStopWorkBuddy: true,
            metrics: [
                .init(symbol: "cpu", title: "CPU", value: "24%", accessibilityLabel: "CPU 使用率 24%"),
                .init(symbol: "memorychip", title: "内存", value: "8.1/16 GB", accessibilityLabel: "内存使用 8.1/16 GB"),
                .init(symbol: "thermometer.medium", title: "温度", value: "54°C", accessibilityLabel: "CPU 温度 54°C"),
                .init(symbol: "fan", title: "风扇", value: "1,420 RPM", accessibilityLabel: "风扇转速 1,420 RPM"),
            ],
            fanNote: "风扇只读，只显示已采样转速"
        )
    }

    private static var darkSnapshot: StatusDetailsSnapshot {
        StatusDetailsSnapshot(
            modeLabel: "菜单栏模式",
            quotaWindows: [
                .init(title: "5 小时", remainingPercent: 21, resetText: "重置时间未知，稍后再次获取配额数据"),
                .init(title: "7 天", remainingPercent: nil, resetText: "重置时间未知"),
            ],
            quotaIsStale: true,
            quotaAwaitingReset: false,
            quotaUpdatedText: "更新于 8 天前，数据已超过有效期",
            tokenShortText: "9877万",
            tokenExactText: "完整值 98,765,432",
            tokenUpdatedText: "更新于 8 天前",
            tokenIsStale: true,
            chatGPT: StatusDetailsPresentation.service(
                name: "ChatGPT", state: "future-state", sourceTitle: "未知状态",
                detail: "未来版本状态应显示为未知，而不是误报待命。"
            ),
            workBuddy: StatusDetailsPresentation.service(
                name: "WorkBuddy", state: "stale", sourceTitle: "连接异常",
                detail: String(repeating: "当前监控通道长时间没有收到新心跳；请确认 WorkBuddy 会话状态并手动处理。", count: 2)
            ),
            canStartWorkBuddy: true,
            canUpdateWorkBuddy: true,
            canStopWorkBuddy: true,
            metrics: [],
            fanNote: "风扇状态未知，未采集转速不代表设备没有风扇"
        )
    }
}
