import AppKit
import SystemMonitoring
import UniformTypeIdentifiers


/// Resolve semantic colors while drawing so controls and background share one appearance.
private final class MonitorSettingsBackground: NSStackView {
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class MonitorSettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: TouchBarPluginManager
    private let monitor: SystemMetricsMonitor
    private let preview: (String) -> String
    var onOpenFanControl: (() -> Void)?
    var onOpenPlugins: (() -> Void)?
    private var thresholdFields: [String:(NSTextField,NSTextField)] = [:]
    private var expectedConfiguration = Data()
    private let didSave: () -> Void
    private let deviceCapabilities: GoodTouchBarDeviceCapabilities
    private let touchBarModeChoice = NSPopUpButton()
    private let deviceSummary = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let message = NSTextField(wrappingLabelWithString: "勾选显示位置，拖动行调整顺序；修改后点保存。")
    private let dashboard = PerformanceDashboard(frame: .zero)
    var statusText: (() -> String)?
    var diagnosticState: (() -> [String:String])?
    var fanText: (() -> String)?
    var onNotifications: ((Bool) -> Void)?
    var notificationsEnabled = false
    var touchBarModeChanged: ((GoodTouchBarMode) -> Void)?
    private var selectedTouchBarMode: GoodTouchBarMode
    private var exporting = false
    private let sensorChoice = NSPopUpButton()
    private let tabs = NSTabView()
    private var rows: [String] = []
    private var bar = Set<String>(), menuSelection = Set<String>()
    private static let dragType = NSPasteboard.PasteboardType("io.github.yihuirui.goodtouchbar.display-row")
    init(manager: TouchBarPluginManager, monitor: SystemMetricsMonitor, preview: @escaping (String) -> String, didSave: @escaping () -> Void,
         capabilities: GoodTouchBarDeviceCapabilities = .current, touchBarMode: GoodTouchBarMode = .auto) {
        self.manager = manager; self.monitor = monitor; self.preview = preview; self.didSave = didSave
        self.deviceCapabilities = capabilities; self.selectedTouchBarMode = touchBarMode
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 880,height: 650), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.title = "性能监控与显示"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 820,height: 620)
        super.init(window: window); window.delegate = self
        build(); loadConfiguration()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(showDetails: Bool = false) {
        if window?.isVisible != true { loadConfiguration() }
        if showDetails { tabs.selectTabViewItem(at: 1) }
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        monitor.detailed = true; render()
    }
    func windowWillClose(_ notification: Notification) { monitor.detailed = false }
    func windowDidMiniaturize(_ notification: Notification) { monitor.detailed = false }
    func windowDidDeminiaturize(_ notification: Notification) { monitor.detailed = true }
    private func build() {
        let root = MonitorSettingsBackground(); root.orientation = .vertical; root.spacing = 12; root.edgeInsets = NSEdgeInsets(top:16,left:16,bottom:16,right:16)
        root.translatesAutoresizingMaskIntoConstraints = false; window?.contentView?.addSubview(root)
        if let content = window?.contentView { NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: content.topAnchor),root.bottomAnchor.constraint(equalTo: content.bottomAnchor),root.leadingAnchor.constraint(equalTo: content.leadingAnchor),root.trailingAnchor.constraint(equalTo: content.trailingAnchor)]) }
        let navigation = NSStackView(); navigation.spacing = 8
        navigation.addArrangedSubview(NSButton(title: "显示项目", target: self, action: #selector(selectDisplayTab)))
        navigation.addArrangedSubview(NSButton(title: "性能详情", target: self, action: #selector(selectDetailsTab)))
        if deviceCapabilities.canUseIntelFanHelper {
            navigation.addArrangedSubview(NSButton(title: "风扇调速", target: self, action: #selector(openFanControl)))
        } else {
            navigation.addArrangedSubview(NSTextField(labelWithString: "风扇由 macOS 自动管理（只读）"))
        }
        navigation.addArrangedSubview(NSButton(title:"阈值颜色",target:self,action:#selector(selectThresholdTab)))
        navigation.addArrangedSubview(NSButton(title:"插件配置",target:self,action:#selector(openPlugins)))
        root.addArrangedSubview(navigation)
        tabs.tabViewType = .noTabsNoBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(tabs)
        let displayTab = NSTabViewItem(identifier: "display"); displayTab.label = "显示项目"
        let display = NSStackView(); display.orientation = .vertical; display.spacing = 10; display.edgeInsets = NSEdgeInsets(top:12,left:12,bottom:12,right:12)
        let description = NSTextField(wrappingLabelWithString: "Touch Bar 和菜单栏可分别选择；放不下的项目进入更多。拖动行或使用上移／下移。")
        display.addArrangedSubview(description)
        let modeRow = NSStackView(); modeRow.spacing = 10
        modeRow.addArrangedSubview(NSTextField(labelWithString: "Touch Bar 模式"))
        for (mode, title) in [(GoodTouchBarMode.auto, "Auto"), (.on, "On"), (.off, "Off")] {
            touchBarModeChoice.addItem(withTitle: title)
            touchBarModeChoice.lastItem?.representedObject = mode.rawValue
        }
        touchBarModeChoice.target = self; touchBarModeChoice.action = #selector(changeTouchBarMode)
        modeRow.addArrangedSubview(touchBarModeChoice); display.addArrangedSubview(modeRow)
        deviceSummary.lineBreakMode = .byWordWrapping
        deviceSummary.font = .systemFont(ofSize: 11)
        display.addArrangedSubview(deviceSummary)
        for (id,title,width) in [("name","项目",220.0),("bar","Touch Bar",88.0),("menu","菜单栏",70.0),("preview","当前值",200.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.usesAlternatingRowBackgroundColors = true
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        display.addArrangedSubview(scroll); scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let actions = NSStackView(); actions.spacing = 8
        for (title,action) in [("上移",#selector(moveRowUp)),("下移",#selector(moveRowDown)),("性能预设",#selector(performancePreset)),("恢复默认",#selector(resetDefaults))] {
            actions.addArrangedSubview(NSButton(title: title,target:self,action:action))
        }
        display.addArrangedSubview(actions)
        let sensorRow = NSStackView(); sensorRow.spacing = 10
        sensorRow.addArrangedSubview(NSTextField(labelWithString:"CPU 温度来源"))
        let sensorOptions: [(String, String)] = deviceCapabilities.hostSupportsArm64 == true || !deviceCapabilities.canUseIntelFanHelper
            ? [(CoreTemperature.selection, MetricThresholds.sensorName(CoreTemperature.selection))]
            : [(CoreTemperature.selection, MetricThresholds.sensorName(CoreTemperature.selection)), ("TC0E", MetricThresholds.sensorName("TC0E")), ("TC0F", MetricThresholds.sensorName("TC0F")), ("TC0P", MetricThresholds.sensorName("TC0P"))]
        for (key,name) in sensorOptions { sensorChoice.addItem(withTitle:name); sensorChoice.lastItem?.representedObject = key }
        sensorRow.addArrangedSubview(sensorChoice); display.addArrangedSubview(sensorRow)
        displayTab.view = display; tabs.addTabViewItem(displayTab)
        let detailsTab = NSTabViewItem(identifier:"details"); detailsTab.label = "性能详情"
        detailsTab.view = dashboard; tabs.addTabViewItem(detailsTab)
        dashboard.fanButton.target = self; dashboard.fanButton.action = #selector(openFanControl)
        dashboard.fanButton.isHidden = !deviceCapabilities.canUseIntelFanHelper
        dashboard.exportButton.target = self; dashboard.exportButton.action = #selector(exportDiagnostics)
        dashboard.notificationButton.target = self; dashboard.notificationButton.action = #selector(changeNotifications)
        let thresholdsTab = NSTabViewItem(identifier:"thresholds")
        let thresholdView = NSStackView(); thresholdView.orientation = .vertical; thresholdView.alignment = .leading; thresholdView.spacing = 14
        thresholdView.edgeInsets = NSEdgeInsets(top:20,left:20,bottom:20,right:20)
        thresholdView.addArrangedSubview(NSTextField(wrappingLabelWithString:"读数达到阈值时变色；无数据／过期显示灰色。颜色仅为显示提醒，不修改风扇安全保护。"))
        for key in MetricThresholds.editable {
            let line = NSStackView(); line.spacing = 12
            let unit = key == MetricID.fans.rawValue ? "% 最高转速" : key.contains("Temperature") ? "°C" : key == MetricID.swap.rawValue ? "GiB" : "%"
            let label = NSTextField(labelWithString:(MetricID(rawValue:key)?.name ?? key)); label.widthAnchor.constraint(equalToConstant:180).isActive = true; line.addArrangedSubview(label)
            let warning = NSTextField(), critical = NSTextField()
            warning.identifier = NSUserInterfaceItemIdentifier("warning-"+key); critical.identifier = NSUserInterfaceItemIdentifier("critical-"+key)
            for (field,title) in [(warning,"橙色 ≥"),(critical,"红色 ≥")] { line.addArrangedSubview(NSTextField(labelWithString:title)); field.widthAnchor.constraint(equalToConstant:60).isActive = true; line.addArrangedSubview(field) }
            line.addArrangedSubview(NSTextField(labelWithString:unit)); thresholdView.addArrangedSubview(line); thresholdFields[key] = (warning,critical)
        }
        thresholdView.addArrangedSubview(NSTextField(wrappingLabelWithString:"内存压力按系统等级变色；风扇高转速表示散热负载，不代表故障。CPU 温度达到阈值，也不等于系统已经降频。"))
        thresholdView.addArrangedSubview(NSButton(title:"保存阈值",target:self,action:#selector(saveThresholds)))
        thresholdsTab.view = thresholdView; tabs.addTabViewItem(thresholdsTab)
        let footer = NSStackView(); footer.spacing = 12; footer.addArrangedSubview(message)
        let save = NSButton(title:"保存显示设置",target:self,action:#selector(save)); save.keyEquivalent = "s"; footer.addArrangedSubview(save)
        root.addArrangedSubview(footer)
        tabs.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-32).isActive = true
        footer.widthAnchor.constraint(equalTo:tabs.widthAnchor).isActive = true
    }
    @objc private func selectThresholdTab() { tabs.selectTabViewItem(at:2) }
    @objc private func openPlugins() { onOpenPlugins?() }
    @objc private func saveThresholds() {
        var values: [String:[Double]] = [:]
        for (key,fields) in thresholdFields {
            guard let first = Double(fields.0.currentEditor()?.string ?? fields.0.stringValue), let second = Double(fields.1.currentEditor()?.string ?? fields.1.stringValue) else { message.stringValue = "阈值请输入有效数字。"; return }
            values[key] = [first,second]
        }
        do { try manager.saveThresholds(values); expectedConfiguration = try manager.configurationData(); didSave(); message.stringValue = "阈值已保存并生效" }
        catch { message.stringValue = error.localizedDescription }
    }
    @objc private func openFanControl() { onOpenFanControl?() }
    @objc private func selectDisplayTab() { tabs.selectTabViewItem(at: 0) }
    @objc private func selectDetailsTab() { tabs.selectTabViewItem(at: 1); render() }
    private func loadConfiguration() {
        expectedConfiguration = (try? manager.configurationData()) ?? Data()
        for (key,fields) in thresholdFields {
            let limits = manager.configuration.metricThresholds?[key] ?? MetricThresholds.defaults[key]!
            fields.0.stringValue = String(format:"%g",limits[0]); fields.1.stringValue = String(format:"%g",limits[1])
        }
        rows = manager.catalogKeys; bar = Set(manager.visibleKeys); menuSelection = Set(manager.menuKeys)
        if let index = sensorChoice.itemArray.firstIndex(where: { $0.representedObject as? String == manager.selectedCPUTemperatureKey }) { sensorChoice.selectItem(at:index) }
        if let index = touchBarModeChoice.itemArray.firstIndex(where: { $0.representedObject as? String == selectedTouchBarMode.rawValue }) { touchBarModeChoice.selectItem(at:index) }
        let resolution = deviceCapabilities.resolveTouchBarMode(selectedTouchBarMode)
        deviceSummary.stringValue = "机型：\(deviceCapabilities.modelIdentifier ?? "unknown") · 架构：\(deviceCapabilities.architectureDescription) · 模式：\(resolution.requested.rawValue) → \(resolution.enabled ? "Touch Bar" : "菜单栏") · \(resolution.reason)"
        table.tableColumns.first(where: { $0.identifier.rawValue == "bar" })?.isHidden = !deviceCapabilities.touchBarSupported
        table.reloadData()
    }
    @objc private func changeTouchBarMode() {
        guard let raw = touchBarModeChoice.selectedItem?.representedObject as? String,
              let mode = GoodTouchBarMode(rawValue: raw) else { return }
        selectedTouchBarMode = mode
        touchBarModeChanged?(mode)
        let resolution = deviceCapabilities.resolveTouchBarMode(mode)
        deviceSummary.stringValue = "机型：\(deviceCapabilities.modelIdentifier ?? "unknown") · 架构：\(deviceCapabilities.architectureDescription) · \(resolution.reason) · 重启 goodtouchbar 后生效"
        message.stringValue = "Touch Bar 模式已保存；重启 goodtouchbar 后生效"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let key = rows[row]
        if column == "bar" || column == "menu" {
            let button = NSButton(checkboxWithTitle:"",target:self,action:#selector(toggle))
            button.identifier = NSUserInterfaceItemIdentifier(column + "|" + key)
            button.state = (column == "bar" ? bar : menuSelection).contains(key) ? .on : .off
            return button
        }
        let label = NSTextField(labelWithString: column == "name" ? name(for:key) : preview(key))
        label.lineBreakMode = .byTruncatingTail; if column == "preview" { label.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular) }
        return label
    }
    private func name(for key:String) -> String {
        if let metric = MetricID(rawValue:key) { return metric.name }
        switch key {
        case TouchBarPluginKey.gptStatus:return "ChatGPT 状态"
        case TouchBarPluginKey.gptUsage:return "7 天额度"
        case TouchBarPluginKey.workbuddy:return "WB AI 状态"
        case TouchBarPluginKey.agentSpeed:return "AI 速度"
        case TouchBarPluginKey.todayTokens:return "今日词元"
        case TouchBarPluginKey.pomodoro:return "番茄钟"
        case TouchBarPluginKey.pomodoroReset:return "重置番茄钟"
        default:return manager.configuration.scripts.first { $0.key == key }?.name ?? key
        }
    }
    @objc private func toggle(_ sender:NSButton) {
        guard let id = sender.identifier?.rawValue, let separator = id.firstIndex(of:"|") else { return }
        let key = String(id[id.index(after:separator)...])
        if id.hasPrefix("bar|") { if sender.state == .on { bar.insert(key) } else { bar.remove(key) } }
        else { if sender.state == .on { menuSelection.insert(key) } else { menuSelection.remove(key) } }
        message.stringValue = "有未保存的修改"
    }
    @objc private func moveRowUp() { moveSelected(by:-1) }
    @objc private func moveRowDown() { moveSelected(by:1) }
    private func moveSelected(by offset:Int) {
        let from = table.selectedRow, to = from + offset
        guard rows.indices.contains(from), rows.indices.contains(to) else { return }
        rows.swapAt(from,to); table.reloadData(); table.selectRowIndexes(IndexSet(integer:to),byExtendingSelection:false); message.stringValue = "有未保存的修改"
    }
    func tableView(_ tableView:NSTableView, pasteboardWriterForRow row:Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(rows[row],forType:Self.dragType); return item
    }
    func tableView(_ tableView:NSTableView, validateDrop info:NSDraggingInfo, proposedRow row:Int, proposedDropOperation operation:NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === table, info.draggingPasteboard.string(forType:Self.dragType) != nil else { return [] }
        table.setDropRow(row,dropOperation:.above); return .move
    }
    func tableView(_ tableView:NSTableView, acceptDrop info:NSDraggingInfo, row:Int, dropOperation:NSTableView.DropOperation) -> Bool {
        guard let key = info.draggingPasteboard.string(forType:Self.dragType), let from = rows.firstIndex(of:key), row >= 0, row <= rows.count else { return false }
        rows.remove(at:from); let to = min(rows.count,row > from ? row-1 : row); rows.insert(key,at:to)
        table.reloadData(); table.selectRowIndexes(IndexSet(integer:to),byExtendingSelection:false); message.stringValue = "有未保存的修改"; return true
    }
    @objc private func performancePreset() { bar = Set(MetricID.performancePreset); rows = DisplayLayout.unique(MetricID.performancePreset + rows); table.reloadData(); message.stringValue = "性能预设已选择，点保存生效" }
    @objc private func resetDefaults() { bar = Set(TouchBarPluginKey.defaultOrder); menuSelection = Set([TouchBarPluginKey.gptUsage,TouchBarPluginKey.todayTokens,TouchBarPluginKey.pomodoro]); rows = DisplayLayout.unique(TouchBarPluginKey.defaultOrder + manager.allKeys); sensorChoice.selectItem(at:0); table.reloadData(); message.stringValue = "默认布局已选择，点保存生效" }
    @objc private func save() {
        do {
            guard try manager.configurationData() == expectedConfiguration else { message.stringValue = "其他窗口已修改配置，请关闭本窗口后重新打开再保存。"; return }
            try manager.saveDisplay(order:rows.filter { bar.contains($0) },menuOrder:rows.filter { menuSelection.contains($0) },catalogOrder:rows,cpuTemperatureKey:sensorChoice.selectedItem?.representedObject as? String ?? CoreTemperature.selection)
            expectedConfiguration = try manager.configurationData(); didSave(); message.stringValue = "已保存并生效"; table.reloadData()
        } catch { message.stringValue = "保存失败：\(error.localizedDescription)" }
    }
    func render() {
        guard window?.isVisible == true, window?.isMiniaturized != true else { return }
        // Do not reload row/cell views during mouse tracking or editing. Keep checkboxes
        // and the scroll position attached; newly visible cells get current text via viewFor.
        if tabs.selectedTabViewItem?.identifier as? String == "display" {
            for row in rows.indices {
                guard let label = table.view(atColumn:3,row:row,makeIfNecessary:false) as? NSTextField else { continue }
                let text = preview(rows[row]); if label.stringValue != text { label.stringValue = text }
            }
        }
        let snapshot = monitor.snapshot
        dashboard.notificationButton.state = notificationsEnabled ? .on : .off
        let performance = [MetricID.cpu, .memory, .pressure, .swap].map { snapshot.text(for: $0.rawValue) }
        dashboard.performance.stringValue = performance.joined(separator: "\n\n")
        dashboard.secondary.stringValue = [TouchBarPluginKey.gptStatus, TouchBarPluginKey.workbuddy, TouchBarPluginKey.gptUsage].map(preview).joined(separator: "\n")
        var thermal = [snapshot.text(for: MetricID.cpuTemperature.rawValue), snapshot.text(for: MetricID.gpuTemperature.rawValue), snapshot.text(for: MetricID.batteryTemperature.rawValue)]
        let fresh = snapshot.readings[MetricID.fans.rawValue]?.isFresh() == true
        for fan in snapshot.fans {
            let rpm = fresh ? fan.actual.map { String(format: "%.0f RPM", $0) } ?? "--" : "--"
            thermal.append("风扇 \(fan.id + 1)   \(rpm)")
        }
        if snapshot.fans.isEmpty { thermal.append("风扇 --") }
        thermal.append(fanText?() ?? "风扇控制未启用")
        thermal.append("来源：" + MetricThresholds.sensorName(monitor.cpuTemperatureKey))
        func coreValue(_ key:String) -> String {
            guard let reading = snapshot.readings[key], reading.isFresh(), let v = reading.value else { return "--" }
            return String(format:"%.1f°C",v)
        }
        let coreCount = snapshot.readings["cpu.coreCount"]
        let count = coreCount?.isFresh() == true ? Int(coreCount?.value ?? 0) : 0
        let readingLabel = deviceCapabilities.hostSupportsArm64 == true ? "有效热区" : "有效核心"
        thermal.append("核心最高 \(coreValue("cpu.coreMax")) · 平均 \(coreValue("cpu.coreAverage"))\n\(readingLabel)：\(count)")
        dashboard.powerStatus.stringValue = CPUPowerStatus.text(snapshot.readings) + "\n速度上限不是实际性能百分比，也不单独证明热降频"
        let comparisons = (deviceCapabilities.hostSupportsArm64 == true ? [] : ["TC0E","TC0F","TC0P"]).map { key -> String in
            let r = monitor.temperatureReadings[key]
            return key + " " + ((r?.isFresh() == true ? r?.value : nil).map { String(format:"%.1f°C",$0) } ?? "--")
        }
        if !comparisons.isEmpty { thermal.append(comparisons.joined(separator:" / ")) }
        thermal.append(MetricThresholds.thermalStateText(ProcessInfo.processInfo.thermalState))
        dashboard.thermal.stringValue = thermal.joined(separator: "\n")
        dashboard.incidents.stringValue = statusText?() ?? "暂无异常"
        dashboard.incidents.textColor = dashboard.incidents.stringValue == "暂无异常" ? .secondaryLabelColor : .systemOrange
        dashboard.trend.points = monitor.history.points
    }
    @objc private func changeNotifications(_ sender: NSButton) { onNotifications?(sender.state == .on) }
    @objc private func exportDiagnostics() {
        guard !exporting else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "GoodTouchBar-diagnostics-" + ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-") + ".json"
        panel.message = "导出版本、内置显示项、性能趋势和脱敏事件。不会包含聊天正文、脚本、账户信息或原始输出；系统服务私有日志需另行读取。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true; dashboard.exportButton.isEnabled = false; dashboard.status.stringValue = "正在整理诊断…"
        let summary: [String: Any] = ["build": Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "2", "os": ProcessInfo.processInfo.operatingSystemVersionString, "architecture": deviceCapabilities.architectureDescription, "modelIdentifier": deviceCapabilities.modelIdentifier ?? "unknown", "touchBarMode": GoodTouchBarRuntimeConfiguration.selectedMode().rawValue, "touchBarEnabled": deviceCapabilities.resolveTouchBarMode(GoodTouchBarRuntimeConfiguration.selectedMode()).enabled, "exportedAt": ISO8601DateFormatter().string(from:Date()), "visibleMetrics": manager.visibleKeys.filter { MetricID(rawValue:$0) != nil }, "menuMetrics": manager.menuKeys.filter { MetricID(rawValue:$0) != nil }, "cpuTemperatureSource": manager.selectedCPUTemperatureKey, "fanCapability": deviceCapabilities.fanCapabilityReason, "state": diagnosticState?() ?? [:]]
        let history = monitor.history.points
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let outcome: Bool
            do {
                var report = summary
                report["events"] = DiagnosticExport.collectLogs(directory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar"))
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                report["trend"] = try JSONSerialization.jsonObject(with:encoder.encode(history))
                report["omitted"] = ["root service log", "stdout/stderr", "session contents", "script configuration", "account information"]
                try JSONSerialization.data(withJSONObject:report, options:[.prettyPrinted,.sortedKeys]).write(to:destination, options:.atomic)
                outcome = true
            } catch { outcome = false }
            DispatchQueue.main.async {
                guard let self else { return }; self.exporting = false; self.dashboard.exportButton.isEnabled = true
                self.dashboard.status.stringValue = outcome ? "诊断包已保存" : "保存失败，请检查目标目录权限后重试"
                if outcome { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
            }
        }
    }
}
