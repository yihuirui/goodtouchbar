import AppKit

private enum StatusDetailsLayout {
    static let panelWidth: CGFloat = 416
    // Keep a reserved-scroller gutter inside the scroll view's clip width.
    static let bodyWidth: CGFloat = panelWidth - 48
    static let quotaCardWidth: CGFloat = (bodyWidth - 8) / 2
}

struct StatusDetailsQuotaWindow: Equatable {
    let title: String
    let remainingPercent: Int?
    let resetText: String
}

struct StatusDetailsService: Equatable {
    let name: String
    let state: String
    let detail: String
    let tone: Tone

    enum Tone: Equatable {
        case neutral, active, waiting, success, stale, error
    }
}

struct StatusDetailsMetric: Equatable {
    let symbol: String
    let title: String
    let value: String
    let accessibilityLabel: String
}

struct StatusDetailsSnapshot: Equatable {
    let modeLabel: String
    let quotaWindows: [StatusDetailsQuotaWindow]
    let quotaIsStale: Bool
    let quotaAwaitingReset: Bool
    let quotaUpdatedText: String
    let tokenShortText: String
    let tokenExactText: String
    let tokenUpdatedText: String
    let tokenIsStale: Bool
    let chatGPT: StatusDetailsService
    let workBuddy: StatusDetailsService
    let canStartWorkBuddy: Bool
    let canUpdateWorkBuddy: Bool
    let canStopWorkBuddy: Bool
    let metrics: [StatusDetailsMetric]
    let fanNote: String
}

enum StatusDetailsPresentation {
    static func quotaPercent(_ value: Int?) -> Int? {
        value.map { min(100, max(0, $0)) }
    }

    static func quotaText(_ value: Int?, stale: Bool, awaitingReset: Bool = false) -> String {
        guard let value = quotaPercent(value) else { return awaitingReset ? "额度待更新" : "暂无数据" }
        return stale ? "历史剩余 \(value)% · 已过期" : "剩余 \(value)%"
    }

    static func quotaPrimaryText(_ value: Int?, stale: Bool) -> String {
        guard let value = quotaPercent(value) else { return "--" }
        return stale ? "\(value)%" : "剩余 \(value)%"
    }

    static func quotaSecondaryText(_ value: Int?, stale: Bool, awaitingReset: Bool) -> String {
        guard quotaPercent(value) != nil else { return awaitingReset ? "额度待更新" : "暂无数据" }
        return stale ? "历史额度 · 已过期" : ""
    }

    static func service(
        name: String,
        state: String,
        sourceTitle: String,
        detail: String
    ) -> StatusDetailsService {
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let stateName: String
        let tone: StatusDetailsService.Tone
        switch state {
        case "idle":
            if title.contains("未监控") {
                stateName = "未监控"
            } else if title.contains("监控停止") {
                stateName = "已停止"
            } else {
                stateName = "待命"
            }
            tone = .neutral
        case "running": stateName = "进行中"; tone = .active
        case "waiting":
            if title.contains("拥堵") || title.contains("模型忙") {
                stateName = "模型拥堵"
            } else if title.contains("重试") {
                stateName = "等待重试"
            } else {
                stateName = "待确认"
            }
            tone = .waiting
        case "completed": stateName = "已完成"; tone = .success
        case "stale":
            stateName = title.contains("连接") ? "连接异常" : "数据过期"
            tone = .stale
        case "error":
            stateName = title.contains("读取") ? "读取异常" : "需处理"
            tone = .error
        default: stateName = "状态未知"; tone = .neutral
        }

        let conciseDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return StatusDetailsService(
            name: name,
            state: stateName,
            detail: conciseDetail,
            tone: tone
        )
    }

    static func shortTokenText(_ value: Int64?) -> String {
        guard let value else { return "--" }
        let tokens = max(0, value)
        if tokens >= 100_000_000 { return String(format: "%.1f亿", Double(tokens) / 100_000_000) }
        if tokens >= 10_000 { return "\(Int((Double(tokens) / 10_000).rounded()))万" }
        if tokens >= 1_000 { return "\(Int((Double(tokens) / 1_000).rounded()))k" }
        return String(tokens)
    }

    static func exactTokenText(_ value: Int64?) -> String {
        guard let value else { return "暂无数据" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
    }

    static func canPerformWorkBuddyAction(
        _ action: String,
        state: String,
        title: String,
        commandInFlight: Bool
    ) -> Bool {
        guard !commandInFlight else { return false }
        switch action {
        case "start": return ["idle", "completed", "stale", "error"].contains(state)
        case "update": return ["idle", "running", "waiting", "completed", "stale", "error"].contains(state)
        case "stop": return ["running", "waiting", "completed", "stale", "error"].contains(state)
            || (state == "idle" && !title.contains("未监控"))
        default: return false
        }
    }
}

@MainActor
final class StatusDetailsPopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let contentController: StatusDetailsViewController
    private var escapeMonitor: Any?
    var onMore: (() -> Void)?
    var onWorkBuddyAction: ((String) -> Void)?
    var onPerformanceDetails: (() -> Void)?
    var onDisplaySettings: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(snapshot: StatusDetailsSnapshot) {
        contentController = StatusDetailsViewController(snapshot: snapshot)
        super.init()
        popover.contentViewController = contentController
        popover.contentSize = NSSize(width: StatusDetailsLayout.panelWidth, height: 560)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        contentController.onMore = { [weak self] in
            self?.close()
            self?.onMore?()
        }
        contentController.onWorkBuddyAction = { [weak self] action in
            self?.close()
            self?.onWorkBuddyAction?(action)
        }
        contentController.onPerformanceDetails = { [weak self] in
            self?.close()
            self?.onPerformanceDetails?()
        }
        contentController.onDisplaySettings = { [weak self] in
            self?.close()
            self?.onDisplaySettings?()
        }
        contentController.onRefresh = { [weak self] in self?.onRefresh?() }
    }

    var isShown: Bool { popover.isShown }

    static func isEscapeKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 53
    }

    func update(_ snapshot: StatusDetailsSnapshot) {
        contentController.update(snapshot)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show(relativeTo: button)
        }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard !popover.isShown else { return }
        let visibleHeight = button.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 720
        let maxHeight = min(640, max(360, visibleHeight - 80))
        popover.contentSize = NSSize(
            width: StatusDetailsLayout.panelWidth,
            height: contentController.preferredContentHeight(maxHeight: maxHeight)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        contentController.scrollToTop()
        installEscapeMonitor()
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        removeEscapeMonitor()
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isEscapeKeyCode(event.keyCode), self?.popover.isShown == true else { return event }
            self?.close()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }
}

@MainActor
final class StatusDetailsViewController: NSViewController {
    private let brandLabel = NSTextField(labelWithString: "goodtouchbar")
    private let modeLabel = NSTextField(labelWithString: "")
    private let quotaCards = [StatusDetailsQuotaCard(title: "5 小时"), StatusDetailsQuotaCard(title: "7 天")]
    private let quotaFreshness = NSTextField(labelWithString: "")
    private let tokenValue = NSTextField(labelWithString: "--")
    private let tokenExact = NSTextField(labelWithString: "")
    private let tokenFreshness = NSTextField(labelWithString: "")
    private let chatGPTCard = StatusDetailsActivityCard(name: "ChatGPT", symbol: "sparkles")
    private let workBuddyCard = StatusDetailsActivityCard(name: "WorkBuddy", symbol: "sparkles.rectangle.stack")
    private let startButton = NSButton(title: "开始监控…", target: nil, action: nil)
    private let updateButton = NSButton(title: "更新会话…", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let fanNoteLabel = NSTextField(labelWithString: "")
    private let contentStack = StatusDetailsDocumentStackView()
    private let metricsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let footerStack = NSStackView()
    private let moreButton = NSButton(title: "更多", target: nil, action: nil)
    private let detailsButton = NSButton(title: "性能详情", target: nil, action: nil)
    private let settingsButton = NSButton(title: "显示设置", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let opaquePreviewBackground: Bool
    private var snapshot: StatusDetailsSnapshot
    private var renderedSnapshot: StatusDetailsSnapshot?
    var onMore: (() -> Void)?
    var onWorkBuddyAction: ((String) -> Void)?
    var onPerformanceDetails: (() -> Void)?
    var onDisplaySettings: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(snapshot: StatusDetailsSnapshot, opaquePreviewBackground: Bool = false) {
        self.snapshot = snapshot
        self.opaquePreviewBackground = opaquePreviewBackground
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = StatusDetailsPopoverRootView(opaquePreviewBackground: opaquePreviewBackground)
        if opaquePreviewBackground {
            root.material = .contentBackground
            root.blendingMode = .withinWindow
            root.state = .inactive
            root.wantsLayer = true
            root.layer?.isOpaque = true
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            root.material = .popover
            root.blendingMode = .behindWindow
            root.state = .active
        }
        root.setAccessibilityLabel("goodtouchbar 状态详情")
        root.onLayout = { [weak self] in self?.updateDocumentFrame() }
        view = root

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.identifier = NSUserInterfaceItemIdentifier("details.scrollView")
        root.addSubview(scrollView)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -8),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footerStack.heightAnchor.constraint(equalToConstant: 30),
        ])

        let content = contentStack
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        content.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true

        brandLabel.font = .systemFont(ofSize: 17, weight: .bold)
        brandLabel.identifier = NSUserInterfaceItemIdentifier("details.brand")
        brandLabel.setAccessibilityLabel("goodtouchbar")
        modeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.alignment = .center
        modeLabel.setContentHuggingPriority(.required, for: .horizontal)
        let modeBadge = StatusDetailsBadgeBackground()
        modeBadge.addSubview(modeLabel)
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            modeLabel.leadingAnchor.constraint(equalTo: modeBadge.leadingAnchor, constant: 8),
            modeLabel.trailingAnchor.constraint(equalTo: modeBadge.trailingAnchor, constant: -8),
            modeLabel.topAnchor.constraint(equalTo: modeBadge.topAnchor, constant: 3),
            modeLabel.bottomAnchor.constraint(equalTo: modeBadge.bottomAnchor, constant: -3),
        ])
        modeBadge.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let header = NSStackView(views: [brandLabel, NSView(), modeBadge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true
        content.addArrangedSubview(header)

        let quotaHeading = sectionHeading("账户额度")
        content.addArrangedSubview(quotaHeading)
        let quotaRow = NSStackView(views: quotaCards)
        quotaRow.orientation = .horizontal
        quotaRow.distribution = .fillEqually
        quotaRow.alignment = .top
        quotaRow.spacing = 8
        quotaRow.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        quotaCards.forEach { $0.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.quotaCardWidth).isActive = true }
        content.addArrangedSubview(quotaRow)
        quotaFreshness.font = .systemFont(ofSize: 11)
        quotaFreshness.textColor = .secondaryLabelColor
        content.addArrangedSubview(quotaFreshness)

        content.addArrangedSubview(sectionHeading("今日 Token"))
        let tokenCard = roundedContainer()
        let tokenStack = NSStackView(views: [tokenValue, tokenExact, tokenFreshness])
        tokenStack.orientation = .vertical
        tokenStack.alignment = .leading
        tokenStack.spacing = 2
        tokenCard.addSubview(tokenStack)
        tokenStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tokenStack.leadingAnchor.constraint(equalTo: tokenCard.leadingAnchor, constant: 10),
            tokenStack.trailingAnchor.constraint(equalTo: tokenCard.trailingAnchor, constant: -10),
            tokenStack.topAnchor.constraint(equalTo: tokenCard.topAnchor, constant: 7),
            tokenStack.bottomAnchor.constraint(equalTo: tokenCard.bottomAnchor, constant: -7),
        ])
        tokenValue.font = .systemFont(ofSize: 26, weight: .semibold)
        tokenExact.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tokenExact.textColor = .secondaryLabelColor
        tokenFreshness.font = .systemFont(ofSize: 11)
        tokenFreshness.textColor = .secondaryLabelColor
        tokenCard.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        tokenCard.heightAnchor.constraint(equalToConstant: 82).isActive = true
        content.addArrangedSubview(tokenCard)

        content.addArrangedSubview(sectionHeading("活动状态"))
        content.addArrangedSubview(chatGPTCard)
        content.addArrangedSubview(workBuddyCard)
        let actions = NSStackView(views: [startButton, updateButton, stopButton])
        actions.orientation = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 6
        actions.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        for (button, identifier, title, action) in [
            (startButton, "workbuddy.start", "开始监控", #selector(startWorkBuddy)),
            (updateButton, "workbuddy.update", "更新会话", #selector(updateWorkBuddy)),
            (stopButton, "workbuddy.stop", "停止监控", #selector(stopWorkBuddy)),
        ] {
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setAccessibilityLabel(title)
            let help = action == #selector(startWorkBuddy) || action == #selector(updateWorkBuddy)
                ? "继续后会先显示现有确认提示"
                : "停止 WorkBuddy 监控"
            button.toolTip = help
            button.setAccessibilityHelp(help)
        }
        content.addArrangedSubview(actions)

        content.addArrangedSubview(sectionHeading("系统概览"))
        let metricsCard = roundedContainer()
        metricsStack.orientation = .vertical
        metricsStack.alignment = .leading
        metricsStack.spacing = 8
        metricsCard.addSubview(metricsStack)
        metricsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            metricsStack.leadingAnchor.constraint(equalTo: metricsCard.leadingAnchor, constant: 10),
            metricsStack.trailingAnchor.constraint(equalTo: metricsCard.trailingAnchor, constant: -10),
            metricsStack.topAnchor.constraint(equalTo: metricsCard.topAnchor, constant: 9),
            metricsStack.bottomAnchor.constraint(equalTo: metricsCard.bottomAnchor, constant: -9),
        ])
        metricsCard.identifier = NSUserInterfaceItemIdentifier("details.metricsCard")
        metricsCard.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        metricsCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        content.addArrangedSubview(metricsCard)
        fanNoteLabel.font = .systemFont(ofSize: 11)
        fanNoteLabel.textColor = .secondaryLabelColor
        fanNoteLabel.lineBreakMode = .byTruncatingTail
        fanNoteLabel.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        content.addArrangedSubview(fanNoteLabel)

        footerStack.orientation = .horizontal
        footerStack.distribution = .fillEqually
        footerStack.spacing = 3
        for (button, identifier, symbol, accessibility, action) in [
            (detailsButton, "details.performance", "chart.xyaxis.line", "打开性能详情", #selector(openPerformanceDetails)),
            (settingsButton, "details.displaySettings", "slider.horizontal.3", "打开显示设置", #selector(openDisplaySettings)),
            (refreshButton, "details.refresh", "arrow.clockwise", "刷新状态", #selector(refreshData)),
            (moreButton, "details.more", "ellipsis", "打开完整菜单和诊断选项", #selector(showMore)),
        ] {
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
            button.imagePosition = .imageLeading
            button.bezelStyle = .texturedRounded
            button.target = self
            button.action = action
            button.toolTip = accessibility
            button.setAccessibilityLabel(accessibility)
        }
        [detailsButton, settingsButton, refreshButton, moreButton].forEach(footerStack.addArrangedSubview)

        update(snapshot)
    }

    func update(_ snapshot: StatusDetailsSnapshot) {
        self.snapshot = snapshot
        guard isViewLoaded else { return }
        guard renderedSnapshot != snapshot else { return }
        renderedSnapshot = snapshot
        modeLabel.stringValue = snapshot.modeLabel
        if snapshot.quotaAwaitingReset {
            quotaFreshness.stringValue = "额度待更新 · 窗口已结束，等待新数据"
        } else if snapshot.quotaIsStale {
            quotaFreshness.stringValue = "历史数据 · \(snapshot.quotaUpdatedText)"
        } else if snapshot.quotaWindows.allSatisfy({ $0.remainingPercent == nil }) {
            quotaFreshness.stringValue = snapshot.quotaUpdatedText == "暂未获取数据"
                ? "尚未获取额度数据"
                : snapshot.quotaUpdatedText
        } else {
            quotaFreshness.stringValue = snapshot.quotaUpdatedText
        }
        for (index, card) in quotaCards.enumerated() {
            let title = index < 2 ? ["5 小时", "7 天"][index] : "额度"
            let window = snapshot.quotaWindows.first(where: { $0.title == title })
            card.update(
                title: title,
                percent: window?.remainingPercent,
                resetText: window?.resetText ?? "重置时间未知",
                stale: snapshot.quotaIsStale && window?.remainingPercent != nil,
                awaitingReset: snapshot.quotaAwaitingReset && window?.remainingPercent == nil
            )
        }
        tokenValue.stringValue = snapshot.tokenShortText
        tokenExact.stringValue = snapshot.tokenExactText
        tokenFreshness.stringValue = snapshot.tokenIsStale
            ? "数据已过期 · \(snapshot.tokenUpdatedText)"
            : snapshot.tokenUpdatedText
        chatGPTCard.update(snapshot.chatGPT)
        workBuddyCard.update(snapshot.workBuddy)
        startButton.isEnabled = snapshot.canStartWorkBuddy
        updateButton.isEnabled = snapshot.canUpdateWorkBuddy
        stopButton.isEnabled = snapshot.canStopWorkBuddy
        for view in metricsStack.arrangedSubviews { metricsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        if snapshot.metrics.isEmpty {
            let label = NSTextField(labelWithString: "系统指标暂不可用")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            metricsStack.addArrangedSubview(label)
        } else {
            let metrics = Array(snapshot.metrics.prefix(4))
            for start in stride(from: 0, to: metrics.count, by: 2) {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .centerY
                row.distribution = .fillEqually
                row.spacing = 12
                row.widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth - 20).isActive = true
                for metric in metrics[start..<min(start + 2, metrics.count)] {
                    let symbol = NSImageView(image: NSImage(
                        systemSymbolName: metric.symbol,
                        accessibilityDescription: metric.accessibilityLabel
                    ) ?? NSImage())
                    symbol.contentTintColor = .secondaryLabelColor
                    symbol.widthAnchor.constraint(equalToConstant: 14).isActive = true
                    symbol.heightAnchor.constraint(equalToConstant: 14).isActive = true
                    let title = NSTextField(labelWithString: metric.title)
                    title.font = .systemFont(ofSize: 11, weight: .medium)
                    let titleRow = NSStackView(views: [symbol, title])
                    titleRow.orientation = .horizontal
                    titleRow.alignment = .centerY
                    titleRow.spacing = 6
                    let value = NSTextField(wrappingLabelWithString: metric.value)
                    value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                    value.lineBreakMode = .byCharWrapping
                    value.maximumNumberOfLines = 3
                    value.toolTip = metric.accessibilityLabel
                    let item = NSStackView(views: [titleRow, value])
                    item.orientation = .vertical
                    item.alignment = .leading
                    item.spacing = 3
                    item.setContentHuggingPriority(.defaultLow, for: .horizontal)
                    item.setAccessibilityElement(true)
                    item.setAccessibilityLabel(metric.accessibilityLabel)
                    item.toolTip = metric.accessibilityLabel
                    row.addArrangedSubview(item)
                }
                metricsStack.addArrangedSubview(row)
            }
        }
        fanNoteLabel.stringValue = snapshot.fanNote
        updateDocumentFrame()
    }

    func preferredContentHeight(maxHeight: CGFloat) -> CGFloat {
        _ = view
        contentStack.layoutSubtreeIfNeeded()
        footerStack.layoutSubtreeIfNeeded()
        let naturalHeight = contentStack.fittingSize.height + 56
        return min(max(360, naturalHeight), maxHeight)
    }

    func scrollToTop() {
        guard isViewLoaded else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    var hasVerticalScroller: Bool { scrollView.hasVerticalScroller }

    @objc private func startWorkBuddy() { onWorkBuddyAction?("start") }
    @objc private func updateWorkBuddy() { onWorkBuddyAction?("update") }
    @objc private func stopWorkBuddy() { onWorkBuddyAction?("stop") }
    @objc private func showMore() { onMore?() }
    @objc private func openPerformanceDetails() { onPerformanceDetails?() }
    @objc private func openDisplaySettings() { onDisplaySettings?() }
    @objc private func refreshData() { onRefresh?() }

    private func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func roundedContainer() -> NSView {
        StatusDetailsCardBackground()
    }

    private func updateDocumentFrame() {
        contentStack.layoutSubtreeIfNeeded()
        let height = max(1, contentStack.fittingSize.height)
        contentStack.setFrameSize(NSSize(width: StatusDetailsLayout.bodyWidth, height: height))
        contentStack.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class StatusDetailsDocumentStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class StatusDetailsQuotaCard: NSView {
    private let titleLabel: NSTextField
    private let percentLabel = NSTextField(labelWithString: "--")
    private let secondaryLabel = NSTextField(labelWithString: "暂无数据")
    private let progress = StatusDetailsQuotaProgressView()
    private let resetLabel = NSTextField(labelWithString: "重置时间未知")

    init(title: String) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        percentLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        secondaryLabel.font = .systemFont(ofSize: 11)
        secondaryLabel.textColor = .secondaryLabelColor
        secondaryLabel.maximumNumberOfLines = 2
        secondaryLabel.lineBreakMode = .byTruncatingTail
        resetLabel.font = .systemFont(ofSize: 11)
        resetLabel.textColor = .secondaryLabelColor
        resetLabel.maximumNumberOfLines = 2
        resetLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, percentLabel, secondaryLabel, progress, resetLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            secondaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            resetLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            percentLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        heightAnchor.constraint(equalToConstant: 120).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    func update(title: String, percent: Int?, resetText: String, stale: Bool, awaitingReset: Bool) {
        titleLabel.stringValue = title
        let value = StatusDetailsPresentation.quotaPercent(percent)
        percentLabel.stringValue = StatusDetailsPresentation.quotaPrimaryText(value, stale: stale)
        secondaryLabel.stringValue = StatusDetailsPresentation.quotaSecondaryText(
            value, stale: stale, awaitingReset: awaitingReset
        )
        secondaryLabel.isHidden = secondaryLabel.stringValue.isEmpty
        progress.isHidden = value == nil
        progress.value = value.map(Double.init)
        let statusColor: NSColor
        if stale || value == nil {
            statusColor = .secondaryLabelColor
        } else if let value, value < 20 {
            statusColor = .systemRed
        } else if let value, value < 50 {
            statusColor = .systemOrange
        } else {
            statusColor = .systemGreen
        }
        progress.fillColor = statusColor
        percentLabel.textColor = statusColor
        secondaryLabel.textColor = .secondaryLabelColor
        resetLabel.stringValue = resetText.isEmpty ? "重置时间未知" : resetText
        setAccessibilityElement(true)
        setAccessibilityLabel("\(title)，\(StatusDetailsPresentation.quotaText(value, stale: stale, awaitingReset: awaitingReset))，\(resetLabel.stringValue)")
    }
}

@MainActor
private final class StatusDetailsQuotaProgressView: NSView {
    var value: Double? { didSet { needsDisplay = true } }
    var fillColor: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = bounds.insetBy(dx: 0, dy: 0.5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        guard let value, value > 0 else { return }
        var fill = track
        fill.size.width *= min(100, max(0, value)) / 100
        fillColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: track.height / 2, yRadius: track.height / 2).fill()
    }
}

@MainActor
private final class StatusDetailsActivityCard: NSView {
    private let icon: NSImageView
    private let stateLabel = NSTextField(labelWithString: "待命")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let name: String

    init(name: String, symbol: String) {
        self.name = name
        icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: name) ?? NSImage())
        super.init(frame: .zero)
        icon.contentTintColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon, NSTextField(labelWithString: name), NSView(), stateLabel])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 6
        icon.widthAnchor.constraint(equalToConstant: 15).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 15).isActive = true
        (heading.views[1] as? NSTextField)?.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [heading, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        widthAnchor.constraint(equalToConstant: StatusDetailsLayout.bodyWidth).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        heightAnchor.constraint(lessThanOrEqualToConstant: 84).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    func update(_ service: StatusDetailsService) {
        stateLabel.stringValue = service.state
        detailLabel.stringValue = service.detail
        detailLabel.isHidden = service.detail.isEmpty
        detailLabel.toolTip = service.detail.isEmpty ? nil : service.detail
        stateLabel.textColor = color(for: service.tone)
        setAccessibilityElement(true)
        setAccessibilityLabel("\(name)：\(service.state)\(service.detail.isEmpty ? "" : "，\(service.detail)")")
    }

    private func color(for tone: StatusDetailsService.Tone) -> NSColor {
        switch tone {
        case .neutral: return .secondaryLabelColor
        case .active: return .systemBlue
        case .waiting: return .systemOrange
        case .success: return .systemGreen
        case .stale: return .systemPurple
        case .error: return .systemRed
        }
    }
}

@MainActor
private final class StatusDetailsCardBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }
}

@MainActor
private final class StatusDetailsBadgeBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

@MainActor
private final class StatusDetailsPopoverRootView: NSVisualEffectView {
    private let opaquePreviewBackground: Bool
    var onLayout: (() -> Void)?

    init(opaquePreviewBackground: Bool = false) {
        self.opaquePreviewBackground = opaquePreviewBackground
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard opaquePreviewBackground else {
            super.draw(dirtyRect)
            return
        }
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}
