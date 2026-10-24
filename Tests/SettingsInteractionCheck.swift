import AppKit
import SystemMonitoring

@main @MainActor struct SettingsInteractionCheck {
    static func main() throws {
        _ = NSApplication.shared
        var count = 0
        func check(_ value:Bool,_ message:String) { precondition(value,message); count += 1; print("PASS: \(message)") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let manager = TouchBarPluginManager(configurationURL:dir.appendingPathComponent("plugins.json"))
        let monitor = SystemMetricsMonitor()
        var saved = 0, openedFan = 0, openedPlugins = 0, value = 10
        let settings = MonitorSettingsWindow(manager:manager,monitor:monitor,preview:{_ in "CPU \(value)%"},didSave:{ saved += 1 })
        settings.onOpenFanControl = { openedFan += 1 }; settings.onOpenPlugins = { openedPlugins += 1 }
        let window = settings.window!, content = window.contentView!
        func views(_ root:NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
        func button(_ title:String) -> NSButton { views(content).compactMap { $0 as? NSButton }.first { $0.title == title }! }
        let tabs = views(content).compactMap { $0 as? NSTabView }.first!
        let table = views(content).compactMap { $0 as? NSTableView }.first!
        let hasTouchBar = GoodTouchBarDeviceCapabilities.current.touchBarSupported
        let selectedLayoutColumn = hasTouchBar ? 1 : 2
        check(table.tableColumns[1].isHidden == !hasTouchBar,"Touch Bar layout column follows detected hardware")
        func reachable(_ b:NSButton) -> Bool {
            window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
            let point = b.convert(NSPoint(x:b.bounds.midX,y:b.bounds.midY),to:content)
            guard let hit = content.hitTest(point) else { return false }
            return hit === b || hit.isDescendant(of:b)
        }
        window.orderFront(nil)
        for theme in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance = NSAppearance(named:theme)
            for (title,id) in [("性能详情","details"),("阈值颜色","thresholds"),("显示项目","display")] {
                let b = button(title); check(reachable(b),"navigation hit test: \(theme.rawValue) \(title)")
                b.performClick(nil)
                for _ in 0..<15 { value += 1; settings.render() }
                check(tabs.selectedTabViewItem?.identifier as? String == id,"tab selection survives refresh: \(id)")
            }
            if GoodTouchBarDeviceCapabilities.current.canUseIntelFanHelper {
                button("风扇调速").performClick(nil)
                check(openedFan > 0,"native Intel exposes the experimental fan control entry")
            } else {
                check(views(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "风扇由 macOS 自动管理（只读）" },"ARM and Rosetta hide fan writes and explain system management")
            }
            button("插件配置").performClick(nil)
            check(openedPlugins > 0,"plugin settings action remains connected")
            let row = manager.catalogKeys.firstIndex(of:MetricID.cpu.rawValue)!
            table.scrollRowToVisible(row); window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
            let checkbox = table.view(atColumn:selectedLayoutColumn,row:row,makeIfNecessary:true) as! NSButton
            let old = checkbox.state; checkbox.performClick(nil)
            let expected = checkbox.state
            check(old != expected,"checkbox toggles")
            let preview = table.view(atColumn:3,row:row,makeIfNecessary:true) as! NSTextField
            for _ in 0..<30 { value += 1; settings.render() }
            check(table.view(atColumn:selectedLayoutColumn,row:row,makeIfNecessary:false) === checkbox && checkbox.state == expected,"refresh preserves checkbox object and selection")
            check(table.view(atColumn:3,row:row,makeIfNecessary:false) === preview && preview.stringValue == "CPU \(value)%","preview updates in place")
            check(reachable(button("保存显示设置")),"save button receives pointer events")
            button("保存显示设置").performClick(nil)
            let selectedLayoutContainsCPU = hasTouchBar
                ? manager.visibleKeys.contains(MetricID.cpu.rawValue)
                : manager.menuKeys.contains(MetricID.cpu.rawValue)
            check(selectedLayoutContainsCPU == (expected == .on),"display selection persists in the active layout")
            button("阈值颜色").performClick(nil)
            let fields = views(content).compactMap { $0 as? NSTextField }
            let warning = fields.first { $0.identifier?.rawValue == "warning-system.cpuTemperature" }!
            let critical = fields.first { $0.identifier?.rawValue == "critical-system.cpuTemperature" }!
            window.makeFirstResponder(warning)
            warning.currentEditor()?.string = "87"
            critical.stringValue = "97"
            for _ in 0..<15 { settings.render() }
            check(warning.currentEditor()?.string == "87","threshold field editor survives updates")
            button("保存阈值").performClick(nil)
            check(manager.configuration.metricThresholds?["system.cpuTemperature"] == [87,97],"threshold save reads active field editor")
            window.makeFirstResponder(nil)
            let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds)!
            window.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in:content.bounds,to:bitmap) }
            let color = bitmap.colorAt(x:8,y:8)!.usingColorSpace(.deviceRGB)!
            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            check(theme == .darkAqua ? brightness < 0.35 : brightness > 0.65,"background matches semantic appearance: \(theme.rawValue)")
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(ProcessInfo.processInfo.environment["TASK_BUILD_DIR"] ?? FileManager.default.temporaryDirectory.path)/settings-\(theme == .darkAqua ? "dark" : "light").png"))
            button("显示项目").performClick(nil)
        }
        window.close(); window.orderFront(nil); button("显示项目").performClick(nil)
        check(reachable(button("性能详情")) && saved >= 4,"close and reopen leaves settings usable")
        window.close(); monitor.stop()
        print("\(count) native settings appearance and interaction checks passed")
    }
}
