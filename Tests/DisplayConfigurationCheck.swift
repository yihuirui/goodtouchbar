import Foundation
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { precondition(value()) }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { precondition(!value()) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
func XCTAssertEqual<T: Equatable>(_ a:T, _ b:T) { precondition(a == b, "Expected \(b), got \(a)") }
func XCTAssertLessThan<T: Comparable>(_ a:T, _ b:T) { precondition(a < b) }
func XCTAssertThrowsError<T>(_ body:@autoclosure () throws -> T) { do { _ = try body() } catch { return }; preconditionFailure("Expected failure") }
func XCTUnwrap<T>(_ value:T?) throws -> T { guard let value else { throw NSError(domain:"test",code:1) }; return value }

import AppKit
import GoodTouchBar
import SystemMonitoring

@MainActor final class DisplayTests {
    func testOldConfigurationMigratesWithoutLosingScriptsOrUnknownFields() async throws {
        try await MainActor.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:dir) }
            let file = dir.appendingPathComponent("plugins.json")
            let original: [String:Any] = ["order":["gpt.status","future.metric"],"scripts":[["id":"test","name":"Example","script":"/tmp/example.sh"]],"futureSetting":["a":true]]
            let originalData = try JSONSerialization.data(withJSONObject:original)
            try originalData.write(to:file)
            let manager = TouchBarPluginManager(configurationURL:file)
            let migratedData = try Data(contentsOf:file)
            XCTAssertEqual(manager.selectedCPUTemperatureKey,CoreTemperature.selection)
            XCTAssertEqual(try Data(contentsOf:file.appendingPathExtension("before-build40")),originalData)
            // Build43 起旧配置会自动补上「AI 速度」项，其余顺序不变。
            XCTAssertEqual(manager.visibleKeys,["gpt.status","agent.speed"])
            XCTAssertTrue(FileManager.default.fileExists(atPath:file.appendingPathExtension("before-build43").path))
            XCTAssertEqual(manager.menuKeys,["gpt.usage","tokens.today","pomodoro"])
            try manager.saveDisplay(order:["system.cpu","system.cpu"],menuOrder:[],catalogOrder:["system.cpu"],cpuTemperatureKey:"TC0F")
            let updated = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
            XCTAssertEqual(updated["order"] as? [String],["system.cpu","future.metric"])
            XCTAssertNotNil(updated["futureSetting"])
            XCTAssertEqual((updated["scripts"] as? [[String:Any]])?.count,1)
            XCTAssertEqual(try Data(contentsOf:file.appendingPathExtension("before-build33")),migratedData)
            XCTAssertEqual(manager.menuKeys,[])
            XCTAssertTrue(manager.catalogKeys.contains("script.test"))
            XCTAssertThrowsError(try manager.saveDisplay(order:[],menuOrder:[],catalogOrder:[],cpuTemperatureKey:"bad"))
            XCTAssertEqual(try Data(contentsOf:file.appendingPathExtension("before-build33")),migratedData)
            XCTAssertNil(manager.reload()); XCTAssertEqual(manager.visibleKeys,["system.cpu"])
        }
    }
    func testMalformedConfigurationDoesNotReplaceLastGoodState() async throws {
        try await MainActor.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:dir) }
            let file = dir.appendingPathComponent("plugins.json")
            try Data("{\"order\":[\"system.cpu\"],\"scripts\":[]}".utf8).write(to:file)
            let manager = TouchBarPluginManager(configurationURL:file)
            try Data("broken".utf8).write(to:file)
            XCTAssertNotNil(manager.reload()); XCTAssertEqual(manager.visibleKeys,["system.cpu","agent.speed"])
        }
    }
    /// 备份不能只是"存在"。这里真的恢复一次，验证它能被重新加载成有效配置。
    func testBackupCanBeRestored() async throws {
        try await MainActor.run {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:dir) }
            let file = dir.appendingPathComponent("plugins.json")
            try Data("{\"order\":[\"system.cpu\"],\"scripts\":[]}".utf8).write(to:file)
            let manager = TouchBarPluginManager(configurationURL:file)
            XCTAssertEqual(manager.visibleKeys,["system.cpu","agent.speed"])
            XCTAssertTrue(manager.availableBackups.contains { $0.lastPathComponent.hasSuffix("before-build43") })

            try manager.saveDisplay(order:["system.memory"],menuOrder:[],catalogOrder:["system.memory"],cpuTemperatureKey:"TC0P")
            XCTAssertEqual(manager.visibleKeys,["system.memory"])

            let restored = try manager.restoreLatestBackup()
            XCTAssertTrue(restored.lastPathComponent.hasPrefix("plugins.json.before-"))
            XCTAssertEqual(manager.visibleKeys,["system.cpu","agent.speed"])

            // 恢复本身也要留退路：当前（被覆盖掉的）配置另存为 before-restore-<时间戳>。
            let names = (try? FileManager.default.contentsOfDirectory(atPath:dir.path)) ?? []
            XCTAssertTrue(names.contains { $0.hasPrefix("plugins.json.before-restore-") })
            XCTAssertEqual(manager.selectedCPUTemperatureKey,"cpu.coreMax")
        }
    }
    func testSettingsWindowBuildsWithAllColumnsAndRows() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:dir) }
            let manager = TouchBarPluginManager(configurationURL:dir.appendingPathComponent("plugins.json"))
            let monitor = SystemMetricsMonitor()
            let settings = MonitorSettingsWindow(manager:manager,monitor:monitor,preview: { _ in "--" },didSave:{})
            guard let window = settings.window, let content = window.contentView else { preconditionFailure("No settings window") }
            @MainActor func tables(_ view:NSView) -> [NSTableView] {
                if let table = view as? NSTableView { return [table] }; return view.subviews.flatMap(tables)
            }
            let table = try XCTUnwrap(tables(content).first)
            XCTAssertEqual(table.numberOfColumns,4); XCTAssertEqual(table.numberOfRows,manager.allKeys.count)
            XCTAssertTrue(manager.catalogKeys.contains(MetricID.cpuTemperature.rawValue))
            window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
            @MainActor func buttons(_ view:NSView) -> [NSButton] {
                if let button = view as? NSButton { return [button] }; return view.subviews.flatMap(buttons)
            }
            let save = try XCTUnwrap(buttons(content).first { $0.title == "保存显示设置" })
            let saveFrame = save.convert(save.bounds,to:content)
            XCTAssertTrue(saveFrame.minY >= 0 && saveFrame.maxY <= content.bounds.height)

            if let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                content.cacheDisplay(in:content.bounds,to:bitmap)
                if let data = bitmap.representation(using:.png,properties:[:]) { try data.write(to:FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-settings-\(UUID().uuidString).png")) }
            }
            monitor.stop(); window.close()
        }
    }
    func testHealthChecksCurrentLayoutInsteadOfFiveOriginalControls() async throws {
        await MainActor.run {
            let monitor = HealthMonitor()
            var probe = TouchBarRuntimeProbe(
        windowReady: true,
        touchBarEnabled: true,
        touchBarInstalled: true,
        touchBarItemReady: true,
        codexTouchBarItemReady: true,
        quotaTouchBarItemReady: true,
        workbuddyTouchBarItemReady: true,
        tokenTouchBarItemReady: true,
        renderCount: 0,
        pomodoroRunning: false,
        pomodoroPhase: "focus",
        pomodoroCompletedToday: 0,
        remainingSeconds: 0,
        codexStatus: "idle",
        codexUpdatedAt: nil,
        quotaRemainingPercent: nil,
        quotaMinimumRemainingPercent: nil,
        quotaResetAt: nil,
        workbuddyStatus: "idle",
        workbuddyUpdatedAt: nil,
        todayTokens: nil,
        todayTokensUpdatedAt: nil,
        todayTokensStale: true,
        touchBarLayoutMode: "unknown",
        touchBarResolvedItemCount: 2,
        touchBarVisibleItemCount: 0,
        touchBarLayoutCheckedAt: nil,
        globalTouchBarEnabled: false,
        globalTouchBarSupported: false,
        globalTouchBarPresented: false,
        globalTouchBarActuallyVisible: false,
        globalTouchBarVisibilityCheckedAt: nil,
        globalTouchBarLastError: nil,
        lastError: nil,
        betterTouchToolInstalled: false,
        betterTouchToolRunning: false
    )
            probe.expectedTouchBarItemCount = 2
            probe.visibleMetricKeys = [MetricID.cpu.rawValue,MetricID.memory.rawValue]
            let snapshot = monitor.makeSnapshot(from:probe)
            XCTAssertEqual(snapshot.status,"healthy")
            XCTAssertEqual(snapshot.expectedTouchBarItemCount,2)
            probe.expectedTouchBarItemCount = 3
            XCTAssertEqual(monitor.makeSnapshot(from:probe).status,"waiting")
        }
    }
}

@main @MainActor struct DisplayChecks { static func main() async throws { let suite = DisplayTests()
try await suite.testHealthChecksCurrentLayoutInsteadOfFiveOriginalControls(); print("PASS: dynamic layout health")
try await suite.testOldConfigurationMigratesWithoutLosingScriptsOrUnknownFields(); print("PASS: testOldConfigurationMigratesWithoutLosingScriptsOrUnknownFields")
try await suite.testMalformedConfigurationDoesNotReplaceLastGoodState(); print("PASS: testMalformedConfigurationDoesNotReplaceLastGoodState")
try await suite.testSettingsWindowBuildsWithAllColumnsAndRows(); print("PASS: testSettingsWindowBuildsWithAllColumnsAndRows")
} }
