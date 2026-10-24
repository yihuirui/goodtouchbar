import AppKit
import Foundation
import FanControlCore
import SystemMonitoring

private let intelTestCapabilities = GoodTouchBarDeviceCapabilities(
    modelIdentifier: "MacBookPro16,2", processArchitecture: "x86_64",
    hostSupportsArm64: false, processTranslated: false
)

@MainActor
final class FakeFanTransport: FanControlTransport {
    var onDisconnect: (() -> Void)?
    var requests: [FanControlRequest] = []
    var current = FanControlStatus()
    var replyOK = true
    var replyCode = "ok"
    var hold = false
    var adaptive = false
    var pending: ((Result<Data, Error>) -> Void)?
    var pendingRequest: FanControlRequest?
    var invalidated = 0
    func send(_ data: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        let request = try! JSONDecoder().decode(FanControlRequest.self, from: data)
        requests.append(request)
        if hold { pending = completion; pendingRequest = request; return }
        if adaptive && request.action == .fixed { current = FanControlStatus(phase:.controlling,leaseID:"quick-lease",targets:request.targets,fans:current.fans,cpuTemperature:60,gpuTemperature:50) }
        if adaptive && request.action == .automatic { current = FanControlStatus(fans:current.fans,cpuTemperature:60,gpuTemperature:50) }
        let reply = FanControlReply(ok: replyOK, code: replyCode, status: current, requestID: request.requestID)
        completion(.success(try! JSONEncoder().encode(reply)))
    }
    func invalidate() { invalidated += 1 }
}

@main @MainActor
struct FanUIClientChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = MonitorEventLog(url: directory.appendingPathComponent("client.jsonl"))
        var count = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition, label); count += 1; print("PASS: \(label)") }
        let fans = [FanDeviceReading(id: 0, actualRPM: 2000, minimumRPM: 1800, maximumRPM: 5600, targetRPM: 2000, automatic: true), FanDeviceReading(id: 1, actualRPM: 1900, minimumRPM: 1700, maximumRPM: 5200, targetRPM: 1900, automatic: true)]
        let transport = FakeFanTransport(); transport.current = FanControlStatus(fans: fans, cpuTemperature: 60, gpuTemperature: 50)
        var now = 100.0, running: [String] = [], installCalls = 0
        let client = FanControlClient(transport: transport, installer: { _,_,_,completion in installCalls += 1; completion(.success(())) }, runningControllers: { running }, clock: { now }, eventLog: log, capabilities: intelTestCapabilities)
        check(FanControlClient.knownControllerName(for: "com.besttouchtool.app") == "BestTouchTool" &&
              FanControlClient.knownControllerName(for: "io.github.yihuirui.goodtouchbar") == nil,
              "legacy BestTouchTool is a fan-control conflict without treating goodtouchbar as external")
        client.refresh(); check(client.connected && client.statusFresh, "status connection")
        check(!client.canReuseFixedTargets, "quick control requires confirmed preset")
        check(client.message == "风扇由系统自动控制", "automatic requires fan readback")
        running = ["Stats"]; let before = transport.requests.count
        client.applyFixed(targets: [0: 2500]); check(transport.requests.count == before && client.message.contains("Stats"), "other controller blocks takeover")
        running = ["BestTouchTool"]; let legacyBefore = transport.requests.count
        client.applyFixed(targets: [0: 2500]); check(transport.requests.count == legacyBefore && client.message.contains("BestTouchTool"), "legacy BestTouchTool blocks takeover without changing fan state")
        running = []
        transport.current = FanControlStatus(phase: .controlling, leaseID: "lease-1", ownedFanIDs: [0,1], targets: [0:2500,1:2400], leaseExpiresAt: 110, boostExpiresAt: 400, fans: fans, cpuTemperature: 60, gpuTemperature: 50)
        client.applyFixed(targets: [0:2500,1:2400]); check(client.hasControl, "successful action owns lease")
        check(client.savedFixedTargets == [0:2500,1:2400] && client.canReuseFixedTargets, "successful fixed saves reusable preset")
        now = 101; client.tick(); check(transport.requests.last?.action == .status, "status between heartbeats")
        now = 102; client.tick(); check(transport.requests.last?.action == .heartbeat && transport.requests.last?.leaseID == "lease-1", "two second heartbeat")
        check(client.boostRemaining == 298, "boost deadline is not reset by heartbeat")
        transport.hold = true; now = 103; client.refresh(); let inFlight = transport.requests.count
        now = 104; client.tick(); client.applyFixed(targets: [0:2600]); check(transport.requests.count == inFlight, "no overlapping requests")
        let pending = transport.pending, request = transport.pendingRequest!
        transport.onDisconnect?(); check(!client.connected && !client.hasControl && client.message.contains("中断"), "disconnect clears ownership without claiming automatic")
        let lateReply = FanControlReply(ok: true, code: "ok", status: transport.current, requestID: request.requestID)
        pending?(.success(try JSONEncoder().encode(lateReply))); check(!client.connected && !client.hasControl, "late reply cannot revive lease")
        transport.hold = false
        transport.current = FanControlStatus(fans: [FanDeviceReading(id:0,actualRPM:2200,minimumRPM:1800,maximumRPM:5600,targetRPM:2200,automatic:false)])
        client.refresh(); check(!client.canReuseFixedTargets, "changed fan topology rejects old preset")
        check(client.message.contains("未接管"), "external manual is not displayed as automatic")
        client.restoreAutomatic(); check(!client.message.contains("已确认恢复"), "release does not claim external fan automatic")
        transport.replyOK = false; transport.replyCode = "temperature_high"
        transport.current = FanControlStatus(phase:.recoveryFailed, ownedFanIDs:[0], fans:fans, error:"restore_failed")
        client.restoreAutomatic(); check(client.message.contains("失败"), "recovery failure overrides transient notice")
        transport.hold = true; client.refresh()
        try await Task.sleep(nanoseconds: 3_200_000_000)
        check(!client.connected && !client.hasControl && !client.busy, "RPC timeout invalidates connection and control")
        transport.hold = false
        transport.replyOK = true; transport.current = FanControlStatus(fans:fans)
        client.install(); check(installCalls == 1 && !client.installationBusy, "installer injected without system authorization")
        check(FanControlClient.shellQuote("a'b") == "'a'\\''b'", "shell path quoting")
        check(FanControlClient.appleScriptLiteral("a\"b\\c") == "\"a\\\"b\\\\c\"", "AppleScript literal quoting")
        _ = NSApplication.shared
        let window = FanControlWindow(client:client)
        check(window.window?.title == "风扇控制", "fan window builds with fake hardware")
        if let content = window.window?.contentView {
            window.window?.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
            @MainActor func buttons(_ view:NSView) -> [NSButton] {
                if let button = view as? NSButton { return [button] }; return view.subviews.flatMap(buttons)
            }
            let labels = buttons(content).filter { ["应用固定转速", "强力散热 5 分钟", "停止并恢复系统自动", "安装／更新辅助服务…"].contains($0.title) }
            var allInside = labels.count == 4
            for button in labels { if !content.bounds.contains(button.convert(button.bounds, to:content)) { allInside = false } }
            check(allInside, "control buttons remain inside window")

            if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:bitmap)
                if let png = bitmap.representation(using:.png,properties:[:]) { try png.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-fan-preview-\(UUID().uuidString).png")) }
            }
        }
        transport.current = FanControlStatus(fans:fans,cpuTemperature:100,gpuTemperature:98)
        client.refresh(); window.render()
        func allViews(_ root:NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews) }
        let fanContent = window.window!.contentView!
        let fixedButton = allViews(fanContent).compactMap { $0 as? NSButton }.first { $0.title == "应用固定转速" }!
        check(fixedButton.isEnabled,"high temperature does not disable fixed-RPM button")
        check(allViews(fanContent).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("高温不会阻止设置或取消固定转速") },"high-temperature advisory stays visible")
        let requestsBeforeHot = transport.requests.count
        client.applyFixed(targets:[0:2500,1:2400])
        check(transport.requests.count == requestsBeforeHot + 1 && transport.requests.last?.action == .fixed,"client sends fixed-RPM request at high temperature")
        window.window!.appearance = NSAppearance(named:.darkAqua)
        window.window!.layoutIfNeeded(); fanContent.layoutSubtreeIfNeeded()
        let fanBitmap = fanContent.bitmapImageRepForCachingDisplay(in:fanContent.bounds)!
        window.window!.effectiveAppearance.performAsCurrentDrawingAppearance { fanContent.cacheDisplay(in:fanContent.bounds,to:fanBitmap) }
        let bg = fanBitmap.colorAt(x:8,y:8)!.usingColorSpace(.deviceRGB)!
        check((bg.redComponent + bg.greenComponent + bg.blueComponent)/3 < 0.35,"fan window background follows dark appearance")
        check(fanContent.bounds.contains(fixedButton.convert(fixedButton.bounds,to:fanContent)),"high-temperature warning leaves fixed control visible")
        try fanBitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"\(ProcessInfo.processInfo.environment["TASK_BUILD_DIR"] ?? FileManager.default.temporaryDirectory.path)/fan-dark.png"))
        transport.replyOK = false; transport.replyCode = "hardware_write_failed"
        transport.current = FanControlStatus(fans:fans,cpuTemperature:60,gpuTemperature:50,hardwareDiagnostic:"setTarget fan 0: F0Tg:write:smc_132")
        client.applyFixed(targets:[0:2500,1:2400])
        check(client.message.contains("F0Tg:write:smc_132"),"hardware register and result reach the visible client message")
        transport.replyOK = false; transport.replyCode = "invalid_target_or_limits"
        transport.current = FanControlStatus(fans:fans); client.refresh()
        client.applyFixed(targets:[0:3000,1:2900])
        check(client.savedFixedTargets == [0:2500,1:2400], "failed application does not overwrite confirmed preset")
        now += 5
        check(!client.canReuseFixedTargets, "stale status blocks quick enable")
        transport.replyOK = true; client.refresh()
        client.applySavedFixed()
        check(transport.requests.last?.targets == [0:2500,1:2400], "quick enable sends exact confirmed RPMs")
        transport.current = FanControlStatus(fans:[FanDeviceReading(id:0,actualRPM:2000,minimumRPM:2600,maximumRPM:5600,targetRPM:2000,automatic:true),fans[1]])
        client.refresh(); check(!client.canReuseFixedTargets, "changed hardware range blocks preset")
        client.stop(release:false); window.window?.close()
        check(!client.connected && !client.hasControl, "stop clears connection")
        let quickTransport = FakeFanTransport(); quickTransport.adaptive = true
        quickTransport.current = FanControlStatus(fans:fans,cpuTemperature:60,gpuTemperature:50)
        let quick = FanControlClient(transport:quickTransport,runningControllers:{[]},clock:{now},eventLog:log,capabilities:intelTestCapabilities)
        quick.refresh(); quick.toggleFixedMode()
        check(quick.hasControl && quickTransport.requests.last?.targets == [0:2000,1:1900], "first click freezes current actual RPM without settings")
        quick.toggleFixedMode(); check(quickTransport.requests.last?.action == .automatic && !quick.hasControl, "second click restores automatic")
        quickTransport.hold = true; quick.refresh()
        let pendingQuick = quickTransport.pending!, pendingQuickRequest = quickTransport.pendingRequest!
        quick.toggleFixedMode(); check(quick.quickModePending, "click during polling retained as one intent")
        let beforeDuplicate = quickTransport.requests.count; quick.toggleFixedMode()
        check(quickTransport.requests.count == beforeDuplicate, "repeated click cannot enqueue duplicate controls")
        quickTransport.hold = false
        pendingQuick(.success(try JSONEncoder().encode(FanControlReply(ok:true,code:"ok",status:quickTransport.current,requestID:pendingQuickRequest.requestID))))
        check(quick.hasControl && quickTransport.requests.last?.action == .fixed && !quick.quickModePending, "queued toggle runs after status reply")
        quick.toggleFixedMode(); now += 5
        let startRequests = quickTransport.requests.count; quick.toggleFixedMode()
        check(quickTransport.requests.count == startRequests+2 && quick.hasControl, "stale status refreshes then switches in one click")
        quick.toggleFixedMode(); quickTransport.hold = true; quick.refresh(); quick.toggleFixedMode(); quickTransport.onDisconnect?()
        check(!quick.quickModePending && !quick.hasControl, "connection loss cancels queued action")
        quick.stop(release:false)
        let armTransport = FakeFanTransport(); var armInstallCalls = 0
        let armClient = FanControlClient(transport: armTransport, installer: { _,_,_,completion in armInstallCalls += 1; completion(.success(())) }, eventLog: log,
            capabilities: GoodTouchBarDeviceCapabilities(modelIdentifier:"MacBookPro18,1",processArchitecture:"x86_64",hostSupportsArm64:true,processTranslated:true))
        armClient.start(); armClient.refresh(); armClient.install(); armClient.applyFixed(targets:[0:2400])
        check(!armClient.fanControlAvailable && armTransport.requests.isEmpty && armInstallCalls == 0,
              "ARM host running an x86 executable cannot connect or invoke Intel helper installation")
        check(armClient.message.contains("系统管理") || armClient.message.contains("Intel"),
              "blocked fan client reports read-only system-managed behavior")
        armClient.stop(release:false)
        print("\(count) fan client and window checks passed; no real RPC, install, or hardware writes")
    }
}
