import AppKit
import Foundation
import SystemMonitoring

@main @MainActor struct PresetsCheck {
    static func main() throws {
        _ = NSApplication.shared
        var passed = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            passed += 1
            print("PASS: \(label)")
        }
        func rejects(_ object: [String: Any], _ label: String) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            do { _ = try GoodTouchBarLayoutPreset.decode(data); preconditionFailure(label) }
            catch is PresetError { passed += 1; print("PASS: \(label)") }
        }

        let validObject: [String: Any] = [
            "schema": "goodtouchbar-layout", "schemaVersion": 1, "name": "系统",
            "layout": ["system.cpu", "system.controls"],
            "thresholds": ["system.cpu": [80, 95]],
        ]
        let encoded = try JSONSerialization.data(withJSONObject: validObject)
        let preset = try GoodTouchBarLayoutPreset.decode(encoded)
        check(preset.layout == ["system.cpu", "system.controls"] && preset.menuLayout == preset.layout, "strict v1 preset migrates bar layout into menu layout")
        let v1Upgrade = try JSONSerialization.jsonObject(with: preset.encoded()) as! [String: Any]
        check(v1Upgrade["schemaVersion"] as? Int == 2 && v1Upgrade["menuLayout"] as? [String] == preset.layout, "v1 re-export upgrades to explicit v2 menu layout")
        check(try preset.encoded().count <= GoodTouchBarLayoutPreset.maximumBytes, "preset export stays under size limit")
        let distinctV2: [String: Any] = [
            "schema": "goodtouchbar-layout", "schemaVersion": 2, "name": "双布局",
            "layout": ["system.cpu", "system.controls"], "menuLayout": ["gpt.usage", "tokens.today"],
            "thresholds": ["system.cpu": [80, 95]],
        ]
        let v2 = try GoodTouchBarLayoutPreset.decode(JSONSerialization.data(withJSONObject: distinctV2))
        check(v2.layout != v2.menuLayout && v2.menuLayout == ["gpt.usage", "tokens.today"], "v2 preserves independent menu-only layout")

        var unknown = validObject; unknown["scripts"] = ["arbitrary shell"]
        try rejects(unknown, "rejects executable or unknown fields")
        var unknownMetric = validObject; unknownMetric["layout"] = ["system.notReal"]
        try rejects(unknownMetric, "rejects unknown layout metrics")
        var duplicates = validObject; duplicates["layout"] = ["system.cpu", "system.cpu"]
        try rejects(duplicates, "rejects duplicate layout items")
        var duplicateMenu = distinctV2; duplicateMenu["menuLayout"] = ["gpt.usage", "gpt.usage"]
        try rejects(duplicateMenu, "rejects duplicate menu layout items")
        var unknownMenu = distinctV2; unknownMenu["menuLayout"] = ["system.unknown"]
        try rejects(unknownMenu, "rejects unknown menu metrics")
        var unknownV2 = distinctV2; unknownV2["autoInstallHelper"] = true
        try rejects(unknownV2, "v2 rejects executable or automatic action fields")
        var badThreshold = validObject; badThreshold["thresholds"] = ["system.unknown": [1, 2]]
        try rejects(badThreshold, "rejects unknown threshold keys")
        var badOrder = validObject; badOrder["thresholds"] = ["system.cpu": [95, 80]]
        try rejects(badOrder, "rejects reversed threshold ranges")
        do { _ = try GoodTouchBarLayoutPreset.decode(Data(repeating: 0x20, count: GoodTouchBarLayoutPreset.maximumBytes + 1)); preconditionFailure("oversize accepted") }
        catch is PresetError { passed += 1; print("PASS: rejects oversized documents") }

        let router = SystemControlGestureRouter()
        var opened = 0, muted = 0
        router.dispatch(.tap, openPanel: { opened += 1 }, toggleMute: { muted += 1 })
        router.dispatch(.longPress, openPanel: { opened += 1 }, toggleMute: { muted += 1 })
        check(opened == 1 && muted == 1, "Touch Bar tap opens panel and long press toggles mute")
        check(SystemVolumeScale.clamp(-1) == 0 && SystemVolumeScale.clamp(2) == 1 && SystemVolumeScale.clamp(.nan) == 0, "volume changes are finite and bounded")
        let mediaPackets = SystemMediaKeyEncoding.playPauseSequence()
        check(mediaPackets.count == 2 && mediaPackets.allSatisfy { $0.eventType == 14 && $0.subtype == 8 && $0.data2 == -1 }, "media key uses NX_SYSDEFINED auxiliary-control packet fields")
        check((mediaPackets[0].data1 >> 16) == 16 && ((mediaPackets[0].data1 >> 8) & 0xff) == 0xA &&
              (mediaPackets[1].data1 >> 16) == 16 && ((mediaPackets[1].data1 >> 8) & 0xff) == 0xB,
              "play/pause packet encodes NX_KEYTYPE_PLAY down and up")
        var postedPackets: [SystemMediaKeyEvent] = []
        var trustedPromptOption = false
        let acceptedMedia = SystemMediaKeyAction(
            accessibilityTrusted: { prompt in trustedPromptOption = prompt; return true },
            postEvent: { postedPackets.append($0); return true }
        )
        if case .success = acceptedMedia.playPause() {
            check(trustedPromptOption && postedPackets == mediaPackets, "media action performs prompt-enabled trust check and sends down/up through injected sink")
        } else {
            check(false, "media action performs prompt-enabled trust check and sends down/up through injected sink")
        }
        var promptRequested = false
        var deniedPostCount = 0
        let deniedMedia = SystemMediaKeyAction(
            accessibilityTrusted: { prompt in promptRequested = prompt; return false },
            postEvent: { _ in deniedPostCount += 1; return true }
        )
        if case .failure(.accessibilityPermissionRequired) = deniedMedia.playPause() {
            check(promptRequested && deniedPostCount == 0, "missing Accessibility permission prompts on click and posts no input")
        } else {
            check(false, "missing Accessibility permission prompts on click and posts no input")
        }
        let failedMedia = SystemMediaKeyAction(accessibilityTrusted: { _ in true }, postEvent: { _ in false })
        if case .failure(.eventCreationFailed) = failedMedia.playPause() {
            check(true, "media event creation failure is reported without real input")
        } else {
            check(false, "media event creation failure is reported without real input")
        }
        let controls = SystemControlsWindow()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let controlViews = views(controls.window!.contentView!)
        let titles = Set(controlViews.compactMap { ($0 as? NSButton)?.title })
        check(["静音切换", "播放 / 暂停", "辅助功能设置…", "切换应用"].allSatisfy(titles.contains), "native controls expose mute, media, accessibility settings, and app switching actions")
        check(controlViews.contains { $0 is NSSlider }, "native controls expose an output volume slider")
        controls.window?.close()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("plugins.json")
        let originalObject: [String: Any] = [
            "version": 2, "agentSpeedVersion": 1, "coreTemperatureDisplayVersion": 1,
            "order": ["system.cpu", "script.manual"], "menuOrder": ["gpt.usage"],
            "catalogOrder": ["system.cpu", "script.manual"], "scripts": [["id": "manual", "name": "Manual", "script": "/tmp/goodtouchbar-fixture.sh", "enabled": false]],
            "cpuTemperatureKey": "cpu.coreMax", "futurePreference": ["retain": true],
        ]
        let originalData = try JSONSerialization.data(withJSONObject: originalObject, options: [.sortedKeys])
        try originalData.write(to: file)
        let manager = TouchBarPluginManager(configurationURL: file)
        try manager.applyPreset(preset)
        check(manager.configuration.order == ["system.cpu", "system.controls", "script.manual"], "preset changes only layout while preserving local script entry")
        check(manager.menuKeys == preset.menuLayout, "legacy v1 preset also sets a usable menu-only layout")
        check(manager.configuration.scripts.count == 1 && manager.configuration.scripts[0].script == "/tmp/goodtouchbar-fixture.sh", "preset does not install or remove script definitions")
        let applied = try JSONSerialization.jsonObject(with: manager.configurationData()) as! [String: Any]
        check((applied["futurePreference"] as? [String: Bool])?["retain"] == true, "preset application preserves unrelated configuration fields")
        check(manager.availableBackups.contains { $0.lastPathComponent.contains("before-preset-") }, "preset application creates a rollback backup")
        _ = try manager.restoreLatestBackup()
        check(manager.configuration.order == ["system.cpu", "script.manual"], "latest preset backup restores the prior layout")
        try manager.applyPreset(v2)
        check(manager.visibleKeys == v2.layout && manager.menuKeys == v2.menuLayout, "v2 applies independent bar and menu layouts")
        _ = try manager.restoreLatestBackup()
        check(SystemControlGestureRouter.destination(for: .tap) == .openPanel && SystemControlGestureRouter.destination(for: .longPress) == .toggleMute, "gesture meanings stay explicit")

        let defaultsName = "GoodTouchBarRuntimeTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        check(GoodTouchBarRuntimeConfiguration.selectedMode(defaults: defaults, infoValue: "auto") == .auto, "new installs default to Auto")
        defaults.set(true, forKey: GoodTouchBarRuntimeConfiguration.touchBarEnabledDefaultsKey)
        check(GoodTouchBarRuntimeConfiguration.selectedMode(defaults: defaults, infoValue: "auto") == .on, "legacy 0.1 true maps to On")
        defaults.set(false, forKey: GoodTouchBarRuntimeConfiguration.touchBarEnabledDefaultsKey)
        check(GoodTouchBarRuntimeConfiguration.selectedMode(defaults: defaults, infoValue: "auto") == .off, "legacy 0.1 false maps to Off")
        defaults.set("auto", forKey: GoodTouchBarRuntimeConfiguration.touchBarModeDefaultsKey)
        check(GoodTouchBarRuntimeConfiguration.selectedMode(defaults: defaults, infoValue: "off") == .auto, "new mode preference takes precedence over legacy Bool")
        let unsupported = GoodTouchBarDeviceCapabilities(modelIdentifier: "MacBookPro18,1", processArchitecture: "arm64", hostSupportsArm64: true, processTranslated: false)
        check(unsupported.resolveTouchBarMode(.on).enabled == false && unsupported.resolveTouchBarMode(.on).reason.contains("无法"), "manual On on a no-Touch-Bar Mac remains menu-only with reason")

        print("\(passed) public feature checks passed")
    }
}
