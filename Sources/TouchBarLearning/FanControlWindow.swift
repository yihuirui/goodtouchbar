import AppKit
import FanControlCore


/// Resolve semantic colors while drawing so controls and background share one appearance.
private final class FanSettingsBackground: NSStackView {
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor
final class FanControlWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let client: FanControlClient
    private let summary = NSTextField(wrappingLabelWithString: "辅助服务尚未连接")
    private let connection = NSTextField(labelWithString: "")
    private let temperatures = NSTextField(labelWithString: "CPU -- · GPU芯片最高 --")
    private let thermalWarning = NSTextField(wrappingLabelWithString: "")
    private let countdown = NSTextField(labelWithString: "")
    private let conflict = NSTextField(wrappingLabelWithString: "")
    private let rows = NSStackView()
    private let fixed = NSButton(title: "应用固定转速", target: nil, action: nil)
    private let boost = NSButton(title: "强力散热 5 分钟", target: nil, action: nil)
    private let automatic = NSButton(title: "停止并恢复系统自动", target: nil, action: nil)
    private let install = NSButton(title: "安装／更新辅助服务…", target: nil, action: nil)
    private let uninstall = NSButton(title: "卸载辅助服务…", target: nil, action: nil)
    private var rpmFields: [Int: NSTextField] = [:]
    private var fanLabels: [Int: NSTextField] = [:]
    private var fanRows: [Int: NSStackView] = [:]
    private var rpmDrafts: [Int: String] = [:]
    private let emptyFans = NSTextField(labelWithString: "连接服务后显示本机风扇及可用转速范围")
    private var knownFanIDs: [Int] = []

    init(client: FanControlClient) {
        self.client = client
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "风扇控制"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 660, height: 540)
        super.init(window: window); window.delegate = self
        build(); render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        client.windowVisible = true; client.refresh(); render()
    }

    func windowWillClose(_ notification: Notification) { client.windowVisible = false }
    func windowDidMiniaturize(_ notification: Notification) { client.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { client.windowVisible = true; client.refresh(); render() }
    func renderIfVisible() {
        guard window?.isVisible == true, window?.isMiniaturized != true else { return }
        render()
    }
    private func build() {
        let content = FanSettingsBackground(); content.orientation = .vertical; content.alignment = .leading
        content.distribution = .fill
        content.spacing = 14; content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false; window?.contentView?.addSubview(content)
        if let root = window?.contentView { NSLayoutConstraint.activate([content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor), content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor)]) }
        let title = NSTextField(labelWithString: "风扇调速"); title.font = .systemFont(ofSize: 19, weight: .semibold)
        content.addArrangedSubview(title)
        summary.font = .systemFont(ofSize: 14, weight: .medium); content.addArrangedSubview(summary)
        connection.font = .systemFont(ofSize: 12); connection.textColor = .secondaryLabelColor
        content.addArrangedSubview(connection)
        temperatures.toolTip = "CPU 来源 TC0E；GPU 为已绑定芯片温度传感器的最高值，与 GPU 邻近温度不同。"
        content.addArrangedSubview(temperatures)
        thermalWarning.textColor = .systemOrange; thermalWarning.font = .systemFont(ofSize:12); content.addArrangedSubview(thermalWarning)
        countdown.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); content.addArrangedSubview(countdown)
        conflict.textColor = .systemOrange; content.addArrangedSubview(conflict)
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10
        rows.addArrangedSubview(emptyFans)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = rows; rows.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(equalToConstant: 116).isActive = true
        scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        if let clip = scroll.contentView as NSClipView? {
            rows.leadingAnchor.constraint(equalTo: clip.leadingAnchor).isActive = true
            rows.trailingAnchor.constraint(equalTo: clip.trailingAnchor).isActive = true
            rows.topAnchor.constraint(equalTo: clip.topAnchor).isActive = true
            rows.widthAnchor.constraint(equalTo: clip.widthAnchor).isActive = true
        }
        let commands = NSStackView(); commands.spacing = 10
        fixed.target = self; fixed.action = #selector(applyFixed)
        boost.target = self; boost.action = #selector(startBoost)
        automatic.target = self; automatic.action = #selector(restoreAutomatic)
        commands.addArrangedSubview(fixed); commands.addArrangedSubview(boost); content.addArrangedSubview(commands)
        content.addArrangedSubview(automatic)
        let detail = NSTextField(wrappingLabelWithString: "固定转速在本机允许范围内设置。高温只提醒，不阻止或取消固定转速；传感器失效、连接中断会尝试恢复系统自动；关闭此窗口后控制继续。停止控制请点恢复自动。")
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; content.addArrangedSubview(detail)
        let installation = NSStackView(); installation.spacing = 10
        install.target = self; install.action = #selector(installHelper)
        uninstall.target = self; uninstall.action = #selector(uninstallHelper)
        if client.fanControlAvailable {
            installation.addArrangedSubview(install); installation.addArrangedSubview(uninstall)
        } else {
            installation.addArrangedSubview(NSTextField(labelWithString: "风扇由 macOS 自动管理；此环境仅允许只读传感器数据。"))
        }
        let log = NSButton(title: "打开运行日志", target: self, action: #selector(openLog)); installation.addArrangedSubview(log)
        content.addArrangedSubview(installation)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        content.addArrangedSubview(spacer)
        for label in [summary, conflict, detail, thermalWarning] { label.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true }
    }

    func render() {
        summary.stringValue = client.message
        summary.textColor = client.status?.phase == .recoveryFailed ? .systemRed : .labelColor
        connection.stringValue = client.installationBusy ? "系统授权处理中" : client.statusFresh ? "辅助服务已连接" : client.isInstalled ? "辅助服务已安装，尚未确认连接" : "辅助服务尚未安装"
        let others = client.conflictingControllers
        conflict.stringValue = others.isEmpty ? "" : "检测到 " + others.joined(separator: "、") + "。请先恢复自动并退出，再启用本应用调速。"
        let status = client.status
        let fresh = client.statusFresh
        func temperature(_ value: Double?) -> String { fresh ? value.map { String(format: "%.1f°C", $0) } ?? "--" : "--" }
        temperatures.stringValue = "CPU(TC0E) \(temperature(status?.cpuTemperature)) · GPU芯片最高 \(temperature(status?.gpuTemperature))"
        thermalWarning.stringValue = fresh ? status?.temperatureWarning ?? "" : ""
        var remaining: [String] = []
        if let seconds = client.boostRemaining { remaining.append(String(format: "强力散热剩余 %02d:%02d", seconds / 60, seconds % 60)) }
        if client.hasControl, let seconds = client.leaseRemaining { remaining.append("连接保护 \(seconds) 秒") }
        countdown.stringValue = remaining.joined(separator: "  ·  ")
        let fans = status?.fans.sorted { $0.id < $1.id } ?? []
        // An empty snapshot is also used for transient read failures. Keep local
        // draft fields; only the current snapshot may enable a control command.
        if !fans.isEmpty, knownFanIDs != fans.map(\.id) { reconcileRows(fans) }
        for id in knownFanIDs {
            let fan = fans.first { $0.id == id }
            func rpm(_ value: Double?) -> String { fresh ? value.map { String(format: "%.0f", $0) } ?? "--" : "--" }
            let mode = fresh ? (fan?.automatic).map { $0 ? "系统自动" : "手动" } ?? "未知" : "未知"
            fanLabels[id]?.stringValue = "风扇 \(id + 1)  实际 \(rpm(fan?.actualRPM)) RPM · 目标 \(rpm(fan?.targetRPM)) RPM · \(mode)\n范围 \(rpm(fan?.minimumRPM))–\(rpm(fan?.maximumRPM)) RPM"
            // A status/heartbeat RPC must not disable the AppKit field editor.
            let editable = !client.installationBusy
            if let field = rpmFields[id], field.isEnabled != editable {
                let draft = draftText(field)
                rpmDrafts[id] = draft
                field.isEnabled = editable
                if !editable, field.stringValue != draft { field.stringValue = draft }
            }
        }
        let available = fresh && !client.busy && !client.installationBusy && !fans.isEmpty
        fixed.isEnabled = available && others.isEmpty && fans.allSatisfy { $0.minimumRPM != nil && $0.maximumRPM != nil }
        boost.isEnabled = available && others.isEmpty
        automatic.isEnabled = !client.busy && !client.installationBusy && (client.connected || client.isInstalled)
        install.isEnabled = !client.busy && !client.installationBusy
        uninstall.isEnabled = client.isInstalled && !client.busy && !client.installationBusy
    }

    private func reconcileRows(_ fans: [FanDeviceReading]) {
        let ids = Set(fans.map(\.id))
        for id in knownFanIDs where !ids.contains(id) {
            if let field = rpmFields[id] { rpmDrafts[id] = draftText(field) }
            if let row = fanRows.removeValue(forKey: id) { rows.removeArrangedSubview(row); row.removeFromSuperview() }
            rpmFields.removeValue(forKey: id); fanLabels.removeValue(forKey: id)
        }
        if emptyFans.superview != nil { rows.removeArrangedSubview(emptyFans); emptyFans.removeFromSuperview() }
        // Insert only new rows. Existing rows, field editors and selections stay attached.
        for (index, fan) in fans.enumerated() where fanRows[fan.id] == nil {
            let row = NSStackView(); row.spacing = 12; row.alignment = .centerY
            let label = NSTextField(wrappingLabelWithString: ""); label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 390).isActive = true
            let field = NSTextField(string: rpmDrafts[fan.id] ?? String(format: "%.0f", fan.targetRPM ?? max(fan.minimumRPM ?? 0, fan.actualRPM ?? 0)))
            field.alignment = .right; field.widthAnchor.constraint(equalToConstant: 84).isActive = true
            field.placeholderString = "目标 RPM"
            field.identifier = NSUserInterfaceItemIdentifier("fan-rpm-\(fan.id)")
            field.delegate = self
            row.addArrangedSubview(label); row.addArrangedSubview(field); row.addArrangedSubview(NSTextField(labelWithString: "RPM"))
            rows.insertArrangedSubview(row, at: index)
            fanRows[fan.id] = row; rpmFields[fan.id] = field; fanLabels[fan.id] = label
        }
        knownFanIDs = fans.map(\.id)
    }

    private func draftText(_ field: NSTextField) -> String { field.currentEditor()?.string ?? field.stringValue }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              let id = rpmFields.first(where: { $0.value === field })?.key else { return }
        rpmDrafts[id] = draftText(field)
    }

    @objc private func applyFixed() {
        guard let fans = client.status?.fans, !fans.isEmpty else { return }
        var targets: [Int: Double] = [:]
        for fan in fans {
            guard let field = rpmFields[fan.id] else { return }
            let text = draftText(field)
            rpmDrafts[fan.id] = text
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rpm = Double(value), rpm.isFinite, rpm.rounded() == rpm, let minimum = fan.minimumRPM, let maximum = fan.maximumRPM, minimum <= rpm, rpm <= maximum else {
                let alert = NSAlert(); alert.messageText = "转速超出可用范围"
                alert.informativeText = "请按风扇旁显示的范围输入整数 RPM。"; alert.addButton(withTitle: "知道了"); alert.runModal(); return
            }
            targets[fan.id] = rpm
        }
        client.applyFixed(targets: targets)
    }
    @objc private func startBoost() { client.boost() }
    @objc private func restoreAutomatic() { client.restoreAutomatic() }

    @objc private func installHelper() {
        guard client.fanControlAvailable else { return }
        let alert = NSAlert(); alert.messageText = "安装风扇控制辅助服务"
        alert.informativeText = "系统将请求管理员授权，安装 GoodTouchBar 专属风扇控制程序、后台服务和本机授权策略。此项能力为实验性功能；安装不等于接管风扇，启动后仍需在窗口中确认。可使用此窗口的卸载入口恢复自动并移除本工具服务；运行日志会保留。文件位于 /Library/PrivilegedHelperTools、/Library/LaunchDaemons 和 /Library/Application Support/GoodTouchBar/FanControl。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "安装并授权")
        if alert.runModal() == .alertSecondButtonReturn { client.install() }
    }
    @objc private func uninstallHelper() {
        guard client.fanControlAvailable else { return }
        let alert = NSAlert(); alert.messageText = "恢复自动并卸载辅助服务"
        alert.informativeText = "先确认本应用接管的风扇已恢复系统自动，再移除后台服务、控制程序和授权策略；日志保留。需要管理员授权。恢复失败时会停止卸载。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "恢复并卸载")
        if alert.runModal() == .alertSecondButtonReturn { client.uninstall() }
    }
    @objc private func openLog() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar", isDirectory: true)
        let file = directory.appendingPathComponent("fan-client-events.jsonl")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
        else if FileManager.default.fileExists(atPath: directory.path) { NSWorkspace.shared.open(directory) }
        else {
            let alert = NSAlert(); alert.messageText = "尚无风扇客户端日志"
            alert.informativeText = "连接或操作辅助服务后会记录日志。系统服务日志位于 /Library/Logs/GoodTouchBar，需要管理员权限查看。"
            alert.addButton(withTitle: "知道了"); alert.runModal()
        }
    }
}
