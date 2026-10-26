import AppKit
import SystemMonitoring

@main @MainActor struct ControlsCheck {
    static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: \(label)") }
        // 假传感器通过子进程响应；CI 冷启动和负载会影响首个样本的到达时间。
        // 立即检查条件，最多等待 10 秒，并返回实际耗时供断言日志使用。
        @discardableResult
        func waitUntil(_ label:String,_ timeout:Double = 10,_ predicate:() -> Bool) async -> Double? {
            let began = ProcessInfo.processInfo.systemUptime
            let deadline = began + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                if predicate() { return ProcessInfo.processInfo.systemUptime - began }
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            FileHandle.standardError.write(Data("TIMEOUT: \(label) 未在 \(String(format:"%.3f",elapsed))s 内满足（上限 \(timeout)s）\n".utf8))
            return nil
        }
        let now = Date()
        var sample = MetricsSnapshot()
        func value(_ key:String,_ v:Double,_ date:Date = Date()) { sample.readings[key] = MetricReading(v,unit:"fixture",source:"AppleSMC TC0E",sampledAt:date) }
        value("system.cpu",79); check(MetricThresholds.level("system.cpu",snapshot:sample) == .normal,"below CPU threshold is normal")
        value("system.cpu",80); check(MetricThresholds.level("system.cpu",snapshot:sample) == .warning,"inclusive orange threshold")
        value("system.cpu",95); check(MetricThresholds.level("system.cpu",snapshot:sample) == .critical,"inclusive red threshold")
        value("system.cpu",99,now.addingTimeInterval(-30)); check(MetricThresholds.level("system.cpu",snapshot:sample) == .unavailable,"expired high value becomes unavailable")
        value("system.memory",90); value("memory.total",100); check(MetricThresholds.level("system.memory",snapshot:sample) == .critical,"memory uses fraction of total")
        value("memory.total",100,now.addingTimeInterval(-30)); check(MetricThresholds.level("system.memory",snapshot:sample) == .unavailable,"stale memory denominator rejected")
        value("system.cpuTemperature",85); check(MetricThresholds.level("system.cpuTemperature",snapshot:sample) == .warning,"temperature orange")
        check(MetricThresholds.level("system.cpuTemperature",snapshot:sample,overrides:["system.cpuTemperature":[60,80]]) == .critical,"custom temperature threshold")
        check(!MetricThresholds.valid(["system.cpu":[95,80]]) && !MetricThresholds.valid(["system.cpu":[80,101]]),"invalid threshold ranges rejected")
        check(!MetricThresholds.valid(["system.cpu":[.nan,95]]) && !MetricThresholds.valid(["system.cpu":[80]]),"invalid threshold shapes rejected")
        value("system.pressure",4); check(MetricThresholds.level("system.pressure",snapshot:sample) == .critical,"system pressure uses severity")
        sample.fans = [FanReading(id:0,actual:4800,minimum:1800,maximum:5000,target:4800,mode:"自动")]; value("system.fans",1)
        check(MetricThresholds.level("system.fans",snapshot:sample) == .critical,"fan color uses fraction of maximum")
        value("system.swap",3*1_073_741_824); check(MetricThresholds.level("system.swap",snapshot:sample) == .warning,"swap converted to GiB")
        sample.readings["system.cpuTemperature"] = MetricReading(66,unit:"°C",source:"AppleSMC TC0P")
        check(sample.text(for:"system.cpuTemperature") == "CPU 66°C","compact CPU label preserves proximity value")
        check(MetricThresholds.sensorName("TC0E").contains("虚拟") && MetricThresholds.sensorName("TC0F").contains("滤波"),"diode sources accurately distinguished")
        check(MetricThresholds.thermalStateText(.nominal).contains("正常"),"system thermal pressure independent of selected temperature")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("plugins.json"), marker = directory.appendingPathComponent("ran"), script = directory.appendingPathComponent("plugin.sh")
        try Data("printf 'yes' > '\(marker.path)'\nprintf 'fixture'\n".utf8).write(to:script)
        let original:[String:Any] = ["order":["gpt.status","script.example","future.metric"],"menuOrder":["script.example","gpt.usage"],"futureSetting":42,"scripts":[["id":"example","name":"示例脚本","script":script.path,"refreshSeconds":30,"enabled":false,"futureField":"keep"]]]
        try JSONSerialization.data(withJSONObject:original).write(to:file)
        let manager = TouchBarPluginManager(configurationURL:file)
        check(!manager.visibleKeys.contains("script.example") && manager.catalogKeys.contains("script.example"),"disabled plugin remains editable but hidden")
        manager.start(); manager.refreshScripts(); manager.scriptRuntimes.first?.handleTouchBarAction()
        try await Task.sleep(nanoseconds:150_000_000)
        check(!FileManager.default.fileExists(atPath:marker.path),"disabled script never executes including manual refresh")
        let before = try manager.configurationData()
        try manager.saveThresholds(["system.cpu":[70,90]])
        check(!FileManager.default.fileExists(atPath:marker.path),"threshold save does not execute scripts")
        var conflict = false
        do { try manager.saveScripts(manager.configuration.scripts,expected:before,barKeys:[],menuKeys:[]) } catch { conflict = true }
        check(conflict,"stale editor rejected after external configuration edit")
        let expected = try manager.configurationData()
        let enabledPlugin = TouchBarScriptPluginDefinition(id:"example",name:"更名",script:script.path,refreshSeconds:60,actionScript:nil,icon:nil,enabled:true)
        try manager.saveScripts([enabledPlugin],expected:expected,barKeys:["script.example"],menuKeys:[])
        try await Task.sleep(nanoseconds:500_000_000)
        check(FileManager.default.fileExists(atPath:marker.path),"explicit enable and save starts fixture script")
        let saved = try JSONSerialization.jsonObject(with:manager.configurationData()) as! [String:Any]
        check(saved["futureSetting"] as? Int == 42 && (saved["scripts"] as? [[String:Any]])?.first?["futureField"] as? String == "keep","unknown root and per-plugin fields retained")
        check(manager.configuration.order.contains("future.metric") && manager.visibleKeys.contains("script.example") && !manager.menuKeys.contains("script.example"),"built-in and future ordering preserved with independent positions")
        let expected2 = try manager.configurationData()
        var invalid = false
        do { try manager.saveScripts([TouchBarScriptPluginDefinition(id:"bad id",name:"Bad",script:script.path,refreshSeconds:30,actionScript:nil,icon:nil)],expected:expected2,barKeys:[],menuKeys:[]) } catch { invalid = true }
        let afterInvalid = try manager.configurationData()
        check(invalid && afterInvalid == expected2,"invalid form cannot corrupt disk configuration")
        try manager.saveScripts([],expected:expected2,barKeys:[],menuKeys:[])
        check(manager.scriptRuntimes.isEmpty && FileManager.default.fileExists(atPath:script.path),"delete removes runtime and retains actual script")
        check(FileManager.default.fileExists(atPath:file.appendingPathExtension("before-build38").path),"original configuration backup created")
        manager.stop()

        _ = NSApplication.shared
        let editor = PluginSettingsWindow(manager:manager,didSave:{})
        let content = editor.window!.contentView!
        func allViews(_ root:NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        func button(_ title:String) -> NSButton { allViews(content).compactMap { $0 as? NSButton }.first { $0.title == title }! }
        button("添加").performClick(nil)
        let fields = Dictionary(uniqueKeysWithValues:allViews(content).compactMap { view -> (String,NSTextField)? in guard let field = view as? NSTextField, let id = field.identifier?.rawValue else { return nil }; return (id,field) })
        fields["plugin-field-0"]!.stringValue = "图形配置测试"
        fields["plugin-field-2"]!.stringValue = script.path
        button("Touch Bar").state = .on
        button("保存插件设置").performClick(nil)
        check(manager.configuration.scripts.count == 1 && manager.configuration.scripts.first?.name == "图形配置测试","native form adds and saves plugin")
        check(manager.configuration.scripts.first?.enabled == false,"new GUI plugin disabled by default")
        editor.window!.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        for title in ["保存插件设置","添加","删除…","启用脚本（保存后执行）"] {
            let b = button(title); check(content.bounds.contains(b.convert(b.bounds,to:content)),"plugin editor control fits: \(title)")
        }
        fields["plugin-field-2"]!.stringValue = FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-plugin-fixture/status.sh").path
        if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) { content.cacheDisplay(in:content.bounds,to:bitmap); try bitmap.representation(using:.png,properties:[:])?.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-plugin-editor-\(UUID().uuidString).png")) }
        editor.window?.close()
        let monitor = SystemMetricsMonitor()
        let settings = MonitorSettingsWindow(manager:manager,monitor:monitor,preview:{_ in "--"},didSave:{})
        let settingsContent = settings.window!.contentView!
        func settingsButton(_ title:String) -> NSButton { allViews(settingsContent).compactMap { $0 as? NSButton }.first { $0.title == title }! }
        settingsButton("阈值颜色").performClick(nil)
        let thresholds = Dictionary(uniqueKeysWithValues:allViews(settingsContent).compactMap { view -> (String,NSTextField)? in guard let field = view as? NSTextField, let id = field.identifier?.rawValue else { return nil }; return (id,field) })
        check(thresholds.count == 14,"native threshold tab provides all seven pairs")
        thresholds["warning-system.cpu"]!.stringValue = "65"; thresholds["critical-system.cpu"]!.stringValue = "88"
        settingsButton("保存阈值").performClick(nil)
        check(manager.configuration.metricThresholds?["system.cpu"] == [65,88],"native threshold fields persist")
        thresholds["warning-system.cpu"]!.stringValue = "99"; settingsButton("保存阈值").performClick(nil)
        check(manager.configuration.metricThresholds?["system.cpu"] == [65,88],"invalid native threshold leaves prior settings intact")
        settings.window!.layoutIfNeeded(); settingsContent.layoutSubtreeIfNeeded()
        let saveThresholds = settingsButton("保存阈值")
        check(settingsContent.bounds.contains(saveThresholds.convert(saveThresholds.bounds,to:settingsContent)),"threshold save control remains visible")
        settings.window?.close(); monitor.stop()
        let sensor = directory.appendingPathComponent("sensor.py")
        let missingMarker = directory.appendingPathComponent("missing-cores")
        let requestLog = directory.appendingPathComponent("requests.jsonl")
        let markerLiteral = String(data:try JSONSerialization.data(withJSONObject:[missingMarker.path],options:.withoutEscapingSlashes),encoding:.utf8)!
        let logLiteral = String(data:try JSONSerialization.data(withJSONObject:[requestLog.path],options:.withoutEscapingSlashes),encoding:.utf8)!
        let python = """
        #!/usr/bin/python3
        import sys,json,time,os
        marker=\(markerLiteral)[0]
        log=\(logLiteral)[0]
        for line in sys.stdin:
            r=json.loads(line)
            with open(log,'a') as f: f.write(json.dumps(r)+'\\n')
            now=time.time()-978307200
            raw={'TC1C':92,'TC2C':80,'TC0E':98,'TC0F':99,'TC0P':70}
            if os.path.exists(marker): raw={k:v for k,v in raw.items() if k not in ['TC1C','TC2C']}
            values={k:{'value':v,'unit':'°C','source':'AppleSMC '+k,'sampledAt':now} for k,v in raw.items() if k in r['temperatureKeys']}
            print(json.dumps({'version':1,'requestID':r['requestID'],'sampledAt':now,'temperatures':values,'fans':[]}),flush=True)
        """
        try Data(python.utf8).write(to:sensor); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:sensor.path)
        let coreMonitor = SystemMetricsMonitor(sensorExecutable:sensor,cpuTemperatureKeys:CoreTemperature.intelKeys)
        coreMonitor.start()
        coreMonitor.configure(keys:[MetricID.cpuTemperature.rawValue],cpuTemperatureKey:CoreTemperature.selection)
        let coreSampleWait = await waitUntil("per-core maximum") { coreMonitor.snapshot.readings[MetricID.cpuTemperature.rawValue]?.value == 92 }
        if let coreSampleWait {
            FileHandle.standardError.write(Data("INFO: per-core maximum fixture sample arrived in \(String(format:"%.3f",coreSampleWait))s\n".utf8))
        } else {
            let metric = coreMonitor.snapshot.readings[MetricID.cpuTemperature.rawValue]
            let metricValue = metric?.value.map { String($0) } ?? "nil"
            let coreReadings = coreMonitor.temperatureReadings.sorted { $0.key < $1.key }.map {
                "\($0.key)=\($0.value.value.map { String($0) } ?? "nil")"
            }.joined(separator:", ")
            let requests = (try? String(contentsOf:requestLog,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "<unavailable>"
            let diagnostic = "DIAGNOSTIC: sensorError=\(coreMonitor.snapshot.sensorError ?? "nil"); cpuMetric=\(metricValue), source=\(metric?.source ?? "nil"); coreReadings=[\(coreReadings)]; requests=[\(requests)]\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
        check(coreSampleWait != nil && coreMonitor.snapshot.readings[MetricID.cpuTemperature.rawValue]?.value == 92,"monitor maps per-core maximum into CPU metric")
        check(coreMonitor.snapshot.readings["cpu.coreAverage"]?.value == 86 && coreMonitor.snapshot.readings["cpu.coreCount"]?.value == 2,"monitor retains mean and valid count")
        let requests = try String(contentsOf:requestLog).split(separator:"\n").compactMap { try? JSONDecoder().decode(SensorRequest.self,from:Data($0.utf8)) }
        check(requests.last?.temperatureKeys.contains("TC1C") == true && requests.last?.temperatureKeys.contains("TC0E") == false,"compact core mode requests cores without diode fallback")
        coreMonitor.configure(keys:[MetricID.cpuTemperature.rawValue],cpuTemperatureKey:"TC0P")
        await waitUntil("manual proximity") { coreMonitor.snapshot.readings[MetricID.cpuTemperature.rawValue]?.value == 70 }
        check(coreMonitor.snapshot.readings[MetricID.cpuTemperature.rawValue]?.value == 70,"manual proximity selection uses distinct reading")
        try Data().write(to:missingMarker)
        coreMonitor.configure(keys:[MetricID.cpuTemperature.rawValue],cpuTemperatureKey:CoreTemperature.selection)
        await waitUntil("missing cores") { coreMonitor.snapshot.text(for:MetricID.cpuTemperature.rawValue) == "CPU --" }
        check(coreMonitor.snapshot.text(for:MetricID.cpuTemperature.rawValue) == "CPU --","missing core readings never reuse previous proximity")
        coreMonitor.stop()
        try manager.saveDisplay(order:manager.visibleKeys,menuOrder:manager.menuKeys,catalogOrder:manager.catalogKeys,cpuTemperatureKey:"TC0P")
        _ = manager.reload()
        check(manager.selectedCPUTemperatureKey == "TC0P","configuration reload retains later user selection")
        let panel = MonitorSettingsWindow(manager:manager,monitor:SystemMetricsMonitor(),preview:{_ in "--"},didSave:{})
        let panelContent = panel.window!.contentView!
        allViews(panelContent).compactMap { $0 as? NSButton }.first { $0.title == "性能详情" }!.performClick(nil)
        let dashboard = allViews(panelContent).compactMap { $0 as? PerformanceDashboard }.first!
        dashboard.performance.stringValue = "CPU 60%\n\n内存 24.5/32G\n\n压力 正常\n\n交换 0.1G"
        dashboard.powerStatus.stringValue = "系统性能：已报告限制 · 速度上限 48%\n速度上限不是实际性能百分比，也不单独证明热降频"
        dashboard.thermal.stringValue = "CPU 92°C\nGPU邻近 60°C\n电池 35°C\n风扇 1 5600 RPM\n风扇 2 5200 RPM\n系统自动\n来源：CPU 核心最高温度\n核心最高 92.0°C · 平均 86.0°C\n有效核心：8\nTC0E 97.6°C / TC0F 98.8°C / TC0P 70.1°C\n系统热压力：较高"
        panel.window!.setContentSize(NSSize(width:820,height:620))
        panel.window!.layoutIfNeeded(); panelContent.layoutSubtreeIfNeeded()
        check(panelContent.bounds.contains(dashboard.exportButton.convert(dashboard.exportButton.bounds,to:panelContent)),"details export button fits minimum panel size")
        check(panelContent.bounds.contains(dashboard.powerStatus.convert(dashboard.powerStatus.bounds,to:panelContent)),"performance limit text fits minimum panel size")
        if let bitmap = panelContent.bitmapImageRepForCachingDisplay(in:panelContent.bounds) { panelContent.cacheDisplay(in:panelContent.bounds,to:bitmap); try bitmap.representation(using:.png,properties:[:])?.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-details-\(UUID().uuidString).png")) }
        panel.window?.close()
        print("\(count) threshold, sensor label and plugin editor checks passed")
    }
}
