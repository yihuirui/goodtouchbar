import AppKit
import SystemMonitoring

@MainActor
final class PerformanceDashboard: NSView {
    let performance = NSTextField(wrappingLabelWithString: "等待采样…")
    let powerStatus = NSTextField(wrappingLabelWithString: "系统性能限制：等待采样…")
    let thermal = NSTextField(wrappingLabelWithString: "等待传感器…")
    let incidents = NSTextField(wrappingLabelWithString: "暂无异常")
    let status = NSTextField(wrappingLabelWithString: "")
    let trend = MetricTrendView()
    let exportButton = NSButton(title: "导出诊断包…", target: nil, action: nil)
    let notificationButton = NSButton(checkboxWithTitle: "系统异常通知", target: nil, action: nil)
    let fanButton = NSButton(title: "设置固定转速…", target: nil, action: nil)
    let secondary = NSTextField(wrappingLabelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        let columns = NSStackView(); columns.orientation = .horizontal; columns.distribution = .fillEqually; columns.alignment = .top; columns.spacing = 24
        columns.translatesAutoresizingMaskIntoConstraints = false; addSubview(columns)
        NSLayoutConstraint.activate([columns.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), columns.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), columns.topAnchor.constraint(equalTo: topAnchor, constant: 16), columns.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)])
        func column(_ title: String) -> NSStackView {
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
            let heading = NSTextField(labelWithString: title); heading.font = .systemFont(ofSize: 18, weight: .semibold)
            stack.addArrangedSubview(heading); columns.addArrangedSubview(stack); return stack
        }
        let left = column("性能与趋势"), right = column("温度与风扇")
        left.identifier = NSUserInterfaceItemIdentifier("dashboard-left")
        right.identifier = NSUserInterfaceItemIdentifier("dashboard-right")
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        for label in [performance, thermal] { label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium) }
        left.addArrangedSubview(performance)
        left.addArrangedSubview(powerStatus); powerStatus.font = .systemFont(ofSize:12); powerStatus.textColor = .secondaryLabelColor
        let legend = NSTextField(wrappingLabelWithString: "最近 1 小时 · CPU 蓝 / 内存 紫 / 温度 橙")
        legend.font = .systemFont(ofSize: 11); legend.textColor = .secondaryLabelColor; left.addArrangedSubview(legend)
        left.addArrangedSubview(trend); trend.heightAnchor.constraint(equalToConstant: 160).isActive = true
        let note = NSTextField(wrappingLabelWithString: "CPU／内存 0–100%，温度 0–110°C。仅记录已启用采集；缺失数据留空，关闭程序后清空。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; left.addArrangedSubview(note)
        left.addArrangedSubview(secondary); secondary.font = .systemFont(ofSize: 12); secondary.textColor = .secondaryLabelColor
        right.addArrangedSubview(thermal); right.addArrangedSubview(fanButton)
        let warningTitle = NSTextField(labelWithString: "运行状态"); warningTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        right.addArrangedSubview(warningTitle); right.addArrangedSubview(incidents)
        right.addArrangedSubview(notificationButton); right.addArrangedSubview(exportButton)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; right.addArrangedSubview(status)
        for (stack, views) in [(left, [performance, powerStatus, legend, trend, note, secondary] as [NSView]), (right, [thermal, incidents, status] as [NSView])] {
            for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
    }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class MetricTrendView: NSView {
    var points: [TrendPoint] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = bounds.insetBy(dx: 4, dy: 12)
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath()
        for n in 0...2 { let y = plot.minY + plot.height * CGFloat(n) / 2; grid.move(to: NSPoint(x: plot.minX,y:y)); grid.line(to: NSPoint(x:plot.maxX,y:y)) }; grid.stroke()
        guard let end = points.last?.time else { return }
        for (key,color,scale) in [(\TrendPoint.cpu, NSColor.systemBlue,100.0),(\TrendPoint.memory,NSColor.systemPurple,100.0),(\TrendPoint.temperature,NSColor.systemOrange,110.0)] {
            let path = NSBezierPath(); path.lineWidth = 1.7; var previous: Date?
            for point in points {
                guard let value = point[keyPath:key], value.isFinite else { previous = nil; continue }
                let x = plot.maxX - CGFloat(end.timeIntervalSince(point.time) / 3600) * plot.width
                let position = NSPoint(x:x,y:plot.minY + CGFloat(min(1,max(0,value/scale))) * plot.height)
                if let prior = previous, point.time.timeIntervalSince(prior) <= 25 { path.line(to:position) } else { path.move(to:position) }
                previous = point.time
            }
            color.setStroke(); path.stroke()
        }
    }
}
