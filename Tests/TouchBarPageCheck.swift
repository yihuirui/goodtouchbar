import AppKit
import Foundation
import FanControlCore
import SystemMonitoring

@MainActor final class PageFanTransport: FanControlTransport {
    var onDisconnect: (() -> Void)?
    var requests: [FanControlRequest] = []
    let fans = [FanDeviceReading(id:0,actualRPM:2400,minimumRPM:1800,maximumRPM:5600,targetRPM:2400,automatic:true),FanDeviceReading(id:1,actualRPM:2300,minimumRPM:1700,maximumRPM:5200,targetRPM:2300,automatic:true)]
    var controlling = false
    func send(_ data:Data,completion:@escaping (Result<Data,Error>)->Void) {
        let request = try! JSONDecoder().decode(FanControlRequest.self,from:data); requests.append(request)
        if request.action == .fixed { controlling = true }
        if request.action == .automatic { controlling = false }
        let status = FanControlStatus(phase:controlling ? .controlling : .automatic,leaseID:controlling ? "fixture-lease" : nil,targets:controlling ? [0:2500,1:2400] : [:],fans:fans,cpuTemperature:60,gpuTemperature:50)
        completion(.success(try! JSONEncoder().encode(FanControlReply(ok:true,code:"ok",status:status,requestID:request.requestID))))
    }
    func invalidate() {}
}

@main @MainActor struct TouchBarPageCheck {
    static func main() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        var count = 0
        func check(_ value:Bool,_ message:String) { precondition(value,message); count += 1; print("PASS: \(message)") }
        let manager = TouchBarPluginManager(configurationURL:dir.appendingPathComponent("plugins.json"))
        let transport = PageFanTransport()
        let fan = FanControlClient(transport:transport,runningControllers:{[]},eventLog:MonitorEventLog(url:dir.appendingPathComponent("fan.jsonl")),capabilities:GoodTouchBarDeviceCapabilities(modelIdentifier:"MacBookPro16,2",processArchitecture:"x86_64",hostSupportsArm64:false,processTranslated:false))
        let controller = MainWindowController(healthMonitor:HealthMonitor(),pluginManager:manager,fanClient:fan,model:PomodoroModel(stateFileURL:dir.appendingPathComponent("pomodoro.json")),startMonitoring:false,touchBarEnabled:true)
        func items() -> [NSButtonTouchBarItem] {
            let bar = controller.makeTouchBar()!
            return bar.defaultItemIdentifiers.compactMap { bar.item(forIdentifier:$0) as? NSButtonTouchBarItem }
        }
        func press(_ item:NSButtonTouchBarItem) { check(NSApp.sendAction(item.action!,to:item.target,from:item),"Touch Bar action dispatch") }
        check(items().last?.title == "更多","home always has More")
        press(items().last!)
        check(items().count == 6,"performance page has six controls")
        check(items().map(\.title) == ["返回","CPU --","内存 --","CPU --","风扇 -- RPM","自动→固定"],"More switches to requested metrics and control")
        check(fan.quickControlsVisible,"performance page requests fresh fan status")
        let total = items().reduce(CGFloat(40)) { sum,item in sum + (item.view?.constraints.first { $0.firstAttribute == .width }?.constant ?? 0) }
        check(total <= 650 && total > 600,"performance controls fit conservative Touch Bar budget")
        let global = controller.touchBarForGlobalPresentation()!
        let container = global.item(forIdentifier:global.defaultItemIdentifiers[0]) as! NSCustomTouchBarItem
        let globalViews = (container.view as! NSStackView).arrangedSubviews
        check(globalViews.count == 6,"global container retains all six controls")
        check(zip(globalViews,items()).allSatisfy { $0.0 !== $0.1.view },"window and global use independent views")
        fan.applyFixed(targets:[0:2500,1:2400]); fan.restoreAutomatic()
        press(items().first!); check(items().last?.title == "更多" && !fan.quickControlsVisible,"Back restores home and idle polling")
        press(items().last!); check(items().last?.title == "自动→固定","confirmed preset can be enabled")
        press(items().last!); check(transport.requests.last?.action == .fixed && transport.requests.last?.targets == [0:2500,1:2400],"toggle sends exact saved speeds")
        press(items().last!); check(transport.requests.last?.action == .automatic,"toggle off restores automatic")
        press(items().first!); press(items().last!)
        check(items().count == 6,"repeated navigation preserves full page")
        try controller.applyPreset(GoodTouchBarLayoutPreset(name:"controls",layout:[TouchBarPluginKey.systemControls],thresholds:[:]))
        let controlsItem = items().first!
        check(controlsItem.title == "系统控制", "system controls are a configurable Touch Bar item")
        check((controlsItem.view as? NSButton)?.gestureRecognizers.contains { $0 is NSPressGestureRecognizer } == true, "Touch Bar item wires the documented long-press mute gesture")

        let menuDelegate = AppDelegate()
        let menuOnly = NSMenu()
        check(!menuDelegate.addPomodoroMenuItems(to:menuOnly,enabled:false)
              && menuOnly.items.isEmpty,"menu-only app omits every Pomodoro menu entry")
        let touchBarMenu = NSMenu()
        check(menuDelegate.addPomodoroMenuItems(to:touchBarMenu,enabled:true)
              && touchBarMenu.items.contains { $0.title == "开始短休息" }
              && touchBarMenu.items.contains { $0.title == "番茄钟结束声音" },"Touch Bar mode retains Pomodoro menu controls")

        let noTouchBar = GoodTouchBarDeviceCapabilities(modelIdentifier:"MacBookPro18,1",processArchitecture:"arm64",hostSupportsArm64:true,processTranslated:false)
        let persistedRunningState:[String:Any] = [
            "phase":"focus", "remainingSeconds":1499, "isRunning":true,
            "endDate":ISO8601DateFormatter().string(from:Date().addingTimeInterval(1200)),
            "completedToday":0, "totalCompleted":0,
            "statsDayStart":Calendar.current.startOfDay(for:Date()).timeIntervalSince1970,
        ]
        let pomodoroStateURL = dir.appendingPathComponent("menu-only-pomodoro.json")
        try JSONSerialization.data(withJSONObject:persistedRunningState).write(to:pomodoroStateURL)
        let menuOnlyFan = FanControlClient(transport:PageFanTransport(),runningControllers:{[]},eventLog:MonitorEventLog(url:dir.appendingPathComponent("menu-only-fan.jsonl")),capabilities:noTouchBar)
        let menuOnlyController = MainWindowController(
            healthMonitor:HealthMonitor(),pluginManager:TouchBarPluginManager(configurationURL:dir.appendingPathComponent("menu-only-plugins.json")),
            fanClient:menuOnlyFan,startMonitoring:false,deviceCapabilities:noTouchBar,pomodoroStateFileURL:pomodoroStateURL
        )
        check(!menuOnlyController.healthProbe(globalTouchBar:.disabled).pomodoroRunning,
              "menu-only startup does not restore a previously running Pomodoro timer")
        func allViews(_ root:NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        let pomodoroButtons = allViews(menuOnlyController.window!.contentView!).compactMap { $0 as? NSButton }.filter { ["开始","短休息","长休息","重置"].contains($0.title) }
        check(pomodoroButtons.count == 4 && pomodoroButtons.allSatisfy(\.isHidden),
              "menu-only main window hides Pomodoro actions")
        menuOnlyController.window?.close()
        fan.stop(release:false); controller.window?.close()
        print("\(count) native Touch Bar page checks passed; no hardware writes or real transport")
    }
}
