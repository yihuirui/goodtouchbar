import AppKit
import os.log
import UserNotifications
import SystemMonitoring
import UniformTypeIdentifiers

private let touchBarLogger = Logger(
    subsystem: "io.github.yihuirui.goodtouchbar",
    category: "TouchBar"
)

private let codexItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.codex"
)
private let quotaItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.codex.quota"
)
private let workbuddyItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.workbuddy"
)
private let agentSpeedItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.agent.speed"
)
private let tokenItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.tokens"
)
private let pomodoroItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.pomodoro"
)
private let pomodoroResetItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.pomodoro.reset"
)
private let systemControlsItemIdentifier = NSTouchBarItem.Identifier(
    "io.github.yihuirui.goodtouchbar.system-controls"
)

private let moreItemIdentifier = NSTouchBarItem.Identifier("io.github.yihuirui.goodtouchbar.more")
private let backItemIdentifier = NSTouchBarItem.Identifier("io.github.yihuirui.goodtouchbar.performance.back")
private let fanToggleIdentifier = NSTouchBarItem.Identifier("io.github.yihuirui.goodtouchbar.performance.fixed")
private let metricItemPrefix = "io.github.yihuirui.goodtouchbar.metric."

private enum TouchBarStateColors {
    static let neutral = NSColor(calibratedWhite: 0.24, alpha: 1)
    static let tokenUsage = NSColor(calibratedRed: 0.384, green: 0.290, blue: 0.514, alpha: 1)
    static let running = NSColor(calibratedRed: 0.10, green: 0.38, blue: 0.76, alpha: 1)
    static let waiting = NSColor(calibratedRed: 0.78, green: 0.42, blue: 0.08, alpha: 1)
    static let completed = NSColor(calibratedRed: 0.12, green: 0.56, blue: 0.30, alpha: 1)
    static let stale = NSColor(calibratedRed: 0.36, green: 0.31, blue: 0.45, alpha: 1)
    static let error = NSColor(calibratedRed: 0.68, green: 0.16, blue: 0.16, alpha: 1)
    static let quotaHealthy = NSColor(calibratedRed: 0.09, green: 0.45, blue: 0.26, alpha: 1)
    static let quotaWarning = NSColor(calibratedRed: 0.64, green: 0.36, blue: 0.06, alpha: 1)
    static let quotaCritical = NSColor(calibratedRed: 0.68, green: 0.14, blue: 0.14, alpha: 1)
    static let focus = NSColor(calibratedRed: 0.74, green: 0.20, blue: 0.16, alpha: 1)
    static let shortBreak = NSColor(calibratedRed: 0.10, green: 0.50, blue: 0.42, alpha: 1)
    static let longBreak = NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.62, alpha: 1)

    static func activity(_ state: CodexActivitySnapshot.State) -> NSColor {
        switch state {
        case .idle: return neutral
        case .running: return running
        case .waiting: return waiting
        case .completed: return completed
        case .stale: return stale
        case .error: return error
        }
    }

    static func activity(_ state: WorkBuddyActivitySnapshot.State) -> NSColor {
        switch state {
        case .idle: return neutral
        case .running: return running
        case .waiting: return waiting
        case .completed: return completed
        case .stale: return stale
        case .error: return error
        }
    }

    static func activity(_ state: AgentSpeedSnapshot.State) -> NSColor {
        switch state {
        case .idle: return neutral
        case .running: return running
        case .completed: return completed
        case .stale: return stale
        case .error: return error
        }
    }

    static func quota(_ remaining: Int?, isStale: Bool = false) -> NSColor {
        guard let remaining else { return neutral }
        if isStale { return stale }
        if remaining >= 50 { return quotaHealthy }
        if remaining >= 20 { return quotaWarning }
        return quotaCritical
    }

    static func pomodoro(
        phase: PomodoroModel.Phase,
        isRunning: Bool
    ) -> NSColor {
        guard isRunning else { return neutral }
        switch phase {
        case .focus: return focus
        case .shortBreak: return shortBreak
        case .longBreak: return longBreak
        }
    }

    static func tokens(_ snapshot: TokenUsageSnapshot) -> NSColor {
        guard snapshot.tokens != nil else { return neutral }
        return snapshot.stale ? stale : tokenUsage
    }
}

private enum StatusBarStateColors {
    static let idle = NSColor.white
    static let running = NSColor.systemBlue
    static let waiting = NSColor.systemOrange
    static let completed = NSColor.systemGreen
    static let stale = NSColor.systemPurple
    static let error = NSColor.systemRed

    static func activity(_ state: CodexActivitySnapshot.State) -> NSColor {
        switch state {
        case .idle: return idle
        case .running: return running
        case .waiting: return waiting
        case .completed: return completed
        case .stale: return stale
        case .error: return error
        }
    }

    static func activity(_ state: WorkBuddyActivitySnapshot.State) -> NSColor {
        switch state {
        case .idle: return idle
        case .running: return running
        case .waiting: return waiting
        case .completed: return completed
        case .stale: return stale
        case .error: return error
        }
    }

    static func activity(_ state: AgentSpeedSnapshot.State) -> NSColor {
        switch state {
        case .idle: return idle
        case .running: return running
        case .completed: return completed
        case .stale: return stale
        case .error: return error
        }
    }

    static func pomodoro(
        phase: PomodoroModel.Phase,
        isRunning: Bool
    ) -> NSColor {
        guard isRunning else { return idle }
        switch phase {
        case .focus: return NSColor.systemRed
        case .shortBreak: return NSColor.systemTeal
        case .longBreak: return NSColor.systemBlue
        }
    }
}

private enum TouchBarAgentIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(named resourceName: String) -> NSImage? {
        if let cached = cache[resourceName] {
            return cached
        }
        let symbol = resourceName.contains("workbuddy") ? "sparkles.rectangle.stack" : "terminal"
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "goodtouchbar") else { return nil }
        image.size = NSSize(width: 24, height: 24)
        image.isTemplate = true
        cache[resourceName] = image
        return image
    }
}

private enum StatusBarIconCatalog {
    private static var cache: [String: NSImage] = [:]
    private static var stateCache: [String: NSImage] = [:]

    static func image(named resourceName: String) -> NSImage? {
        if let cached = cache[resourceName] {
            return cached
        }
        let symbol = resourceName.contains("workbuddy") ? "sparkles.rectangle.stack" : "terminal"
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "goodtouchbar") else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        cache[resourceName] = image
        return image
    }

    static func image(
        named resourceName: String,
        stateKey: String,
        statusColor: NSColor
    ) -> NSImage? {
        let cacheKey = "\(resourceName)#\(stateKey)"
        if let cached = stateCache[cacheKey] {
            return cached
        }

        guard let baseImage = image(named: resourceName) else {
            return nil
        }

        let result = NSImage(size: NSSize(width: 18, height: 18))
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        baseImage.draw(
            in: NSRect(x: 0, y: 2, width: 16, height: 16),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let badgeRect = NSRect(x: 13, y: 0.7, width: 4.2, height: 4.2)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(ovalIn: badgeRect.insetBy(dx: -0.65, dy: -0.65)).fill()
        statusColor.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()
        result.unlockFocus()

        result.isTemplate = false
        stateCache[cacheKey] = result
        return result
    }
}

private enum TouchBarTextMode {
    case full
    case compact
}

private enum TouchBarLayout {
    // Keep the countdown width stable while the two-digit seconds change.
    static let pomodoroWidth: CGFloat = 90
    static let pomodoroFont = NSFont.monospacedDigitSystemFont(
        ofSize: 14,
        weight: .medium
    )
}

private enum PomodoroReminderSettings {
    static let soundEnabledKey = "pomodoro.completionSoundEnabled"
    static let popupEnabledKey = "pomodoro.completionPopupEnabled"

    static func soundEnabled() -> Bool {
        UserDefaults.standard.object(forKey: soundEnabledKey) as? Bool ?? true
    }

    static func popupEnabled() -> Bool {
        UserDefaults.standard.object(forKey: popupEnabledKey) as? Bool ?? true
    }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSTouchBarDelegate {
    private static let windowItemPrefix = "io.github.yihuirui.goodtouchbar.window."
    private let model: PomodoroModel
    private let codexMonitor = CodexActivityMonitor()
    private let quotaMonitor = CodexQuotaMonitor()
    private let workbuddyMonitor = WorkBuddyActivityMonitor()
    private let agentSpeedMonitor = AgentSpeedMonitor()
    private let tokenMonitor = TokenUsageMonitor()
    private let pluginManager: TouchBarPluginManager
    private let healthMonitor: HealthMonitor
    private let metricsMonitor = SystemMetricsMonitor()
    private let fanClient: FanControlClient
    private let deviceCapabilities: GoodTouchBarDeviceCapabilities
    private var fanWindow: FanControlWindow?
    private var lastFanHealthSignature = ""
    private var monitorSettings: MonitorSettingsWindow?
    private var pluginSettings: PluginSettingsWindow?
    private var activeTouchBarIdentifiers: [NSTouchBarItem.Identifier] = []
    private var overflowKeys: [String] = []
    private var performancePage = false
    private var incidents = IncidentTracker()
    private var fanWasConnected = false
    private var notificationsEnabled = UserDefaults.standard.bool(forKey: "diagnosticNotifications")
    private var notificationNotice = ""
    private var notificationGeneration = 0
    private var requestedWBMonitoring = false
    private var wbStopRequested = false

    private var titleLabel: NSTextField!
    private var statusLabel: NSTextField!
    private var codexLabel: NSTextField!
    private var statsLabel: NSTextField!
    private var usageLabel: NSTextField!
    private var actionButton: NSButton!
    private var shortBreakButton: NSButton!
    private var longBreakButton: NSButton!
    private var resetButton: NSButton!
    private var codexTouchBarButton: NSButtonTouchBarItem?
    private var quotaTouchBarButton: NSButtonTouchBarItem?
    private var workbuddyTouchBarButton: NSButtonTouchBarItem?
    private var agentSpeedTouchBarButton: NSButtonTouchBarItem?
    private var tokenTouchBarButton: NSButtonTouchBarItem?
    private var touchBarButton: NSButtonTouchBarItem?
    private var touchBarResetButton: NSButtonTouchBarItem?
    private var appTouchBar: NSTouchBar?
    private var globalTouchBar: NSTouchBar?
    private var globalTouchBarItems: [NSTouchBarItem.Identifier: NSButtonTouchBarItem] = [:]
    private let touchBarEnabled: Bool
    var fanControlAvailable: Bool { fanClient.fanControlAvailable }
    private var renderCount = 0
    private var fanUIUpdatePending = false
    private var lastFanMenuTitle = ""
    private var touchBarTextMode: TouchBarTextMode = .compact
    private var touchBarLayoutCheckWorkItem: DispatchWorkItem?
    private var touchBarLayoutCheckedAt: Date?
    private var touchBarResolvedItemCount = 0
    private var touchBarVisibleItemCount = 0
    private var activePomodoroAlert: NSAlert?
    private var systemControlsWindow: SystemControlsWindow?

    var onChange: (() -> Void)?
    var onTouchBarRebuilt: ((NSTouchBar) -> Void)?

    init(healthMonitor: HealthMonitor, pluginManager injectedManager: TouchBarPluginManager? = nil, fanClient injectedFan: FanControlClient? = nil, model injectedModel: PomodoroModel? = nil, startMonitoring: Bool = true, touchBarEnabled: Bool? = nil, deviceCapabilities injectedCapabilities: GoodTouchBarDeviceCapabilities? = nil, pomodoroStateFileURL: URL? = nil) {
        let capabilities = injectedCapabilities ?? .current
        let resolvedTouchBar = touchBarEnabled ?? capabilities.resolveTouchBarMode(GoodTouchBarRuntimeConfiguration.selectedMode()).enabled
        self.deviceCapabilities = capabilities
        self.healthMonitor = healthMonitor
        self.pluginManager = injectedManager ?? TouchBarPluginManager()
        self.fanClient = injectedFan ?? FanControlClient(capabilities: capabilities)
        self.model = injectedModel ?? PomodoroModel(stateFileURL: pomodoroStateFileURL, restoreState: resolvedTouchBar)
        self.touchBarEnabled = resolvedTouchBar

        let contentRect = NSRect(x: 0, y: 0, width: 520, height: 300)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GoodTouchBar"
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        buildWindowContents()
        if self.touchBarEnabled {
            installTouchBar()
        } else {
            touchBarLogger.notice("Touch Bar disabled; running in menu bar mode")
        }

        guard startMonitoring else { return }
        metricsMonitor.onChange = { [weak self] in
            self?.monitorSettings?.render()
            self?.renderAndNotify(remeasureTouchBar: false)
        }
        configureMetrics()
        metricsMonitor.start()
        fanClient.onChange = { [weak self] in
            guard let self else { return }
            if !self.fanUIUpdatePending {
                self.fanUIUpdatePending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.fanUIUpdatePending = false
                    self.fanWindow?.renderIfVisible()
                    self.render()
                    self.monitorSettings?.render()
                    let title = self.fanControlMenuTitle()
                    if title != self.lastFanMenuTitle { self.lastFanMenuTitle = title; self.onChange?() }
                }
            }
            let signature = "\(self.fanClient.connected):\(self.fanClient.status?.phase.rawValue ?? "unknown"):\(self.fanClient.status?.error ?? "")"
            if signature != self.lastFanHealthSignature { self.lastFanHealthSignature = signature; self.healthMonitor.refresh() }
        }
        fanClient.start()
        model.onChange = { [weak self] in
            // A Pomodoro tick only changes the already-fixed-width title. Do not
            // remeasure and reflow the global Touch Bar once per second.
            self?.renderAndNotify(remeasureTouchBar: false)
        }
        codexMonitor.onChange = { [weak self] in
            self?.renderAndNotify()
        }
        quotaMonitor.onChange = { [weak self] in
            self?.renderAndNotify()
        }
        workbuddyMonitor.onChange = { [weak self] in
            self?.renderAndNotify()
        }
        workbuddyMonitor.onRestartRequired = { [weak self] command in
            self?.confirmWorkBuddyRestart(command)
        }
        agentSpeedMonitor.onChange = { [weak self] in
            self?.renderAndNotify()
        }
        tokenMonitor.onChange = { [weak self] in
            self?.renderAndNotify()
        }
        pluginManager.onChange = { [weak self] in
            self?.renderAndNotify()
        }
        model.onCompletion = { [weak self] message, kind in
            self?.handlePomodoroCompletion(message, kind: kind)
        }
        codexMonitor.start()
        quotaMonitor.start()
        workbuddyMonitor.start()
        agentSpeedMonitor.start()
        pluginManager.start()
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showMainWindow() {
        showWindow(nil)
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.refresh()
        codexMonitor.refresh()
        refreshUsageStatus()
        healthMonitor.refresh()
    }

    func startCollapsed() {
        showWindow(nil)
        if window?.isMiniaturized == false {
            window?.miniaturize(nil)
        }
    }

    func stopMonitoring() {
        touchBarLayoutCheckWorkItem?.cancel()
        touchBarLayoutCheckWorkItem = nil
        codexMonitor.stop()
        quotaMonitor.stop()
        workbuddyMonitor.stop()
        agentSpeedMonitor.stop()
        tokenMonitor.stop()
        pluginManager.stop()
        metricsMonitor.stop()
        fanClient.stop(release: true)
        model.flush()
    }

    override func makeTouchBar() -> NSTouchBar? {
        touchBarLogger.notice("makeTouchBar called")
        return appTouchBar
    }

    func togglePomodoro() {
        Self.requestPomodoroNotificationAuthorization()
        model.toggle()
    }

    func startPomodoro() {
        Self.requestPomodoroNotificationAuthorization()
        model.start()
    }

    func resetPomodoro() {
        model.reset()
    }

    func startShortBreak() {
        model.startShortBreak()
    }

    func startLongBreak() {
        model.startLongBreak()
    }

    func pomodoroStatusBarText() -> String? {
        model.statusBarText
    }

    func pomodoroSoundReminderEnabled() -> Bool {
        PomodoroReminderSettings.soundEnabled()
    }

    func pomodoroPopupReminderEnabled() -> Bool {
        PomodoroReminderSettings.popupEnabled()
    }

    func togglePomodoroSoundReminder() {
        UserDefaults.standard.set(
            !PomodoroReminderSettings.soundEnabled(),
            forKey: PomodoroReminderSettings.soundEnabledKey
        )
        onChange?()
    }

    func togglePomodoroPopupReminder() {
        UserDefaults.standard.set(
            !PomodoroReminderSettings.popupEnabled(),
            forKey: PomodoroReminderSettings.popupEnabledKey
        )
        onChange?()
    }

    func openPomodoroNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshCodexStatus() {
        codexMonitor.refresh()
    }

    func refreshUsageStatus() {
        quotaMonitor.refresh()
        workbuddyMonitor.refresh()
        tokenMonitor.refresh()
    }

    func openPluginConfiguration() {
        if pluginSettings == nil {
            pluginSettings = PluginSettingsWindow(manager:pluginManager,didSave:{ [weak self] in
                guard let self else { return }; self.configureMetrics()
                if self.touchBarEnabled { self.installTouchBar(); if let bar = self.globalTouchBar { self.onTouchBarRebuilt?(bar) } }
                self.renderAndNotify(); self.healthMonitor.refresh()
            })
        }
        pluginSettings?.present()
    }

    @discardableResult
    func reloadPluginConfiguration() -> String? {
        if let error = pluginManager.reload() {
            return error
        }

        configureMetrics()
        if touchBarEnabled {
            installTouchBar()
        }
        renderAndNotify()
        if let globalTouchBar {
            onTouchBarRebuilt?(globalTouchBar)
        }
        return nil
    }

    func refreshScriptPlugins() {
        pluginManager.refreshScripts()
    }

    func pomodoroMenuTitle() -> String {
        model.menuText
    }

    func codexMenuTitle() -> String {
        gptStatusWindowText
    }

    func quotaMenuTitle() -> String {
        gptUsageWindowText
    }

    func controlWorkBuddyRetry(_ command: String) {
        if command == "start" || command == "update" {
            let alert = NSAlert()
            alert.messageText = command == "start" ? "允许 WorkBuddy 自动重试吗？" : "更新会话并继续自动重试吗？"
            alert.informativeText = "启用后只在唯一绑定的当前聊天出现明确模型忙碌状态时执行；每轮最多 10 次或 20 分钟。此操作不会安装辅助服务。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "允许并开始监控")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        requestedWBMonitoring = command != "stop"
        wbStopRequested = command == "stop"
        workbuddyMonitor.control(command)
    }

    private func confirmWorkBuddyRestart(_ command: String) {
        let alert = NSAlert()
        alert.messageText = "需要重新打开 WorkBuddy"
        alert.informativeText = "重新打开后才能开始监控，可能中断当前任务。请等任务完成后继续；之后会自动连接并监控当前会话。"
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "重新打开并监控")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            workbuddyMonitor.control(command, allowRestart: true)
        }
    }

    func workbuddyMenuTitle() -> String {
        workbuddyMonitor.snapshot.menuText
    }

    func agentSpeedBundle() -> AgentSpeedBundle {
        agentSpeedMonitor.bundle
    }

    func refreshAgentSpeed() {
        agentSpeedMonitor.refresh()
    }

    func configurationBackups() -> [URL] {
        pluginManager.availableBackups
    }

    func fanHelperUpdateRequired() -> Bool { fanClient.helperUpdateRequired }

    func restoreConfigurationBackup() -> String {
        do {
            let url = try pluginManager.restoreLatestBackup()
            if let error = reloadPluginConfiguration() {
                return "已从 \(url.lastPathComponent) 恢复，但重新加载失败：\(error)"
            }
            return "已从 \(url.lastPathComponent) 恢复配置。"
        } catch {
            return "恢复失败：\(error.localizedDescription)"
        }
    }

    func showSystemControls() {
        if systemControlsWindow == nil { systemControlsWindow = SystemControlsWindow() }
        systemControlsWindow?.present()
    }

    func toggleSystemMute() {
        if systemControlsWindow == nil { systemControlsWindow = SystemControlsWindow() }
        systemControlsWindow?.toggleMute()
    }

    func applyPreset(_ preset: GoodTouchBarLayoutPreset) throws {
        try pluginManager.applyPreset(preset)
        // A layout preset should become visible immediately even when the user
        // opened the import/menu action from the performance page.
        if performancePage {
            performancePage = false
            metricsMonitor.performancePage = false
            fanClient.quickControlsVisible = false
        }
        configureMetrics()
        if touchBarEnabled { installTouchBar() }
        renderAndNotify()
    }

    func exportedPreset() -> GoodTouchBarLayoutPreset {
        let layout = pluginManager.visibleKeys.filter(GoodTouchBarLayoutPreset.allowedLayoutKeys.contains)
        let menuLayout = pluginManager.menuKeys.filter(GoodTouchBarLayoutPreset.allowedLayoutKeys.contains)
        return GoodTouchBarLayoutPreset(
            name: "自定义布局",
            layout: layout.isEmpty ? [TouchBarPluginKey.systemControls] : layout,
            menuLayout: menuLayout.isEmpty ? [TouchBarPluginKey.gptUsage, TouchBarPluginKey.todayTokens] : menuLayout,
            thresholds: pluginManager.configuration.metricThresholds ?? [:]
        )
    }

    func tokenMenuTitle() -> String {
        tokenMonitor.snapshot.menuText
    }

    func statusDetailsSnapshot(menuBarMode: Bool) -> StatusDetailsSnapshot {
        let quota = quotaMonitor.snapshot
        let token = tokenMonitor.snapshot
        let workBuddy = workbuddyMonitor.snapshot
        let metricSnapshot = metricsMonitor.snapshot
        let quotaHasData = !quota.windows.isEmpty
        let quotaWindows = [
            StatusDetailsQuotaWindow(
                title: "5 小时",
                remainingPercent: quota.windows.first(where: { $0.label == "5小时" })?.remainingPercent,
                resetText: quota.windows.first(where: { $0.label == "5小时" })?.resetText ?? "重置时间未知"
            ),
            StatusDetailsQuotaWindow(
                title: "7 天",
                remainingPercent: quota.windows.first(where: { $0.label == "7天" })?.remainingPercent,
                resetText: quota.windows.first(where: { $0.label == "7天" })?.resetText ?? "重置时间未知"
            ),
        ]
        let chatGPT = StatusDetailsPresentation.service(
            name: "ChatGPT",
            state: codexMonitor.snapshot.state.rawValue,
            sourceTitle: codexMonitor.snapshot.title,
            detail: codexMonitor.snapshot.detail
        )
        let workBuddyStatus = StatusDetailsPresentation.service(
            name: "WorkBuddy",
            state: workBuddy.state.rawValue,
            sourceTitle: workBuddy.title,
            detail: workBuddy.detail
        )

        var metrics: [StatusDetailsMetric] = []
        if let reading = metricSnapshot.readings[MetricID.cpu.rawValue],
           reading.isFresh(), let value = reading.value {
            let text = String(format: "%.0f%%", value)
            metrics.append(.init(symbol: "cpu", title: "CPU", value: text, accessibilityLabel: "CPU 使用率 \(text)"))
        }
        if let used = metricSnapshot.readings[MetricID.memory.rawValue],
           used.isFresh(), let value = used.value {
            let total = metricSnapshot.readings["memory.total"]?.value ?? 0
            let text = total > 0
                ? String(format: "%.1f/%.0f GB", value / 1_073_741_824, total / 1_073_741_824)
                : String(format: "%.1f GB", value / 1_073_741_824)
            metrics.append(.init(symbol: "memorychip", title: "内存", value: text, accessibilityLabel: "内存使用 \(text)"))
        }
        if let reading = metricSnapshot.readings[MetricID.cpuTemperature.rawValue],
           reading.isFresh(), let value = reading.value {
            let text = String(format: "%.0f°C", value)
            metrics.append(.init(symbol: "thermometer.medium", title: "温度", value: text, accessibilityLabel: "CPU 温度 \(text)"))
        }

        let fanReading = metricSnapshot.readings[MetricID.fans.rawValue]
        if fanReading?.isFresh() == true {
            if metricSnapshot.fans.isEmpty {
                metrics.append(.init(symbol: "fan", title: "风扇", value: "未检测到", accessibilityLabel: "未检测到风扇转速读数"))
            } else {
                let rpm = metricSnapshot.fans.map { fan in
                    fan.actual.map { String(format: "%.0f", $0) } ?? "未知"
                }.joined(separator: "/")
                metrics.append(.init(symbol: "fan", title: "风扇", value: "\(rpm) RPM", accessibilityLabel: "风扇转速 \(rpm) RPM"))
            }
        }

        let fanNote: String
        if capabilitiesCanReadFansAsReadOnly {
            fanNote = "风扇只读 · 只显示已采样转速；未知读数不代表没有风扇"
        } else if deviceCapabilities.processArchitecture == "x86_64", deviceCapabilities.hostSupportsArm64 == false {
            fanNote = "Intel 风扇读数只读 · 未采样时状态未知"
        } else {
            fanNote = "风扇能力未知 · 仅显示已有只读读数"
        }

        let quotaUpdatedText: String
        if !quotaHasData {
            quotaUpdatedText = "暂未获取数据"
        } else {
            quotaUpdatedText = quota.updatedAgeText.map { "更新于\($0)" } ?? "更新时间未知"
        }
        let tokenUpdatedText: String
        if token.tokens == nil {
            tokenUpdatedText = "暂未采集"
        } else {
            tokenUpdatedText = token.updatedAt.map { "更新于\(CodexQuotaSnapshot.ageText($0))" } ?? "更新时间未知"
        }

        return StatusDetailsSnapshot(
            modeLabel: menuBarMode ? "菜单栏模式" : "Touch Bar 模式",
            quotaWindows: quotaWindows,
            quotaIsStale: quotaHasData && quota.isStale,
            quotaAwaitingReset: quota.windows.isEmpty && quota.awaitingReset,
            quotaUpdatedText: quotaUpdatedText,
            tokenShortText: StatusDetailsPresentation.shortTokenText(token.tokens),
            tokenExactText: token.tokens.map { "精确计数 \(StatusDetailsPresentation.exactTokenText($0))" } ?? "暂无精确计数",
            tokenUpdatedText: tokenUpdatedText,
            tokenIsStale: token.tokens != nil && token.stale,
            chatGPT: chatGPT,
            workBuddy: workBuddyStatus,
            canStartWorkBuddy: StatusDetailsPresentation.canPerformWorkBuddyAction(
                "start", state: workBuddy.state.rawValue, title: workBuddy.title,
                commandInFlight: workbuddyMonitor.commandInFlight
            ),
            canUpdateWorkBuddy: StatusDetailsPresentation.canPerformWorkBuddyAction(
                "update", state: workBuddy.state.rawValue, title: workBuddy.title,
                commandInFlight: workbuddyMonitor.commandInFlight
            ),
            canStopWorkBuddy: StatusDetailsPresentation.canPerformWorkBuddyAction(
                "stop", state: workBuddy.state.rawValue, title: workBuddy.title,
                commandInFlight: workbuddyMonitor.commandInFlight
            ),
            metrics: metrics,
            fanNote: fanNote
        )
    }

    private var capabilitiesCanReadFansAsReadOnly: Bool {
        deviceCapabilities.processArchitecture == "arm64" || deviceCapabilities.hostSupportsArm64 == true
    }

    func refreshStatusDetails() {
        codexMonitor.refresh()
        quotaMonitor.refresh()
        workbuddyMonitor.refresh()
        tokenMonitor.refresh()
        agentSpeedMonitor.refresh()
        metricsMonitor.refresh()
    }

    func displayText(for key: String) -> String {
        if MetricID(rawValue: key) != nil { return metricsMonitor.snapshot.text(for: key) }
        switch key {
        case TouchBarPluginKey.gptStatus: return gptStatusTouchBarText
        case TouchBarPluginKey.gptUsage: return gptUsageTouchBarText
        case TouchBarPluginKey.workbuddy: return workbuddyTouchBarText
        case TouchBarPluginKey.agentSpeed: return agentSpeedTouchBarText
        case TouchBarPluginKey.todayTokens: return tokenTouchBarText
        case TouchBarPluginKey.pomodoro: return pomodoroTouchBarText
        case TouchBarPluginKey.pomodoroReset: return "↺"
        case TouchBarPluginKey.systemControls: return "系统控制"
        default: return pluginManager.scriptRuntimes.first { $0.definition.key == key }?.displayText ?? key
        }
    }

    private func configureMetrics() {
        tokenMonitor.setEnabled((pluginManager.visibleKeys + pluginManager.menuKeys).contains(TouchBarPluginKey.todayTokens))
        metricsMonitor.configure(keys: pluginManager.visibleKeys + pluginManager.menuKeys, cpuTemperatureKey: pluginManager.selectedCPUTemperatureKey)
    }

    func showMonitorSettings(showDetails: Bool = false) {
        if monitorSettings == nil {
            monitorSettings = MonitorSettingsWindow(manager: pluginManager, monitor: metricsMonitor, preview: { [weak self] key in self?.displayText(for: key) ?? "--" }, didSave: { [weak self] in
                guard let self else { return }
                self.configureMetrics()
                if self.touchBarEnabled {
                    self.installTouchBar()
                    if let bar = self.globalTouchBar { self.onTouchBarRebuilt?(bar) }
                }
                self.renderAndNotify()
                self.healthMonitor.refresh()
            }, capabilities: deviceCapabilities, touchBarMode: GoodTouchBarRuntimeConfiguration.selectedMode())
            monitorSettings?.touchBarModeChanged = { [weak self] mode in
                guard let self else { return }
                UserDefaults.standard.set(mode.rawValue, forKey: GoodTouchBarRuntimeConfiguration.touchBarModeDefaultsKey)
                let resolution = self.deviceCapabilities.resolveTouchBarMode(mode)
                let alert = NSAlert()
                alert.messageText = "Touch Bar 模式已保存"
                alert.informativeText = "\(resolution.reason)\n请退出并重新打开 goodtouchbar 后生效。"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
        monitorSettings?.diagnosticState = { [weak self] in
            guard let self else { return [:] }
            return ["fanPhase": self.fanClient.status?.phase.rawValue ?? "unknown", "fanConnected": String(self.fanClient.connected), "helperUpdateRequired": String(self.fanClient.helperUpdateRequired), "wbState": self.workbuddyMonitor.snapshot.state.rawValue, "incidents": self.incidents.active.sorted().joined(separator:",")]
        }
        monitorSettings?.statusText = { [weak self] in self?.incidentSummary ?? "暂无异常" }
        monitorSettings?.fanText = { [weak self] in self?.fanClient.message ?? "--" }
        monitorSettings?.notificationsEnabled = notificationsEnabled
        monitorSettings?.onNotifications = { [weak self] enabled in self?.setIncidentNotifications(enabled) }
        monitorSettings?.onOpenPlugins = { [weak self] in self?.openPluginConfiguration() }
        monitorSettings?.onOpenFanControl = { [weak self] in self?.showFanControl() }
        monitorSettings?.present(showDetails: showDetails)
    }
    @objc private func showFanControlFromTouchBar() { showFanControl() }
    func fanControlMenuTitle() -> String {
        if fanClient.status?.phase.rawValue == "recoveryFailed" { return "风扇调速：恢复自动未确认…" }
        if fanClient.hasControl { return "风扇调速：" + fanClient.message + "…" }
        return "风扇调速…"
    }
    func showFanControl() {
        guard fanClient.fanControlAvailable else {
            let alert = NSAlert()
            alert.messageText = "风扇由 macOS 自动管理"
            alert.informativeText = "当前运行环境只允许只读传感器数据；不会连接或安装 Intel 风扇辅助服务，也不会修改风扇转速。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        if fanWindow == nil { fanWindow = FanControlWindow(client: fanClient) }
        fanWindow?.present()
    }

    func installFanHelper() {
        guard fanClient.fanControlAvailable else { return }
        fanClient.install()
        // 安装会弹系统授权框；装完把窗口带出来，让用户直接看到连接结果。
        showFanControl()
    }
    @objc private func showMetricsFromTouchBar(_ sender: Any?) {
        if let item = sender as? NSTouchBarItem, item.identifier.rawValue.contains("system.fan") { showFanControl() }
        else { showMonitorSettings(showDetails: true) }
    }

    func usesLegacyPomodoroStatusItem() -> Bool { touchBarEnabled && pluginManager.configuration.version == nil }

    private var statusMenuLayout: (visible: [String], overflow: [String]) {
        DisplayLayout.fit(pluginManager.menuKeys.filter { touchBarEnabled && !usesLegacyPomodoroStatusItem() || $0 != TouchBarPluginKey.pomodoro }, budget: 380, moreWidth: 32) { key in
            MetricID(rawValue: key) != nil ? self.fixedWidth(for: key) * 0.8 : min(160, self.estimatedButtonWidth(for: self.displayText(for: key)))
        }
    }
    func statusBarSummaryText() -> String {
        let keys = statusMenuLayout.visible
        return keys.isEmpty ? "GoodTouchBar · 点击打开菜单" : keys.map(displayText(for:)).joined(separator: " · ")
    }

    func statusBarSummaryAttributedText() -> NSAttributedString {
        let layout = statusMenuLayout
        var text = layout.visible.map(displayText(for:)).joined(separator: "  ")
        if !layout.overflow.isEmpty { text += " ···" }
        if text.isEmpty { text = "◉" }
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor])
    }

    func pomodoroStatusBarAttributedText() -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            // The top menu bar has a light background in this TouchBar build.
            .foregroundColor: NSColor.black,
        ]
        return NSAttributedString(string: model.statusBarSummaryText, attributes: attributes)
    }

    private var statusBarQuotaText: String {
        quotaMonitor.snapshot.touchBarText
    }

    private var statusBarTokenText: String {
        tokenMonitor.snapshot.touchBarText.replacingOccurrences(of: "💰", with: "💰 ")
    }

    func copyCurrentStatus() {
        var lines = [
            gptStatusWindowText,
            gptUsageWindowText,
            workbuddyMonitor.snapshot.windowText,
            tokenMonitor.snapshot.menuText,
        ]
        if touchBarEnabled { lines.append(model.menuText) }
        copyToPasteboard(lines.joined(separator: "\n"))
    }

    func touchBarForGlobalPresentation() -> NSTouchBar? {
        globalTouchBar
    }

    func healthProbe(
        globalTouchBar: GlobalTouchBarPresentationSnapshot
    ) -> TouchBarRuntimeProbe {
        if touchBarEnabled {
            updateTouchBarLayoutDiagnostics(
                for: globalTouchBar.enabled ? self.globalTouchBar : appTouchBar
            )
        }
        let betterTouchToolURL = URL(fileURLWithPath: "/Applications/BetterTouchTool.app")
        let betterTouchToolInstalled = FileManager.default.fileExists(atPath: betterTouchToolURL.path)
        let betterTouchToolRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.hegenberg.BetterTouchTool"
        ).isEmpty

        return TouchBarRuntimeProbe(
            windowReady: window != nil && window?.contentView != nil,
            touchBarEnabled: touchBarEnabled,
            touchBarInstalled: appTouchBar != nil,
            touchBarItemReady: !activeTouchBarIdentifiers.contains(pomodoroItemIdentifier) || globalTouchBarItems[pomodoroItemIdentifier] != nil,
            codexTouchBarItemReady: !activeTouchBarIdentifiers.contains(codexItemIdentifier) || globalTouchBarItems[codexItemIdentifier] != nil,
            quotaTouchBarItemReady: !activeTouchBarIdentifiers.contains(quotaItemIdentifier) || globalTouchBarItems[quotaItemIdentifier] != nil,
            workbuddyTouchBarItemReady: !activeTouchBarIdentifiers.contains(workbuddyItemIdentifier) || globalTouchBarItems[workbuddyItemIdentifier] != nil,
            tokenTouchBarItemReady: !activeTouchBarIdentifiers.contains(tokenItemIdentifier) || globalTouchBarItems[tokenItemIdentifier] != nil,
            renderCount: renderCount,
            pomodoroRunning: model.isRunning,
            pomodoroPhase: model.phase.rawValue,
            pomodoroCompletedToday: model.completedToday,
            remainingSeconds: model.remaining,
            codexStatus: codexMonitor.snapshot.state.rawValue,
            codexUpdatedAt: codexMonitor.snapshot.updatedAt,
            quotaRemainingPercent: quotaMonitor.snapshot.remainingPercent,
            quotaMinimumRemainingPercent: quotaMonitor.snapshot.minimumRemainingPercent,
            quotaResetAt: quotaMonitor.snapshot.resetAt,
            workbuddyStatus: workbuddyMonitor.snapshot.state.rawValue,
            workbuddyUpdatedAt: workbuddyMonitor.snapshot.updatedAt,
            todayTokens: tokenMonitor.snapshot.tokens,
            todayTokensUpdatedAt: tokenMonitor.snapshot.updatedAt,
            todayTokensStale: tokenMonitor.snapshot.stale,
            touchBarLayoutMode: touchBarTextMode == .compact ? "compact" : "full",
            touchBarResolvedItemCount: touchBarResolvedItemCount,
            touchBarVisibleItemCount: touchBarVisibleItemCount,
            touchBarLayoutCheckedAt: touchBarLayoutCheckedAt,
            globalTouchBarEnabled: globalTouchBar.enabled,
            globalTouchBarSupported: globalTouchBar.supported,
            globalTouchBarPresented: globalTouchBar.presented,
            globalTouchBarActuallyVisible: globalTouchBar.actuallyVisible,
            globalTouchBarVisibilityCheckedAt: globalTouchBar.visibilityCheckedAt,
            globalTouchBarLastError: globalTouchBar.lastError,
            lastError: nil,
            betterTouchToolInstalled: betterTouchToolInstalled,
            betterTouchToolRunning: betterTouchToolRunning,
            expectedTouchBarItemCount: activeTouchBarIdentifiers.count,
            visibleMetricKeys: pluginManager.visibleKeys.filter { MetricID(rawValue: $0) != nil },
            metricSampledAt: metricsMonitor.snapshot.readings.mapValues(\.sampledAt),
            sensorError: metricsMonitor.snapshot.sensorError,
            fanControlPhase: fanClient.status?.phase.rawValue,
            fanControlMessage: fanClient.message,
            fanControlConnected: fanClient.connected,
            fanControlInstalled: fanClient.isInstalled,
            fanControlHelperUpdateRequired: fanClient.helperUpdateRequired
        )
    }

    func windowDidBecomeMain(_ notification: Notification) {
        healthMonitor.refresh()
    }

    func windowDidResignMain(_ notification: Notification) {
        healthMonitor.refresh()
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        let contentIdentifier = canonicalTouchBarIdentifier(identifier)
        if contentIdentifier == moreItemIdentifier {
            return NSButtonTouchBarItem(identifier: identifier, title: "更多", target: self, action: #selector(togglePerformancePage))
        }
        if contentIdentifier == systemControlsItemIdentifier {
            let item = NSButtonTouchBarItem(identifier: identifier, title: "系统控制", target: self, action: #selector(openSystemControlsFromTouchBar))
            item.customizationLabel = "系统控制 · 点按打开，长按静音"
            item.visibilityPriority = .high
            if let button = item.view as? NSButton {
                button.setAccessibilityHelp("点按打开音量与媒体面板；长按切换静音")
                let press = NSPressGestureRecognizer(target: self, action: #selector(toggleMuteFromTouchBar(_:)))
                press.minimumPressDuration = 0.65
                press.delaysPrimaryMouseButtonEvents = true
                button.addGestureRecognizer(press)
            }
            return item
        }
        if contentIdentifier == backItemIdentifier || contentIdentifier == fanToggleIdentifier {
            let item = NSButtonTouchBarItem(identifier: identifier, title: contentIdentifier == backItemIdentifier ? "返回" : fixedControlTitle, target: self, action: contentIdentifier == backItemIdentifier ? #selector(togglePerformancePage) : #selector(toggleFixedFromTouchBar))
            configureFixedWidth(item, width: contentIdentifier == backItemIdentifier ? 52 : 108)
            return item
        }
        if contentIdentifier.rawValue.hasPrefix(metricItemPrefix) {
            let key = String(contentIdentifier.rawValue.dropFirst(metricItemPrefix.count))
            let item = NSButtonTouchBarItem(identifier: identifier, title: metricTouchBarText(key), target: self, action: #selector(showMetricsFromTouchBar))
            if [MetricID.fans.rawValue, MetricID.fan0.rawValue, MetricID.fan1.rawValue].contains(key) { item.action = #selector(showFanControlFromTouchBar) }
            item.bezelColor = metricColor(key)
            item.customizationLabel = MetricID(rawValue: key)?.name
            configureFixedWidth(item, width: fixedWidth(for: key))
            return item
        }
        if let runtime = pluginManager.runtime(for: contentIdentifier) {
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: runtime.displayText,
                target: runtime,
                action: #selector(ScriptPluginRuntime.handleTouchBarAction)
            )
            item.customizationLabel = runtime.definition.name
            item.image = runtime.image
            item.visibilityPriority = .high
            return item
        }

        switch contentIdentifier {
        case quotaItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: gptUsageTouchBarText,
                target: self,
                action: #selector(refreshUsageFromTouchBar)
            )
            item.customizationLabel = "7天额度"
            item.visibilityPriority = .low
            item.bezelColor = TouchBarStateColors.quota(
                quotaMonitor.snapshot.minimumRemainingPercent,
                isStale: quotaMonitor.snapshot.isStale
            )
            quotaTouchBarButton = item
            return item

        case workbuddyItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: workbuddyTouchBarText,
                target: self,
                action: #selector(handleWorkBuddyFromTouchBar)
            )
            item.customizationLabel = "WorkBuddy AI 国际版状态"
            item.image = workbuddyTouchBarIcon
            item.bezelColor = TouchBarStateColors.activity(workbuddyMonitor.snapshot.state)
            item.visibilityPriority = .low
            workbuddyTouchBarButton = item
            return item

        case agentSpeedItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: agentSpeedTouchBarText,
                target: self,
                action: #selector(handleAgentSpeedFromTouchBar)
            )
            item.customizationLabel = "AI 速度（国际版/国内版/Codex）"
            item.bezelColor = TouchBarStateColors.activity(agentSpeedMonitor.bundle.primary.state)
            item.visibilityPriority = .low
            agentSpeedTouchBarButton = item
            return item

        case tokenItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: tokenTouchBarText,
                target: self,
                action: #selector(copyTokenFromTouchBar)
            )
            item.customizationLabel = "词元"
            item.bezelColor = TouchBarStateColors.tokens(tokenMonitor.snapshot)
            item.visibilityPriority = .low
            tokenTouchBarButton = item
            return item

        case codexItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: gptStatusTouchBarText,
                target: self,
                action: #selector(handleCodexFromTouchBar)
            )
            item.customizationLabel = "ChatGPT状态"
            item.image = codexTouchBarIcon
            item.bezelColor = TouchBarStateColors.activity(codexMonitor.snapshot.state)
            item.visibilityPriority = .low
            codexTouchBarButton = item
            return item

        case pomodoroItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: pomodoroTouchBarText,
                target: self,
                action: #selector(togglePomodoroFromTouchBar)
            )
            item.customizationLabel = "🍅"
            item.bezelColor = TouchBarStateColors.pomodoro(
                phase: model.phase,
                isRunning: model.isRunning
            )
            item.visibilityPriority = .low
            configurePomodoroTouchBarItem(item)
            touchBarButton = item
            return item

        case pomodoroResetItemIdentifier:
            let item = NSButtonTouchBarItem(
                identifier: identifier,
                title: "↺",
                target: self,
                action: #selector(resetPomodoroFromTouchBar)
            )
            item.customizationLabel = "重置番茄钟"
            item.visibilityPriority = .high
            touchBarResetButton = item
            return item

        default:
            return nil
        }
    }

    @objc private func togglePomodoroFromTouchBar() {
        togglePomodoro()
    }

    @objc private func resetPomodoroFromTouchBar() {
        resetPomodoro()
    }

    @objc private func openSystemControlsFromTouchBar() { showSystemControls() }
    @objc private func toggleMuteFromTouchBar(_ recognizer: NSPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        toggleSystemMute()
    }

    @objc private func refreshCodexFromTouchBar() {
        refreshCodexStatus()
    }

    @objc private func handleCodexFromTouchBar() {
        refreshCodexStatus()
        guard codexMonitor.snapshot.needsAttention else { return }
        _ = openApplicationIfAvailable(
            at: [
                "/Applications/ChatGPT.app",
                "/Applications/Codex.app",
            ]
        )
    }

    @objc private func handleWorkBuddyFromTouchBar() {
        workbuddyMonitor.refresh()
        guard workbuddyMonitor.snapshot.needsAttention else { return }
        _ = openApplicationIfAvailable(
            at: [
                "/Applications/WorkBuddy AI.app",
            ]
        )
    }

    @objc private func handleAgentSpeedFromTouchBar() {
        agentSpeedMonitor.refresh()
    }

    @objc private func copyTokenFromTouchBar() {
        tokenMonitor.refresh()
        copyToPasteboard(tokenMonitor.snapshot.menuText)
    }

    @objc private func refreshUsageFromTouchBar() {
        refreshUsageStatus()
    }

    private func openApplicationIfAvailable(at paths: [String]) -> Bool {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func handlePomodoroCompletion(
        _ message: String,
        kind: PomodoroModel.CompletionKind
    ) {
        if pomodoroSoundReminderEnabled() {
            playPomodoroCompletionSound(
                repeatCount: kind == .focusFinished ? 2 : 1
            )
        }

        guard kind == .focusFinished else { return }

        NSApp.requestUserAttention(.criticalRequest)
        Self.sendPomodoroNotification(message)

        guard pomodoroPopupReminderEnabled() else { return }
        DispatchQueue.main.async { [weak self] in
            self?.presentPomodoroPopup(message)
        }
    }

    private func playPomodoroCompletionSound(repeatCount: Int) {
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
            if repeatCount > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    sound.play()
                }
            }
        } else {
            NSSound.beep()
            if repeatCount > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                    NSSound.beep()
                }
            }
        }
    }

    private func presentPomodoroPopup(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "番茄钟完成"
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        activePomodoroAlert = alert
        NSApp.activate(ignoringOtherApps: true)

        if let window, window.isVisible, !window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
            alert.beginSheetModal(for: window) { [weak self] _ in
                self?.activePomodoroAlert = nil
            }
        } else {
            alert.runModal()
            activePomodoroAlert = nil
        }
    }

    private static func requestPomodoroNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    touchBarLogger.error(
                        "Pomodoro notification authorization failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private static func sendPomodoroNotification(_ message: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                enqueuePomodoroNotification(message, with: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        touchBarLogger.error(
                            "Pomodoro notification authorization failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    if granted {
                        enqueuePomodoroNotification(message, with: center)
                    }
                }
            default:
                touchBarLogger.notice("Pomodoro notification is disabled by the user")
            }
        }
    }

    private static func enqueuePomodoroNotification(
        _ message: String,
        with center: UNUserNotificationCenter
    ) {
        let content = UNMutableNotificationContent()
        content.title = "番茄钟完成"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "pomodoro-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                touchBarLogger.error(
                    "Unable to schedule pomodoro notification: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func buildWindowContents() {
        guard let contentView = window?.contentView else { return }

        titleLabel = NSTextField(labelWithString: touchBarEnabled ? "GoodTouchBar" : "GoodTouchBar · 菜单栏模式")
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 30, y: 252, width: 460, height: 30)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 30, y: 177, width: 460, height: 52)

        codexLabel = NSTextField(labelWithString: "")
        codexLabel.font = .systemFont(ofSize: 13)
        codexLabel.textColor = .secondaryLabelColor
        codexLabel.alignment = .center
        codexLabel.frame = NSRect(x: 30, y: 148, width: 460, height: 20)

        statsLabel = NSTextField(labelWithString: "")
        statsLabel.font = .systemFont(ofSize: 13)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .center
        statsLabel.frame = NSRect(x: 30, y: 122, width: 460, height: 20)

        usageLabel = NSTextField(labelWithString: "")
        usageLabel.font = .systemFont(ofSize: 12)
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.alignment = .center
        usageLabel.lineBreakMode = .byTruncatingMiddle
        usageLabel.frame = NSRect(x: 30, y: 96, width: 460, height: 20)

        actionButton = makeButton(title: "开始", x: 35, width: 100, action: #selector(togglePomodoroFromWindow))
        shortBreakButton = makeButton(title: "短休息", x: 145, width: 100, action: #selector(startShortBreakFromWindow))
        longBreakButton = makeButton(title: "长休息", x: 255, width: 100, action: #selector(startLongBreakFromWindow))
        resetButton = makeButton(title: "重置", x: 365, width: 100, action: #selector(resetPomodoroFromWindow))

        contentView.addSubview(titleLabel)
        contentView.addSubview(statusLabel)
        contentView.addSubview(codexLabel)
        contentView.addSubview(statsLabel)
        contentView.addSubview(usageLabel)
        contentView.addSubview(actionButton)
        contentView.addSubview(shortBreakButton)
        contentView.addSubview(longBreakButton)
        contentView.addSubview(resetButton)
        if !touchBarEnabled {
            statusLabel.isHidden = true
            statsLabel.isHidden = true
            actionButton.isHidden = true
            shortBreakButton.isHidden = true
            longBreakButton.isHidden = true
            resetButton.isHidden = true
        }
    }

    private func makeButton(title: String, x: CGFloat, width: CGFloat, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: 50, width: width, height: 32)
        return button
    }

    @objc private func startShortBreakFromWindow() {
        startShortBreak()
    }

    @objc private func togglePomodoroFromWindow() {
        togglePomodoro()
    }

    @objc private func startLongBreakFromWindow() {
        startLongBreak()
    }

    @objc private func resetPomodoroFromWindow() {
        resetPomodoro()
    }

    private func installTouchBar() {
        guard touchBarEnabled else { return }

        var visibleItemIdentifiers: [NSTouchBarItem.Identifier] = []
        if performancePage {
            visibleItemIdentifiers = [backItemIdentifier] + MetricID.performancePreset.compactMap { touchBarIdentifier(for:$0) } + [fanToggleIdentifier]
            overflowKeys = []
        } else {
            var remaining = Double(availableTouchBarWidth()) - 72
            overflowKeys = []
            for key in pluginManager.visibleKeys {
                let width = Double(fixedWidth(for:key)) + 8
                if overflowKeys.isEmpty, width <= remaining, let id = touchBarIdentifier(for:key) { visibleItemIdentifiers.append(id); remaining -= width }
                else { overflowKeys.append(key) }
            }
            visibleItemIdentifiers.append(moreItemIdentifier)
        }
        activeTouchBarIdentifiers = visibleItemIdentifiers
        let allowedItemIdentifiers = pluginManager.allKeys.compactMap {
            touchBarIdentifier(for: $0)
        }
        // AppKit changes a window's Touch Bar ownership when it is minimized.
        // Each presentation needs its own bar and its own item views.
        appTouchBar = makeConfiguredTouchBar(
            visible: visibleItemIdentifiers.map(windowTouchBarIdentifier),
            allowed: allowedItemIdentifiers.map(windowTouchBarIdentifier)
        )
        window?.touchBar = appTouchBar
        globalTouchBar = makeGlobalTouchBar(visible: visibleItemIdentifiers)
        scheduleTouchBarLayoutCheck()
        touchBarLogger.notice("Independent window and global Touch Bars installed")
    }

    private func makeConfiguredTouchBar(
        visible visibleItemIdentifiers: [NSTouchBarItem.Identifier],
        allowed allowedItemIdentifiers: [NSTouchBarItem.Identifier]
    ) -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = visibleItemIdentifiers
        touchBar.customizationAllowedItemIdentifiers = allowedItemIdentifiers
        // 先实例化一次，避免系统尚未主动请求 Touch Bar 时健康检查长期停留在 waiting。
        for identifier in visibleItemIdentifiers {
            _ = touchBar.item(forIdentifier: identifier)
        }
        return touchBar
    }

    private func makeGlobalTouchBar(
        visible identifiers: [NSTouchBarItem.Identifier]
    ) -> NSTouchBar {
        let bar = NSTouchBar()
        let containerIdentifier = NSTouchBarItem.Identifier("io.github.yihuirui.goodtouchbar.global.content")
        let container = NSCustomTouchBarItem(identifier: containerIdentifier)
        globalTouchBarItems.removeAll()
        let views = identifiers.compactMap { identifier -> NSView? in
            guard let item = touchBar(bar, makeItemForIdentifier: identifier) as? NSButtonTouchBarItem
            else { return nil }
            globalTouchBarItems[identifier] = item
            if identifier == moreItemIdentifier { configureFixedWidth(item, width: 64) }
            else if !identifier.rawValue.hasPrefix(metricItemPrefix), identifier != pomodoroItemIdentifier, identifier != backItemIdentifier, identifier != fanToggleIdentifier {
                if let key = pluginManager.visibleKeys.first(where: { touchBarIdentifier(for: $0) == identifier }) { configureFixedWidth(item, width: fixedWidth(for: key)) }
            }
            return item.view
        }
        // System-modal presentation must retain one complete view hierarchy
        // across window minimization and app switches, rather than item hosts.
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        container.view = stack
        bar.templateItems = [container]
        bar.defaultItemIdentifiers = [containerIdentifier]
        return bar
    }

    private func windowTouchBarIdentifier(
        _ identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier(Self.windowItemPrefix + identifier.rawValue)
    }

    private func canonicalTouchBarIdentifier(
        _ identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem.Identifier {
        guard identifier.rawValue.hasPrefix(Self.windowItemPrefix) else { return identifier }
        return NSTouchBarItem.Identifier(
            String(identifier.rawValue.dropFirst(Self.windowItemPrefix.count))
        )
    }

    private func touchBarIdentifier(for key: String) -> NSTouchBarItem.Identifier? {
        if MetricID(rawValue: key) != nil { return NSTouchBarItem.Identifier(metricItemPrefix + key) }
        switch key {
        case TouchBarPluginKey.gptStatus: return codexItemIdentifier
        case TouchBarPluginKey.gptUsage: return quotaItemIdentifier
        case TouchBarPluginKey.workbuddy: return workbuddyItemIdentifier
        case TouchBarPluginKey.agentSpeed: return agentSpeedItemIdentifier
        case TouchBarPluginKey.todayTokens: return tokenItemIdentifier
        case TouchBarPluginKey.pomodoro: return pomodoroItemIdentifier
        case TouchBarPluginKey.pomodoroReset: return pomodoroResetItemIdentifier
        case TouchBarPluginKey.systemControls: return systemControlsItemIdentifier
        default: return pluginManager.identifier(for: key)
        }
    }

    private func scheduleTouchBarLayoutCheck() {
        touchBarLayoutCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.renderAndNotify()
        }
        touchBarLayoutCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.25,
            execute: workItem
        )
    }

    private func updateTouchBarTextMode() {
        let nextMode: TouchBarTextMode = estimatedFullTouchBarWidth() > availableTouchBarWidth()
            ? .compact
            : .full
        guard nextMode != touchBarTextMode else { return }
        touchBarTextMode = nextMode
        touchBarLogger.notice(
            "Touch Bar text mode changed: \(nextMode == .compact ? "compact" : "full", privacy: .public)"
        )
    }

    private func availableTouchBarWidth() -> CGFloat {
        let displayedBar = globalTouchBar ?? appTouchBar
        let itemViews: [NSView]
        if globalTouchBar != nil {
            itemViews = globalTouchBarItems.values.compactMap(\.view)
        } else {
            itemViews = displayedBar?.itemIdentifiers.compactMap {
                (displayedBar?.item(forIdentifier: $0) as? NSButtonTouchBarItem)?.view
            } ?? []
        }

        let measuredWidth = itemViews.compactMap { view -> CGFloat? in
            var current: NSView? = view
            var largest: CGFloat = 0
            while let candidate = current {
                largest = max(largest, candidate.bounds.width)
                current = candidate.superview
            }
            return largest > 600 ? largest : nil
        }.max()

        if let measuredWidth {
            return max(64, min(900, measuredWidth - 24))
        }

        return 650 // Conservative content budget until AppKit reports a measured width.
    }

    @objc private func togglePerformancePage() {
        performancePage.toggle(); metricsMonitor.performancePage = performancePage
        fanClient.quickControlsVisible = performancePage
        if performancePage { fanClient.refresh() }
        installTouchBar(); renderAndNotify(remeasureTouchBar: false)
        if let bar = globalTouchBar { onTouchBarRebuilt?(bar) }
    }
    private var fixedControlTitle: String {
        if fanClient.quickModePending { return "切换中…" }
        if fanClient.status?.phase == .recoveryFailed { return "重试自动" }
        if fanClient.hasControl { return "固定→自动" }
        if fanClient.status?.phase == .controlling { return "外部控制" }
        if fanClient.status?.phase == .recovering { return "恢复中…" }
        if !fanClient.connected { return "连接服务…" }
        return "自动→固定"
    }
    @objc private func toggleFixedFromTouchBar() {
        guard !fanClient.installationBusy else { return }
        if fanClient.hasControl || fanClient.status?.phase == .recoveryFailed { fanClient.toggleFixedMode(); return }
        if !fanClient.isInstalled && !fanClient.connected || fanClient.helperUpdateRequired { showFanControl(); return }
        fanClient.toggleFixedMode()
    }
    private func metricColor(_ key:String) -> NSColor? {
        switch MetricThresholds.level(key,snapshot:metricsMonitor.snapshot,overrides:pluginManager.configuration.metricThresholds ?? [:]) {
        case .critical: return .systemRed
        case .warning: return .systemOrange
        case .normal: return nil
        case .unavailable: return .darkGray
        }
    }
    private func metricTouchBarText(_ key: String) -> String {
        let snapshot = metricsMonitor.snapshot
        if performancePage, key == MetricID.memory.rawValue {
            guard let used = snapshot.readings[key], used.isFresh(), let value = used.value,
                  let total = snapshot.readings["memory.total"], total.isFresh(), let capacity = total.value, capacity > 0 else { return "内存 --" }
            return String(format:"内存 %.0f%%", min(100,max(0,value/capacity*100)))
        }
        if performancePage, key == MetricID.fans.rawValue {
            guard snapshot.readings[key]?.isFresh() == true else { return "风扇 -- RPM" }
            return snapshot.fans.prefix(2).map { $0.actual.map { String(format:"%.0f",$0) } ?? "--" }.joined(separator:"/") + " RPM"
        }
        return displayText(for:key)
    }
    private static let incidentNames = ["fan_recovery_failed":"风扇恢复自动失败，请打开调速窗口检查", "fan_disconnected":"风扇辅助服务断连，正在重新连接", "sensor_failed":"传感器暂不可用", "wb_stopped":"WB 监控异常，请检查会话与后台通道"]
    private var incidentSummary: String {
        let messages = incidents.active.sorted().compactMap { Self.incidentNames[$0] }
        return (messages + (notificationNotice.isEmpty ? [] : [notificationNotice])).joined(separator:"\n").isEmpty ? "暂无异常" : (messages + (notificationNotice.isEmpty ? [] : [notificationNotice])).joined(separator:"\n")
    }
    private func updateIncidents() {
        var conditions = Set<String>()
        if fanClient.connected { fanWasConnected = true }
        if fanWasConnected && !fanClient.connected && !fanClient.installationBusy && fanClient.isInstalled { conditions.insert("fan_disconnected") }
        if fanClient.status?.phase == .recoveryFailed { conditions.insert("fan_recovery_failed") }
        if metricsMonitor.snapshot.sensorError != nil { conditions.insert("sensor_failed") }
        if !wbStopRequested && [.running, .waiting, .completed].contains(workbuddyMonitor.snapshot.state) { requestedWBMonitoring = true }
        if requestedWBMonitoring && ([.error, .stale].contains(workbuddyMonitor.snapshot.state) || workbuddyMonitor.snapshot.title == "监控停止") { conditions.insert("wb_stopped") }
        let changes = incidents.update(conditions)
        if !changes.recovered.isEmpty {
            let ids = changes.recovered.map { "goodtouchbar.incident." + $0 }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:ids)
        }
        guard notificationsEnabled else { return }
        for key in changes.raised {
            let content = UNMutableNotificationContent(); content.title = "GoodTouchBar 运行异常"; content.body = Self.incidentNames[key] ?? "请查看运行状态"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"goodtouchbar.incident." + key, content:content, trigger:nil))
        }
    }
    private func setIncidentNotifications(_ enabled: Bool) {
        notificationNotice = ""
        notificationGeneration += 1; let generation = notificationGeneration
        if !enabled {
            notificationsEnabled = false; UserDefaults.standard.set(false,forKey:"diagnosticNotifications")
            let ids = Self.incidentNames.keys.map { "goodtouchbar.incident." + $0 }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:ids)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers:ids)
            monitorSettings?.notificationsEnabled = false; monitorSettings?.render(); return
        }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self, self.notificationGeneration == generation else { return }; self.notificationsEnabled = granted
                UserDefaults.standard.set(granted,forKey:"diagnosticNotifications")
                self.notificationNotice = granted ? "" : "通知未获授权；可在系统设置中开启，面板仍显示异常。"
                self.monitorSettings?.notificationsEnabled = granted; self.monitorSettings?.render()
            }
        }
    }

    private func fixedWidth(for key: String) -> CGFloat {
        if performancePage {
            switch MetricID(rawValue:key) { case .cpu: return 86; case .memory: return 94; case .cpuTemperature: return 100; case .fans: return 162; default: break }
        }
        switch MetricID(rawValue: key) {
        case .fans: return 174
        case .memory: return 150
        case .cpuTemperature, .gpuTemperature, .batteryTemperature: return 116
        case .cpu, .pressure, .swap, .fan0, .fan1: return 116
        case nil:
            if key == TouchBarPluginKey.pomodoro { return TouchBarLayout.pomodoroWidth }
            if key == TouchBarPluginKey.pomodoroReset { return 44 }
            return min(220, max(80, estimatedButtonWidth(for: displayText(for: key))))
        }
    }
    private func configureFixedWidth(_ item: NSButtonTouchBarItem, width: CGFloat) {
        guard let button = item.view as? NSButton else { return }
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    private func estimatedFullTouchBarWidth() -> CGFloat {
        pluginManager.visibleKeys.reduce(0) { $0 + fixedWidth(for: $1) } + CGFloat(max(0,pluginManager.visibleKeys.count - 1))*8
    }

    private func estimatedButtonWidth(for text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
        ]
        let textWidth = ceil((text as NSString).size(withAttributes: attributes).width)
        return textWidth + 30
    }

    private func configurePomodoroTouchBarItem(_ item: NSButtonTouchBarItem) {
        guard let button = item.view as? NSButton else {
            touchBarLogger.error("Unable to access the Pomodoro Touch Bar button view")
            return
        }

        button.font = TouchBarLayout.pomodoroFont
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let widthConstraint = button.widthAnchor.constraint(
            equalToConstant: TouchBarLayout.pomodoroWidth
        )
        widthConstraint.priority = .required
        widthConstraint.isActive = true
    }

    private func renderAndNotify(remeasureTouchBar: Bool = true) {
        if touchBarEnabled && remeasureTouchBar {
            updateTouchBarTextMode()
        }
        render()
        if touchBarEnabled && remeasureTouchBar {
            updateTouchBarLayoutDiagnostics()
        }
        onChange?()
    }

    private func updateTouchBarLayoutDiagnostics(for bar: NSTouchBar? = nil) {
        guard let bar = bar ?? globalTouchBar ?? appTouchBar else { return }
        if bar === globalTouchBar {
            touchBarResolvedItemCount = globalTouchBarItems.count
            touchBarVisibleItemCount = bar.isVisible ? globalTouchBarItems.values.filter {
                $0.view?.isHiddenOrHasHiddenAncestor == false
            }.count : 0
            touchBarLayoutCheckedAt = Date()
            return
        }
        let identifiers = bar.itemIdentifiers
        touchBarResolvedItemCount = identifiers.count
        touchBarVisibleItemCount = identifiers.reduce(into: 0) { count, identifier in
            if bar.item(forIdentifier: identifier)?.isVisible == true {
                count += 1
            }
        }
        touchBarLayoutCheckedAt = Date()
    }

    private func render() {
        renderCount += 1
        updateIncidents()
        statusLabel?.stringValue = model.displayText
        codexLabel?.stringValue = gptStatusWindowText
        statsLabel?.stringValue = model.statsText
        usageLabel?.stringValue = [
            gptUsageWindowText,
            workbuddyMonitor.snapshot.windowText,
            tokenMonitor.snapshot.windowText,
        ].joined(separator: " · ")
        actionButton?.title = model.actionText
        var displayedItems = globalTouchBarItems
        if let appTouchBar {
            for identifier in appTouchBar.defaultItemIdentifiers {
                displayedItems[identifier] = appTouchBar.item(forIdentifier: identifier) as? NSButtonTouchBarItem
            }
        }
        for (identifier, item) in displayedItems {
            let contentIdentifier = canonicalTouchBarIdentifier(identifier)
            if contentIdentifier.rawValue.hasPrefix(metricItemPrefix) {
                let key = String(contentIdentifier.rawValue.dropFirst(metricItemPrefix.count))
                item.title = metricTouchBarText(key)
                item.bezelColor = metricColor(key)
                continue
            }
            switch contentIdentifier {
            case fanToggleIdentifier:
                item.title = fixedControlTitle
                item.isEnabled = !fanClient.quickModePending && !fanClient.installationBusy
                item.bezelColor = fanClient.hasControl ? .systemBlue : nil
            case quotaItemIdentifier:
                item.title = gptUsageTouchBarText
                item.bezelColor = TouchBarStateColors.quota(
                    quotaMonitor.snapshot.minimumRemainingPercent,
                    isStale: quotaMonitor.snapshot.isStale
                )
            case workbuddyItemIdentifier:
                item.title = workbuddyTouchBarText
                item.image = workbuddyTouchBarIcon
                item.bezelColor = TouchBarStateColors.activity(workbuddyMonitor.snapshot.state)
            case agentSpeedItemIdentifier:
                item.title = agentSpeedTouchBarText
                item.bezelColor = TouchBarStateColors.activity(agentSpeedMonitor.bundle.primary.state)
            case tokenItemIdentifier:
                item.title = tokenTouchBarText
                item.bezelColor = TouchBarStateColors.tokens(tokenMonitor.snapshot)
            case pomodoroItemIdentifier:
                item.title = pomodoroTouchBarText
                item.bezelColor = TouchBarStateColors.pomodoro(
                    phase: model.phase,
                    isRunning: model.isRunning
                )
            case codexItemIdentifier:
                item.title = gptStatusTouchBarText
                item.image = codexTouchBarIcon
                item.bezelColor = TouchBarStateColors.activity(codexMonitor.snapshot.state)
            default:
                if let runtime = pluginManager.runtime(for: contentIdentifier) {
                    item.title = runtime.displayText
                    item.image = runtime.image
                }
            }
        }
    }

    private var gptStatusTouchBarText: String {
        let state: String
        switch codexMonitor.snapshot.state {
        case .idle: state = "待命"
        case .running: state = "执行"
        case .waiting: state = "确认"
        case .completed: state = "完成"
        case .stale: state = "过期"
        case .error: state = "错误"
        }
        return "ChatGPT·\(state)"
    }

    private var gptUsageTouchBarText: String {
        quotaMonitor.snapshot.touchBarText
    }

    private var workbuddyTouchBarText: String {
        workbuddyMonitor.snapshot.compactTouchBarText
    }

    private var agentSpeedTouchBarText: String {
        agentSpeedMonitor.bundle.touchBarText
    }

    private var codexTouchBarIcon: NSImage? {
        TouchBarAgentIcon.image(named: "codex-status-icon")
    }

    private var workbuddyTouchBarIcon: NSImage? {
        return TouchBarAgentIcon.image(named: "workbuddy-status-icon")
    }

    private var tokenTouchBarText: String {
        tokenMonitor.snapshot.touchBarText
    }

    private var pomodoroTouchBarText: String {
        model.compactTouchBarText
    }

    private var gptStatusWindowText: String {
        let snapshot = codexMonitor.snapshot
        let status = snapshot.detail.isEmpty
            ? snapshot.title
            : "\(snapshot.title) · \(snapshot.detail)"
        return "ChatGPT状态：\(status)"
    }

    private var gptUsageWindowText: String {
        quotaMonitor.snapshot.windowText
    }

}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController!
    private var pomodoroStatusItem: NSStatusItem?
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu?
    private var statusDetailsPopover: StatusDetailsPopoverController?
    private var healthMonitor: HealthMonitor!
    private var globalTouchBarPresenter: GlobalTouchBarPresenter?
    private var healthMenuItem: NSMenuItem!
    private var globalTouchBarMenuItem: NSMenuItem?
    private var pomodoroMenuItem: NSMenuItem?
    private var pomodoroResetMenuItem: NSMenuItem?
    private var pomodoroSoundMenuItem: NSMenuItem?
    private var pomodoroPopupMenuItem: NSMenuItem?
    private var codexMenuItem: NSMenuItem!
    private var quotaMenuItem: NSMenuItem!
    private var workbuddyMenuItem: NSMenuItem!
    private var agentSpeedParentMenuItem: NSMenuItem!
    private var agentSpeedMenuItems: [AgentSpeedSource: NSMenuItem] = [:]
    private var tokenMenuItem: NSMenuItem!
    private var fanControlMenuItem: NSMenuItem?
    private var fanHelperMenuItem: NSMenuItem?
    private var healthStatusIcon = "⚡…"
    private var statusBarVisibilityTimer: Timer?
    private var appUsesTouchBar = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        StandardStreamLogLimiter.shared.start()
        NSApp.applicationIconImage = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "goodtouchbar")
        let capabilities = GoodTouchBarDeviceCapabilities.current
        let modeResolution = GoodTouchBarRuntimeConfiguration.resolution(capabilities: capabilities)
        appUsesTouchBar = modeResolution.enabled
        if appUsesTouchBar {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        touchBarLogger.notice("applicationDidFinishLaunching")

        healthMonitor = HealthMonitor()
        windowController = MainWindowController(healthMonitor: healthMonitor, touchBarEnabled: appUsesTouchBar, deviceCapabilities: capabilities)
        if appUsesTouchBar,
           let touchBar = windowController.touchBarForGlobalPresentation() {
            let presenter = GlobalTouchBarPresenter(touchBar: touchBar)
            globalTouchBarPresenter = presenter
            windowController.onTouchBarRebuilt = { [weak self] touchBar in
                self?.globalTouchBarPresenter?.replaceTouchBar(touchBar)
                _ = self?.healthMonitor.refresh()
            }
        }

        if appUsesTouchBar {
        pomodoroStatusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        // Give the system menu-bar layout a stable identity for this item. Without
        // an autosave name, macOS can retain a stale/off-screen placement after a
        // menu-bar restart, especially for a background-only app.
        pomodoroStatusItem?.autosaveName = NSStatusItem.AutosaveName(
            "io.github.yihuirui.goodtouchbar.pomodoro"
        )
        pomodoroStatusItem?.button?.target = self
        pomodoroStatusItem?.button?.action = #selector(startPomodoroFromStatusBar)
        pomodoroStatusItem?.button?.sendAction(on: [.leftMouseUp])
        pomodoroStatusItem?.button?.title = "🍅--"
        pomodoroStatusItem?.button?.font = .monospacedDigitSystemFont(
            ofSize: 11,
            weight: .regular
        )
        pomodoroStatusItem?.button?.contentTintColor = NSColor.black
        pomodoroStatusItem?.button?.toolTip = "点击开始番茄钟"
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = NSStatusItem.AutosaveName(
            "io.github.yihuirui.goodtouchbar.summary"
        )
        statusItem.button?.image = NSImage(
            systemSymbolName: "bolt.horizontal.circle",
            accessibilityDescription: "goodtouchbar 状态详情"
        )
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleStatusItemAction)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem.button?.setAccessibilityLabel("goodtouchbar 状态详情")
        statusItem.button?.setAccessibilityHelp("点击查看状态详情；右键打开完整菜单")
        statusItem.button?.toolTip = "goodtouchbar · 点击查看状态详情 · 右键打开完整菜单"

        let menu = NSMenu()
        let openItem = menu.addItem(
            withTitle: "打开 GoodTouchBar",
            action: #selector(showMainWindow),
            keyEquivalent: "o"
        )
        openItem.target = self

        if globalTouchBarPresenter != nil {
            menu.addItem(.separator())
            globalTouchBarMenuItem = menu.addItem(
                withTitle: "全局常驻 Touch Bar（实验）",
                action: #selector(toggleGlobalTouchBar),
                keyEquivalent: "g"
            )
            globalTouchBarMenuItem?.target = self
        }

        menu.addItem(.separator())
        let controlsItem = menu.addItem(withTitle: "系统控制…", action: #selector(showSystemControls), keyEquivalent: "")
        controlsItem.target = self
        if windowController.fanControlAvailable {
            let fanItem = menu.addItem(withTitle: "风扇调速…", action: #selector(showFanControl), keyEquivalent: "")
            fanItem.target = self
            fanControlMenuItem = fanItem
            // 辅助服务绑定到签名哈希，只在确认 Intel 原生机上提供安装入口。
            let helperItem = menu.addItem(withTitle: "更新风扇辅助服务…", action: #selector(installFanHelper), keyEquivalent: "")
            helperItem.target = self
            fanHelperMenuItem = helperItem
        } else {
            let fanInfo = menu.addItem(withTitle: "风扇由 macOS 自动管理（只读）", action: nil, keyEquivalent: "")
            fanInfo.isEnabled = false
        }
        let metricsItem = menu.addItem(withTitle: "性能监控与显示设置…", action: #selector(showMonitorSettings), keyEquivalent: ",")
        metricsItem.target = self
        let pluginConfigItem = menu.addItem(
            withTitle: "插件配置…",
            action: #selector(openPluginConfiguration),
            keyEquivalent: ""
        )
        pluginConfigItem.target = self
        let presetParent = NSMenuItem(title: "版式预设", action: nil, keyEquivalent: "")
        let presetMenu = NSMenu(title: "版式预设")
        for (filename, preset) in GoodTouchBarPresetCatalog.loadBundled() {
            let item = NSMenuItem(title: preset.name, action: #selector(applyBundledPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = filename
            presetMenu.addItem(item)
        }
        if presetMenu.items.isEmpty {
            let unavailable = NSMenuItem(title: "内置预设不可用", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            presetMenu.addItem(unavailable)
        }
        presetMenu.addItem(.separator())
        let importPreset = NSMenuItem(title: "导入…", action: #selector(importLayoutPreset), keyEquivalent: "")
        importPreset.target = self
        presetMenu.addItem(importPreset)
        let exportPreset = NSMenuItem(title: "导出当前版式…", action: #selector(exportLayoutPreset), keyEquivalent: "")
        exportPreset.target = self
        presetMenu.addItem(exportPreset)
        presetParent.submenu = presetMenu
        menu.addItem(presetParent)
        let reloadPluginsItem = menu.addItem(
            withTitle: "重新加载插件",
            action: #selector(reloadPluginConfiguration),
            keyEquivalent: "r"
        )
        reloadPluginsItem.target = self

        addPomodoroMenuItems(to: menu, enabled: appUsesTouchBar)

        menu.addItem(.separator())
        codexMenuItem = menu.addItem(
            withTitle: "ChatGPT状态：检查中",
            action: #selector(refreshCodexStatus),
            keyEquivalent: ""
        )
        codexMenuItem.target = self
        quotaMenuItem = menu.addItem(
            withTitle: "使用量：检查中",
            action: #selector(refreshUsageStatus),
            keyEquivalent: ""
        )
        quotaMenuItem.target = self
        workbuddyMenuItem = menu.addItem(
            withTitle: "WB状态：检查中",
            action: #selector(refreshUsageStatus),
            keyEquivalent: ""
        )
        workbuddyMenuItem.target = self

        // AI 速度：三个来源收在一个子菜单里，主菜单只留一行，避免状态行堆叠。
        let speedParent = NSMenuItem(title: "AI 速度", action: nil, keyEquivalent: "")
        let speedSubmenu = NSMenu(title: "AI 速度")
        for source in AgentSpeedSource.allCases {
            let item = NSMenuItem(
                title: "\(source.shortName) · 检查中",
                action: #selector(refreshAgentSpeed),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = source.rawValue
            speedSubmenu.addItem(item)
            agentSpeedMenuItems[source] = item
        }
        speedSubmenu.addItem(.separator())
        let speedSettings = NSMenuItem(
            title: "打开监控设置…",
            action: #selector(openMonitorSettingsFromMenu),
            keyEquivalent: ""
        )
        speedSettings.target = self
        speedSubmenu.addItem(speedSettings)
        speedParent.submenu = speedSubmenu
        menu.addItem(speedParent)
        agentSpeedParentMenuItem = speedParent

        // WB AI 重试：三个动作同样收进子菜单。
        let retryParent = NSMenuItem(title: "WB AI 重试", action: nil, keyEquivalent: "")
        let retrySubmenu = NSMenu(title: "WB AI 重试")
        for (title, action) in [
            ("开始监控与自动重试…", #selector(startWorkBuddyRetry)),
            ("更新会话与自动重试…", #selector(updateWorkBuddySession)),
            ("停止监控", #selector(stopWorkBuddyRetry)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            retrySubmenu.addItem(item)
        }
        retryParent.submenu = retrySubmenu
        menu.addItem(retryParent)
        tokenMenuItem = menu.addItem(
            withTitle: "词元：检查中",
            action: #selector(refreshUsageStatus),
            keyEquivalent: ""
        )
        tokenMenuItem.target = self
        menu.addItem(.separator())
        let diagnosticsParent = NSMenuItem(title: "诊断与恢复", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu(title: "诊断与恢复")
        healthMenuItem = NSMenuItem(
            title: "运行状态：检查中",
            action: nil,
            keyEquivalent: ""
        )
        healthMenuItem.isEnabled = false
        diagnosticsMenu.addItem(healthMenuItem)
        let checkItem = diagnosticsMenu.addItem(
            withTitle: "立即自检",
            action: #selector(runSelfCheck),
            keyEquivalent: "c"
        )
        checkItem.target = self
        let reportItem = diagnosticsMenu.addItem(
            withTitle: "打开健康报告",
            action: #selector(openHealthReport),
            keyEquivalent: "h"
        )
        reportItem.target = self
        let restoreItem = diagnosticsMenu.addItem(
            withTitle: "从备份恢复配置…",
            action: #selector(restoreConfigurationBackup),
            keyEquivalent: ""
        )
        restoreItem.target = self
        diagnosticsMenu.addItem(.separator())
        let copyStatusItem = diagnosticsMenu.addItem(
            withTitle: "复制当前状态",
            action: #selector(copyCurrentStatus),
            keyEquivalent: ""
        )
        copyStatusItem.target = self
        diagnosticsParent.submenu = diagnosticsMenu
        menu.addItem(diagnosticsParent)
        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: "退出",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu = menu
        ensureStatusBarItemsVisible()
        logStatusBarDiagnostics("launch")

        windowController.onChange = { [weak self] in
            self?.renderMenuControls()
        }
        healthMonitor.onSnapshot = { [weak self] snapshot in
            self?.renderHealth(snapshot)
        }
        globalTouchBarPresenter?.onChange = { [weak self] in
            self?.renderMenuControls()
            _ = self?.healthMonitor.refresh()
        }
        let details = StatusDetailsPopoverController(
            snapshot: windowController.statusDetailsSnapshot(menuBarMode: !appUsesTouchBar)
        )
        details.onMore = { [weak self] in self?.showFullStatusMenu() }
        details.onWorkBuddyAction = { [weak self] command in
            self?.windowController.controlWorkBuddyRetry(command)
        }
        details.onPerformanceDetails = { [weak self] in
            self?.windowController.showMonitorSettings(showDetails: true)
        }
        details.onDisplaySettings = { [weak self] in self?.windowController.showMonitorSettings() }
        details.onRefresh = { [weak self] in self?.windowController.refreshStatusDetails() }
        statusDetailsPopover = details
        renderMenuControls()
        windowController.startCollapsed()
        globalTouchBarPresenter?.start()
        startStatusBarVisibilityWatchdog()
        // The first menu-bar layout may happen before a launch agent has a
        // settled Control Center connection. Reassert the items after launch
        // and force a fresh layout if AppKit gave them an off-screen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshStatusBarLayout()
        }
        healthMonitor.start { [weak self] in
            guard let self else { return .empty }
            return self.windowController.healthProbe(
                globalTouchBar: self.globalTouchBarPresenter?.snapshot ?? .disabled
            )
        }
    }

    @discardableResult
    func addPomodoroMenuItems(to menu: NSMenu, enabled: Bool) -> Bool {
        guard enabled else { return false }
        menu.addItem(.separator())
        pomodoroMenuItem = menu.addItem(withTitle: "番茄钟", action: #selector(togglePomodoro), keyEquivalent: "")
        pomodoroMenuItem?.target = self
        pomodoroResetMenuItem = menu.addItem(withTitle: "重置番茄钟", action: #selector(resetPomodoro), keyEquivalent: "")
        pomodoroResetMenuItem?.target = self
        let shortBreakItem = menu.addItem(withTitle: "开始短休息", action: #selector(startShortBreak), keyEquivalent: "")
        shortBreakItem.target = self
        let longBreakItem = menu.addItem(withTitle: "开始长休息", action: #selector(startLongBreak), keyEquivalent: "")
        longBreakItem.target = self
        menu.addItem(.separator())
        pomodoroSoundMenuItem = menu.addItem(withTitle: "番茄钟结束声音", action: #selector(togglePomodoroSoundReminder), keyEquivalent: "")
        pomodoroSoundMenuItem?.target = self
        pomodoroPopupMenuItem = menu.addItem(withTitle: "番茄钟结束弹窗", action: #selector(togglePomodoroPopupReminder), keyEquivalent: "")
        pomodoroPopupMenuItem?.target = self
        let notificationSettingsItem = menu.addItem(withTitle: "打开系统通知设置…", action: #selector(openPomodoroNotificationSettings), keyEquivalent: "")
        notificationSettingsItem.target = self
        return true
    }

    @objc private func showMonitorSettings() { windowController.showMonitorSettings() }

    @objc private func handleStatusItemAction() {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showFullStatusMenu()
        } else {
            statusDetailsPopover?.toggle(relativeTo: button)
        }
    }

    private func showFullStatusMenu() {
        guard let menu = statusMenu, let button = statusItem?.button else { return }
        statusDetailsPopover?.close()
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        } else {
            _ = menu.popUp(
                positioning: nil,
                at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
                in: button
            )
        }
    }
    @objc private func showFanControl() { windowController.showFanControl() }
    @objc private func showSystemControls() { windowController.showSystemControls() }
    @objc private func installFanHelper() { windowController.installFanHelper() }

    @objc private func applyBundledPreset(_ sender: NSMenuItem) {
        guard let filename = sender.representedObject as? String,
              let preset = GoodTouchBarPresetCatalog.loadBundled().first(where: { $0.0 == filename })?.1 else {
            showPresetError("内置预设无法读取。")
            return
        }
        applyLayoutPreset(preset)
    }

    @objc private func importLayoutPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "导入预设"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  fileSize <= GoodTouchBarLayoutPreset.maximumBytes else { throw PresetError.tooLarge }
            let preset = try GoodTouchBarLayoutPreset.decode(Data(contentsOf: url))
            applyLayoutPreset(preset)
        } catch { showPresetError("预设未导入：\(error.localizedDescription)") }
    }

    @objc private func exportLayoutPreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "goodtouchbar-layout.json"
        panel.prompt = "导出版式"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try windowController.exportedPreset().encoded()
            try data.write(to: url, options: .atomic)
        } catch { showPresetError("预设未导出：\(error.localizedDescription)") }
    }

    private func applyLayoutPreset(_ preset: GoodTouchBarLayoutPreset) {
        do { try windowController.applyPreset(preset) }
        catch { showPresetError("预设未应用：\(error.localizedDescription)") }
    }

    private func showPresetError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "GoodTouchBar 版式预设"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func showMainWindow() {
        windowController.showMainWindow()
    }

    @objc private func togglePomodoro() {
        windowController.togglePomodoro()
    }

    @objc private func startPomodoroFromStatusBar() {
        windowController.startPomodoro()
    }

    private func startStatusBarVisibilityWatchdog() {
        statusBarVisibilityTimer?.invalidate()
        let timer = Timer(
            timeInterval: 10,
            target: self,
            selector: #selector(reassertStatusBarItems),
            userInfo: nil,
            repeats: true
        )
        statusBarVisibilityTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func reassertStatusBarItems() {
        ensureStatusBarItemsVisible()
        refreshStatusBarLayoutIfNeeded()
    }

    private func ensureStatusBarItemsVisible() {
        pomodoroStatusItem?.isVisible = windowController?.usesLegacyPomodoroStatusItem() ?? true
        statusItem?.isVisible = true
        pomodoroStatusItem?.button?.isHidden = false
        statusItem?.button?.isHidden = false
        pomodoroStatusItem?.button?.alphaValue = 1
        statusItem?.button?.alphaValue = 1
        pomodoroStatusItem?.button?.window?.alphaValue = 1
        statusItem?.button?.window?.alphaValue = 1
        pomodoroStatusItem?.button?.window?.ignoresMouseEvents = false
        statusItem?.button?.window?.ignoresMouseEvents = false
        if windowController?.usesLegacyPomodoroStatusItem() == true { pomodoroStatusItem?.button?.window?.orderFrontRegardless() }
        statusItem?.button?.window?.orderFrontRegardless()
    }

    private func refreshStatusBarLayout() {
        guard !appUsesTouchBar else { return }

        // Toggling visibility makes NSStatusBar ask Control Center for a new
        // slot. This is intentionally only used during recovery, not on every
        // render, so normal updates never flicker.
        pomodoroStatusItem?.isVisible = false
        statusItem?.isVisible = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pomodoroStatusItem?.isVisible = true
            self.statusItem?.isVisible = true
            self.ensureStatusBarItemsVisible()
            self.renderMenuControls()
            self.logStatusBarDiagnostics("layout-refresh")
        }
    }

    private func refreshStatusBarLayoutIfNeeded() {
        let pomodoroFrame = pomodoroStatusItem?.button?.window?.frame
        let summaryFrame = statusItem?.button?.window?.frame
        let frames = windowController?.usesLegacyPomodoroStatusItem() == true ? [pomodoroFrame, summaryFrame] : [summaryFrame]
        let hasOffscreenItem = frames.contains { frame in
            guard let frame else { return true }
            return frame.maxY <= 0 || frame.maxX <= 1
        }
        if hasOffscreenItem {
            refreshStatusBarLayout()
        }
    }

    private func logStatusBarDiagnostics(_ reason: String) {
        let pomodoroButton = pomodoroStatusItem?.button
        let summaryButton = statusItem?.button
        let pomodoroVisible = pomodoroStatusItem?.isVisible ?? false
        let summaryVisible = statusItem?.isVisible ?? false
        let pomodoroWindow = pomodoroButton?.window != nil
        let summaryWindow = summaryButton?.window != nil
        let pomodoroHidden = pomodoroButton?.isHidden ?? true
        let summaryHidden = summaryButton?.isHidden ?? true
        let pomodoroWidth = pomodoroButton?.bounds.width ?? 0
        let summaryWidth = summaryButton?.bounds.width ?? 0
        let pomodoroWindowVisible = pomodoroButton?.window?.isVisible ?? false
        let summaryWindowVisible = summaryButton?.window?.isVisible ?? false
        let pomodoroFrame = pomodoroButton?.window?.frame.debugDescription ?? "nil"
        let summaryFrame = summaryButton?.window?.frame.debugDescription ?? "nil"
        let pomodoroWindowAlpha = pomodoroButton?.window?.alphaValue ?? -1
        let summaryWindowAlpha = summaryButton?.window?.alphaValue ?? -1
        let pomodoroWindowLevel = pomodoroButton?.window?.level.rawValue ?? -1
        let summaryWindowLevel = summaryButton?.window?.level.rawValue ?? -1
        let diagnostics = [
            "Status bar diagnostics reason=\(reason)",
            "pomodoroVisible=\(pomodoroVisible)",
            "summaryVisible=\(summaryVisible)",
            "pomodoroWindow=\(pomodoroWindow)",
            "summaryWindow=\(summaryWindow)",
            "pomodoroWindowVisible=\(pomodoroWindowVisible)",
            "summaryWindowVisible=\(summaryWindowVisible)",
            "pomodoroHidden=\(pomodoroHidden)",
            "summaryHidden=\(summaryHidden)",
            "pomodoroWidth=\(pomodoroWidth)",
            "summaryWidth=\(summaryWidth)",
            "pomodoroFrame=\(pomodoroFrame)",
            "summaryFrame=\(summaryFrame)",
            "pomodoroWindowAlpha=\(pomodoroWindowAlpha)",
            "summaryWindowAlpha=\(summaryWindowAlpha)",
            "pomodoroWindowLevel=\(pomodoroWindowLevel)",
            "summaryWindowLevel=\(summaryWindowLevel)",
        ].joined(separator: " ")
        touchBarLogger.notice("\(diagnostics, privacy: .public)")
    }

    @objc private func resetPomodoro() {
        windowController.resetPomodoro()
    }

    @objc private func startShortBreak() {
        windowController.startShortBreak()
    }

    @objc private func startLongBreak() {
        windowController.startLongBreak()
    }

    @objc private func togglePomodoroSoundReminder() {
        windowController.togglePomodoroSoundReminder()
    }

    @objc private func togglePomodoroPopupReminder() {
        windowController.togglePomodoroPopupReminder()
    }

    @objc private func openPomodoroNotificationSettings() {
        windowController.openPomodoroNotificationSettings()
    }

    @objc private func refreshCodexStatus() {
        windowController.refreshCodexStatus()
    }

    @objc private func refreshUsageStatus() {
        windowController.refreshUsageStatus()
    }

    @objc private func copyCurrentStatus() {
        windowController.copyCurrentStatus()
    }

    @objc private func openPluginConfiguration() {
        windowController.openPluginConfiguration()
    }

    @objc private func reloadPluginConfiguration() {
        if let error = windowController.reloadPluginConfiguration() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "插件配置没有生效"
            alert.informativeText = error
            alert.runModal()
        }
    }

    @objc private func toggleGlobalTouchBar() {
        guard let globalTouchBarPresenter else { return }
        globalTouchBarPresenter.setEnabled(!globalTouchBarPresenter.isEnabled)
    }

    @objc private func startWorkBuddyRetry() { windowController.controlWorkBuddyRetry("start") }
    @objc private func updateWorkBuddySession() { windowController.controlWorkBuddyRetry("update") }
    @objc private func stopWorkBuddyRetry() { windowController.controlWorkBuddyRetry("stop") }
    @objc private func refreshAgentSpeed() { windowController.refreshAgentSpeed() }
    @objc private func openMonitorSettingsFromMenu() { windowController.showMonitorSettings() }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func runSelfCheck() {
        windowController.refreshCodexStatus()
        windowController.refreshUsageStatus()
        windowController.refreshScriptPlugins()
        globalTouchBarPresenter?.refresh()
        _ = healthMonitor.refresh()
    }

    @objc private func openHealthReport() {
        healthMonitor.openStateFile()
    }

    /// 迁移备份此前只能靠人手动 cp，这里给一个带确认的入口。
    @objc private func restoreConfigurationBackup() {
        guard let windowController else { return }
        let backups = windowController.configurationBackups()
        guard let latest = backups.first else {
            let alert = NSAlert()
            alert.messageText = "没有可用的配置备份"
            alert.informativeText = "当前配置目录里找不到 plugins.json.before-* 文件。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "从备份恢复配置？"
        alert.informativeText = "将用 \(latest.lastPathComponent)（\(backups.count) 份备份中最新的）覆盖当前 plugins.json。\n当前配置会先另存为 before-restore-<时间戳>，可再恢复回来。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = windowController.restoreConfigurationBackup()
        let done = NSAlert()
        done.messageText = result
        done.addButton(withTitle: "好")
        done.runModal()
    }

    private func renderMenuControls() {
        pomodoroMenuItem?.title = windowController?.pomodoroMenuTitle() ?? "番茄钟"
        if let windowController {
            pomodoroSoundMenuItem?.state = windowController.pomodoroSoundReminderEnabled() ? .on : .off
            pomodoroPopupMenuItem?.state = windowController.pomodoroPopupReminderEnabled() ? .on : .off
        }
        codexMenuItem?.title = windowController?.codexMenuTitle() ?? "ChatGPT状态：检查中"
        quotaMenuItem?.title = windowController?.quotaMenuTitle() ?? "使用量：检查中"
        workbuddyMenuItem?.title = windowController?.workbuddyMenuTitle() ?? "WB状态：检查中"
        if let bundle = windowController?.agentSpeedBundle() {
            for source in AgentSpeedSource.allCases {
                agentSpeedMenuItems[source]?.title = bundle.snapshot(for: source).rowText
            }
            let primary = bundle.primary
            agentSpeedParentMenuItem?.title = primary.speed == nil
                ? "AI 速度"
                : "AI 速度 · \(primary.source.touchBarTag) \(Int((primary.speed ?? 0).rounded()))"
        }
        tokenMenuItem?.title = windowController?.tokenMenuTitle() ?? "词元：检查中"
        fanControlMenuItem?.title = windowController?.fanControlMenuTitle() ?? "风扇调速…"
        if let windowController {
            fanHelperMenuItem?.title = windowController.fanHelperUpdateRequired()
                ? "更新风扇辅助服务（需要）…"
                : "更新风扇辅助服务…"
        }

        if let windowController {
            pomodoroStatusItem?.button?.attributedTitle = windowController.pomodoroStatusBarAttributedText()
            pomodoroStatusItem?.button?.toolTip = "点击开始番茄钟 · \(windowController.pomodoroMenuTitle())"
            statusItem?.button?.title = ""
            statusItem?.button?.toolTip = "goodtouchbar · 点击查看状态详情 · 右键打开完整菜单"
            statusDetailsPopover?.update(
                windowController.statusDetailsSnapshot(menuBarMode: !appUsesTouchBar)
            )
        } else {
            pomodoroStatusItem?.button?.title = "🍅--"
            pomodoroStatusItem?.button?.toolTip = "点击开始番茄钟"
            statusItem?.button?.title = ""
            statusItem?.button?.toolTip = "goodtouchbar · 点击查看状态详情 · 右键打开完整菜单"
        }
        ensureStatusBarItemsVisible()

        guard let globalTouchBarMenuItem, let globalTouchBarPresenter else { return }
        let globalSnapshot = globalTouchBarPresenter.snapshot
        globalTouchBarMenuItem.state = globalSnapshot.enabled ? .on : .off
        if !globalSnapshot.supported {
            globalTouchBarMenuItem.title = "全局常驻 Touch Bar（当前系统不支持）"
        } else if globalSnapshot.lastError != nil {
            globalTouchBarMenuItem.title = "全局常驻 Touch Bar（呈现失败）"
        } else {
            globalTouchBarMenuItem.title = "全局常驻 Touch Bar（实验）"
        }
    }

    private func renderHealth(_ snapshot: TouchBarHealthSnapshot) {
        let prefix = appUsesTouchBar ? "🍅" : "⚡"
        let icon: String
        switch snapshot.status {
        case "healthy": icon = prefix + "✓"
        case "waiting": icon = prefix + "…"
        default: icon = prefix + "!"
        }
        healthStatusIcon = icon
        statusItem.button?.toolTip = "goodtouchbar · \(snapshot.status) · 点击查看状态详情"
        healthMenuItem.title = "运行状态：\(snapshot.message)"
        renderMenuControls()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarVisibilityTimer?.invalidate()
        statusBarVisibilityTimer = nil
        globalTouchBarPresenter?.stop()
        windowController.stopMonitoring()
        healthMonitor.stop()
    }
}

#if !DASHBOARD_TESTING
@main
@MainActor
struct GoodTouchBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

#endif
