import AppKit

@main
@MainActor
struct StatusDetailsCheck {
    private static var failures = 0

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        check(StatusDetailsPresentation.quotaPercent(68) == 68, "quota progress follows remaining percentage")
        check(StatusDetailsPresentation.quotaPercent(140) == 100, "quota percentage is clamped")
        check(StatusDetailsPresentation.quotaText(nil, stale: true) == "暂无数据", "missing quota is not shown as zero or stale data")
        check(StatusDetailsPresentation.quotaText(24, stale: true).contains("已过期"), "stale quota is explicitly marked")
        check(StatusDetailsPresentation.quotaText(nil, stale: false, awaitingReset: true) == "额度待更新", "expired windows are waiting for new quota data")
        check(StatusDetailsPresentation.quotaText(68, stale: false).contains("剩余 68%"), "quota card identifies its value as remaining")
        check(StatusDetailsPresentation.quotaPrimaryText(68, stale: false) == "剩余 68%", "fresh quota uses a large remaining value")
        check(StatusDetailsPresentation.quotaPrimaryText(21, stale: true) == "21%", "stale quota value stays concise")
        check(StatusDetailsPresentation.quotaSecondaryText(21, stale: true, awaitingReset: false).contains("已过期"), "stale quota has a historical label")
        check(StatusDetailsPresentation.quotaSecondaryText(nil, stale: false, awaitingReset: true) == "额度待更新", "missing reset data has a neutral label")
        check(StatusDetailsPresentation.shortTokenText(123_456) == "12万", "short token value is readable")
        check(StatusDetailsPresentation.exactTokenText(123_456).filter(\.isNumber) == "123456", "full token value is available")

        let idle = StatusDetailsPresentation.service(name: "WorkBuddy", state: "idle", sourceTitle: "未监控", detail: "")
        let stopped = StatusDetailsPresentation.service(name: "WorkBuddy", state: "idle", sourceTitle: "监控停止", detail: "")
        let running = StatusDetailsPresentation.service(name: "ChatGPT", state: "running", sourceTitle: "执行中", detail: "生成回答")
        let stale = StatusDetailsPresentation.service(name: "WorkBuddy", state: "stale", sourceTitle: "连接异常", detail: "长文本测试")
        let crowded = StatusDetailsPresentation.service(name: "WorkBuddy", state: "waiting", sourceTitle: "模型拥堵", detail: "等待重试")
        check(idle.state == "未监控", "unmonitored is distinct from idle")
        check(stopped.state == "已停止", "stopped is distinct from unmonitored")
        check(running.state == "进行中", "running maps to the public status")
        check(stale.state == "连接异常", "lost connection maps to an explicit status")
        check(crowded.state == "模型拥堵", "model congestion is visible")
        let unknown = StatusDetailsPresentation.service(name: "WorkBuddy", state: "future-state", sourceTitle: "未知", detail: "")
        check(unknown.state == "状态未知", "unrecognized activity states are not reported as idle")

        check(!StatusDetailsPresentation.canPerformWorkBuddyAction("start", state: "running", title: "进行中", commandInFlight: false), "start disabled while work is running")
        check(!StatusDetailsPresentation.canPerformWorkBuddyAction("start", state: "waiting", title: "模型拥堵", commandInFlight: false), "start disabled while a monitor is waiting")
        check(StatusDetailsPresentation.canPerformWorkBuddyAction("update", state: "stale", title: "连接异常", commandInFlight: false), "update available after a lost connection")
        check(!StatusDetailsPresentation.canPerformWorkBuddyAction("stop", state: "idle", title: "未监控", commandInFlight: false), "stop disabled before monitoring starts")
        check(!StatusDetailsPresentation.canPerformWorkBuddyAction("update", state: "running", title: "进行中", commandInFlight: true), "all commands disabled during an operation")
        check(!StatusDetailsPresentation.canPerformWorkBuddyAction("start", state: "future-state", title: "未知", commandInFlight: false), "unknown state does not enable start")
        check(StatusDetailsPopoverController.isEscapeKeyCode(53), "Escape key is recognized")
        check(!StatusDetailsPopoverController.isEscapeKeyCode(36), "other keys do not dismiss the popover")

        let light = healthyFixture()
        let dark = longUnknownFixture()
        verifyViewAndActions(light)
        verifyViewAndActions(dark)
        verifyViewAndActions(unmonitoredFixture())
        verifyViewAndActions(awaitingResetFixture())
        if ProcessInfo.processInfo.environment["STATUS_DETAILS_CAPTURE_PREVIEWS"] == "1" {
            render(light, appearance: .aqua, name: "status-details-light-healthy.png")
            render(dark, appearance: .darkAqua, name: "status-details-dark-long-unknown.png")
            render(unmonitoredFixture(), appearance: .aqua, name: "status-details-light-unmonitored.png")
            render(awaitingResetFixture(), appearance: .darkAqua, name: "status-details-dark-awaiting-reset.png")
        } else {
            print("SKIP: AppKit hierarchy PNG previews require STATUS_DETAILS_CAPTURE_PREVIEWS=1")
        }

        if failures > 0 {
            fputs("FAIL: \(failures) status details checks failed\n", stderr)
            exit(1)
        }
        print("PASS: quota freshness/progress, token display, activity mapping, WB action policy, Escape, and accessibility routes")
    }

    private static func healthyFixture() -> StatusDetailsSnapshot {
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
            tokenExactText: "精确计数 123,456",
            tokenUpdatedText: "更新于刚刚",
            tokenIsStale: false,
            chatGPT: StatusDetailsPresentation.service(name: "ChatGPT", state: "running", sourceTitle: "进行中", detail: "正在生成回答"),
            workBuddy: StatusDetailsPresentation.service(name: "WorkBuddy", state: "completed", sourceTitle: "已完成", detail: "最近会话已完成"),
            canStartWorkBuddy: true,
            canUpdateWorkBuddy: true,
            canStopWorkBuddy: true,
            metrics: [
                .init(symbol: "cpu", title: "CPU", value: "24%", accessibilityLabel: "CPU 使用率 24%"),
                .init(symbol: "memorychip", title: "内存", value: "8.1/16 GB", accessibilityLabel: "内存使用 8.1/16 GB"),
                .init(symbol: "thermometer.medium", title: "温度", value: "54°C", accessibilityLabel: "CPU 温度 54°C"),
                .init(symbol: "fan", title: "风扇", value: "1,420 RPM", accessibilityLabel: "风扇转速 1,420 RPM"),
            ],
            fanNote: "风扇只读 · 只显示已采样转速"
        )
    }

    private static func longUnknownFixture() -> StatusDetailsSnapshot {
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
            tokenExactText: "精确计数 98,765,432 · 长数字仍独立显示",
            tokenUpdatedText: "更新于 8 天前",
            tokenIsStale: true,
            chatGPT: StatusDetailsPresentation.service(
                name: "ChatGPT", state: "error", sourceTitle: "读取失败",
                detail: String(repeating: "状态详情最多显示两行，完整文本保留为提示。", count: 3)
            ),
            workBuddy: StatusDetailsPresentation.service(
                name: "WorkBuddy", state: "stale", sourceTitle: "连接异常",
                detail: String(repeating: "当前监控通道无新心跳；请检查 WorkBuddy 是否仍在运行。", count: 3)
            ),
            canStartWorkBuddy: true,
            canUpdateWorkBuddy: true,
            canStopWorkBuddy: true,
            metrics: [],
            fanNote: "风扇只读 · 未采集读数时保持未知，不推断设备有无风扇"
        )
    }

    private static func unmonitoredFixture() -> StatusDetailsSnapshot {
        StatusDetailsSnapshot(
            modeLabel: "菜单栏模式",
            quotaWindows: [
                .init(title: "5 小时", remainingPercent: nil, resetText: "重置时间未知"),
                .init(title: "7 天", remainingPercent: nil, resetText: "重置时间未知"),
            ],
            quotaIsStale: false,
            quotaAwaitingReset: false,
            quotaUpdatedText: "暂未获取数据",
            tokenShortText: "--",
            tokenExactText: "暂无精确计数",
            tokenUpdatedText: "暂未采集",
            tokenIsStale: false,
            chatGPT: StatusDetailsPresentation.service(name: "ChatGPT", state: "idle", sourceTitle: "待命", detail: "没有检测到最近任务"),
            workBuddy: StatusDetailsPresentation.service(name: "WorkBuddy", state: "idle", sourceTitle: "未监控", detail: "点击开始并确认后可监控当前会话"),
            canStartWorkBuddy: true,
            canUpdateWorkBuddy: true,
            canStopWorkBuddy: false,
            metrics: [],
            fanNote: "风扇能力未知 · 仅显示已有只读读数"
        )
    }

    private static func awaitingResetFixture() -> StatusDetailsSnapshot {
        let base = unmonitoredFixture()
        return StatusDetailsSnapshot(
            modeLabel: base.modeLabel,
            quotaWindows: base.quotaWindows,
            quotaIsStale: false,
            quotaAwaitingReset: true,
            quotaUpdatedText: "暂未获取数据",
            tokenShortText: base.tokenShortText,
            tokenExactText: base.tokenExactText,
            tokenUpdatedText: base.tokenUpdatedText,
            tokenIsStale: false,
            chatGPT: base.chatGPT,
            workBuddy: base.workBuddy,
            canStartWorkBuddy: base.canStartWorkBuddy,
            canUpdateWorkBuddy: base.canUpdateWorkBuddy,
            canStopWorkBuddy: base.canStopWorkBuddy,
            metrics: base.metrics,
            fanNote: base.fanNote
        )
    }

    private static func verifyViewAndActions(_ snapshot: StatusDetailsSnapshot) {
        let controller = StatusDetailsViewController(snapshot: snapshot, opaquePreviewBackground: true)
        let fittedHeight = controller.preferredContentHeight(maxHeight: 620)
        if let scrollView = descendants(of: controller.view).first(where: { $0.identifier?.rawValue == "details.scrollView" }) as? NSScrollView {
            // Force a non-overlay scroller so the test exercises the narrower clip view.
            scrollView.scrollerStyle = .legacy
            scrollView.autohidesScrollers = false
        }
        let root = previewHost(controller, appearance: .aqua, height: fittedHeight)
        root.layoutSubtreeIfNeeded()
        controller.scrollToTop()

        let views = descendants(of: root)
        let buttons = views.compactMap { $0 as? NSButton }
        let scrollView = views.first(where: { $0.identifier?.rawValue == "details.scrollView" }) as? NSScrollView
        check(fittedHeight >= 360 && fittedHeight <= 620, "content uses its natural height within the screen limit")
        if let brand = views.first(where: { $0.identifier?.rawValue == "details.brand" }) {
            let frame = brand.convert(brand.bounds, to: root)
            check(root.bounds.maxY - frame.maxY <= 24, "document opens at the brand with no top blank space")
        } else {
            check(false, "brand anchors the top of the document")
        }
        check(buttons.contains(where: { $0.identifier?.rawValue == "details.more" }), "more menu entry is available")
        check(buttons.contains(where: { $0.identifier?.rawValue == "details.refresh" }), "refresh entry is available")
        check(buttons.contains(where: { $0.identifier?.rawValue == "details.performance" }), "performance details entry is available")
        check(buttons.contains(where: { $0.identifier?.rawValue == "details.displaySettings" }), "display settings entry is available")
        check(!views.contains(where: { $0.identifier?.rawValue.contains("pomodoro") == true }), "menu-only popover has no Pomodoro entry")
        check(buttons.filter { $0.identifier?.rawValue.hasPrefix("workbuddy.") == true }.count == 3, "WorkBuddy exposes start/update/stop actions")
        check(buttons.first(where: { $0.identifier?.rawValue == "workbuddy.start" })?.toolTip != nil, "WorkBuddy buttons have accessible help")
        if let footer = buttons.first(where: { $0.identifier?.rawValue == "details.more" }), let scrollView {
            let footerFrame = footer.convert(footer.bounds, to: root)
            let scrollFrame = scrollView.convert(scrollView.bounds, to: root)
            check(footerFrame.minY >= 0 && footerFrame.maxY <= root.bounds.maxY, "fixed footer remains fully visible within the panel")
            check(scrollFrame.minY >= footerFrame.maxY + 7, "scroll area ends above the fixed footer without overlap")
            let clipWidth = scrollView.contentView.bounds.width
            let documentWidth = scrollView.documentView?.frame.width ?? .greatestFiniteMagnitude
            check(documentWidth <= clipWidth + 0.5, "document width fits the scroll clip with a reserved scroller")
        }
        check(controller.hasVerticalScroller, "long status content remains reachable by scrolling")
        check(views.allSatisfy { view in
            let frame = view.convert(view.bounds, to: root)
            return frame.minX >= -1 && frame.maxX <= root.bounds.maxX + 1
        }, "long text and actions remain within the popover width")

        var routedActions: [String] = []
        var invoked: [String] = []
        controller.onWorkBuddyAction = { routedActions.append($0) }
        controller.onMore = { invoked.append("more") }
        controller.onRefresh = { invoked.append("refresh") }
        controller.onPerformanceDetails = { invoked.append("performance") }
        controller.onDisplaySettings = { invoked.append("settings") }
        for name in ["workbuddy.start", "workbuddy.update", "workbuddy.stop"] {
            if let button = buttons.first(where: { $0.identifier?.rawValue == name }),
               let action = button.action, let target = button.target {
                _ = NSApp.sendAction(action, to: target, from: button)
            } else {
                check(false, "\(name) action routes")
            }
        }
        for name in ["details.more", "details.refresh", "details.performance", "details.displaySettings"] {
            if let button = buttons.first(where: { $0.identifier?.rawValue == name }),
               let action = button.action, let target = button.target {
                _ = NSApp.sendAction(action, to: target, from: button)
            } else {
                check(false, "\(name) action routes")
            }
        }
        check(routedActions == ["start", "update", "stop"], "WorkBuddy controls route without bypassing the supplied confirmation handler")
        check(invoked.sorted() == ["more", "performance", "refresh", "settings"], "footer actions route to their owners")
    }

    private static func render(_ snapshot: StatusDetailsSnapshot, appearance: NSAppearance.Name, name: String) {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STATUS_DETAILS_PREVIEW_DIR"] ?? "/private/tmp/goodtouchbar-030-preview", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                check(false, "preview output does not overwrite an existing screenshot: \(name)")
                return
            }
            let controller = StatusDetailsViewController(snapshot: snapshot, opaquePreviewBackground: true)
            let height = controller.preferredContentHeight(maxHeight: 620)
            let host = previewHost(controller, appearance: appearance, height: height)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                check(false, "preview hierarchy has no cacheable bitmap")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                check(false, "preview hierarchy could not be encoded as PNG")
                return
            }
            try data.write(to: destination, options: .atomic)
            check(hasVisiblePixels(in: rep), "preview contains rendered interface pixels")
            print("PREVIEW: \(destination.path)")
        } catch {
            check(false, "preview render failed: \(error.localizedDescription)")
        }
    }

    private static func previewHost(
        _ controller: StatusDetailsViewController,
        appearance: NSAppearance.Name,
        height: CGFloat
    ) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 416, height: height))
        host.appearance = NSAppearance(named: appearance)
        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private static func descendants(of root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants(of:))
    }

    private static func hasVisiblePixels(in rep: NSBitmapImageRep) -> Bool {
        for y in stride(from: 20, to: rep.pixelsHigh - 20, by: 24) {
            for x in stride(from: 20, to: rep.pixelsWide - 20, by: 24) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent > 0.03 {
                    return true
                }
            }
        }
        return false
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() {
            print("PASS: \(label)")
        } else {
            failures += 1
            fputs("FAIL: \(label)\n", stderr)
        }
    }
}
