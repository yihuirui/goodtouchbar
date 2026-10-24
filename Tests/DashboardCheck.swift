import Foundation
import AppKit
import SystemMonitoring

@main @MainActor
struct DashboardCheck {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS: \(label)") }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var history = MetricHistory(), snapshot = MetricsSnapshot()
        func sample(_ time: Date) -> MetricsSnapshot {
            var s = MetricsSnapshot()
            for (key,value) in [(MetricID.cpu.rawValue,30.0),(MetricID.memory.rawValue,24.0),("memory.total",32.0),(MetricID.cpuTemperature.rawValue,75.0)] {
                s.readings[key] = MetricReading(value,unit:"test",source:"fixture",sampledAt:time)
            }
            return s
        }
        snapshot = sample(now); history.append(snapshot,now:now)
        check(history.points.first?.memory == 75,"memory percentage uses fresh total")
        history.append(snapshot,now:now.addingTimeInterval(1)); check(history.points.count == 1,"callbacks do not oversample history")
        history.append(snapshot,now:now.addingTimeInterval(20)); check(history.points.last?.cpu == nil,"expired values create gaps")
        for n in 3...1000 { let t = now.addingTimeInterval(Double(n)*10); history.append(sample(t),now:t) }
        check(history.points.count == 361,"history bounded to one hour")
        history.append(sample(now),now:now); check(history.points.count == 1,"clock rollback discards future points")
        var tracker = IncidentTracker()
        check(tracker.update(["sensor_failed"],now:now).raised.isEmpty,"transient failures do not notify")
        check(tracker.update(["sensor_failed"],now:now.addingTimeInterval(10)).raised == ["sensor_failed"],"persistent failure raises once")
        check(tracker.update(["sensor_failed"],now:now.addingTimeInterval(30)).raised.isEmpty,"duplicates are merged")
        check(tracker.update([],now:now.addingTimeInterval(31)).recovered == ["sensor_failed"],"recovery clears warning")
        check(tracker.update(["fan_recovery_failed"],now:now).raised == ["fan_recovery_failed"],"recovery failure alerts immediately")
        let secret = "SECRET_ACCOUNT_SESSION_CONTENT"
        let fixturePath = FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-private-fixture").appendingPathComponent(secret).path
        let event: [String:Any] = ["event":"fan_control_failed","code":"hardware_write_failed","time":"2026-10-22T00:00:00Z","requestID":UUID().uuidString,"message":secret,"path":fixturePath,"token":secret,"elapsed_ms":123]
        let sanitized = DiagnosticExport.sanitizedEvents(try JSONSerialization.data(withJSONObject:event))
        let text = String(data:try JSONSerialization.data(withJSONObject:sanitized),encoding:.utf8)!
        check(!text.contains(secret) && !text.contains("/Users/"),"diagnostics strips content paths and token fields")
        check(text.contains("hardware_write_failed") && text.contains("requestID"),"controlled failure and correlation survive")
        check(DiagnosticExport.sanitizedEvents(Data("{\"event\":\"arbitrary_secret\"}\n".utf8)).isEmpty,"unknown events are omitted")
        check(DiagnosticExport.sanitizedEvents(Data("not json".utf8)).isEmpty,"malformed events are skipped")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let log = dir.appendingPathComponent("fan-client-events.jsonl")
        try JSONSerialization.data(withJSONObject:event).write(to:log)
        check((DiagnosticExport.collectLogs(directory:dir)["fan-client-events.jsonl"] as? [[String:Any]])?.count == 1,"collects whitelisted regular log")
        try FileManager.default.createSymbolicLink(at:dir.appendingPathComponent("token-events.jsonl"),withDestinationURL:log)
        check(DiagnosticExport.collectLogs(directory:dir)["token-events.jsonl"] is [String:String],"symlink log not followed")
        let alias = dir.appendingPathComponent("alias"); try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:dir)
        check(DiagnosticExport.collectLogs(directory:alias)["availability"] != nil,"symlink log directory refused")

        _ = NSApplication.shared
        let panel = PerformanceDashboard(frame:NSRect(x:0,y:0,width:820,height:540))
        let window = NSWindow(contentRect:panel.frame,styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = panel
        panel.performance.stringValue = "CPU 9%\n\n内存 24.5/32G（77%）\n\n压力 正常\n\n交换 0.1G"
        panel.thermal.stringValue = "CPU 83°C\n\nGPU 邻近 55°C\n\n电池 36°C\n\n风扇 1  3166 RPM\n\n风扇 2  2947 RPM\n\n风扇由系统自动控制"
        panel.incidents.stringValue = "暂无异常"; panel.status.stringValue = "诊断导出只包含脱敏元数据"
        panel.trend.points = (0...360).map { n in var h = MetricHistory(); h.append(sample(now.addingTimeInterval(Double(n)*10)),now:now.addingTimeInterval(Double(n)*10)); return h.points[0] }
        for width in [820.0,1040.0] {
            window.setContentSize(NSSize(width:width,height:540)); window.layoutIfNeeded(); panel.layoutSubtreeIfNeeded()
            func find(_ view:NSView,_ id:String) -> NSView? { if view.identifier?.rawValue == id { return view }; return view.subviews.compactMap { find($0,id) }.first }
            let left = find(panel,"dashboard-left")!, right = find(panel,"dashboard-right")!
            let l = left.convert(left.bounds,to:panel), r = right.convert(right.bounds,to:panel)
            check(l.maxX < r.minX && abs(l.width-r.width)<1 && l.width > (width - 70) / 2,"two equal columns at width \(width)")
            for view in [panel.performance,panel.thermal,panel.trend,panel.exportButton,panel.notificationButton] as [NSView] {
                check(panel.bounds.contains(view.convert(view.bounds,to:panel)),"visible control fits at width \(width)")
            }
        }
        window.setContentSize(NSSize(width:860,height:540)); window.layoutIfNeeded(); panel.layoutSubtreeIfNeeded()
        if let bitmap = panel.bitmapImageRepForCachingDisplay(in:panel.bounds) {
            panel.cacheDisplay(in:panel.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-dashboard-\(UUID().uuidString).png"))
        }
        window.close()
        print("\(count) dashboard/history/diagnostic checks passed")
    }
}
