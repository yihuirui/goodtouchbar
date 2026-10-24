import AppKit
import CoreAudio
import Darwin
import Foundation
import Quartz
import ApplicationServices

enum SystemControlGesture: Equatable { case tap, longPress }
enum SystemControlDestination: Equatable { case openPanel, toggleMute }

struct SystemControlGestureRouter {
    static func destination(for gesture: SystemControlGesture) -> SystemControlDestination {
        switch gesture {
        case .tap: return .openPanel
        case .longPress: return .toggleMute
        }
    }

    func dispatch(_ gesture: SystemControlGesture, openPanel: () -> Void, toggleMute: () -> Void) {
        switch Self.destination(for: gesture) {
        case .openPanel: openPanel()
        case .toggleMute: toggleMute()
        }
    }
}

enum SystemVolumeScale {
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// `NX_SYSDEFINED` media-key packets as represented by public AppKit/IOKit
/// event constants. The values correspond to NX_SYSDEFINED (14),
/// NX_SUBTYPE_AUX_CONTROL_BUTTONS (8), and NX_KEYTYPE_PLAY (16).
struct SystemMediaKeyEvent: Equatable {
    let eventType: UInt32
    let subtype: Int16
    let modifierFlags: UInt
    let data1: Int
    let data2: Int
}

enum SystemMediaKeyEncoding {
    static let systemDefinedEvent: UInt32 = 14
    static let auxiliaryControlSubtype: Int16 = 8
    static let playKeyCode = 16
    static let keyDownState = 0xA
    static let keyUpState = 0xB
    static let mediaKeyModifierFlags: UInt = 0xA00

    static func playPauseSequence() -> [SystemMediaKeyEvent] {
        [keyEvent(state: keyDownState), keyEvent(state: keyUpState)]
    }

    private static func keyEvent(state: Int) -> SystemMediaKeyEvent {
        SystemMediaKeyEvent(
            eventType: systemDefinedEvent,
            subtype: auxiliaryControlSubtype,
            modifierFlags: mediaKeyModifierFlags,
            data1: (playKeyCode << 16) | (state << 8),
            data2: -1
        )
    }
}

enum SystemMediaKeyError: Error, Equatable {
    case accessibilityPermissionRequired
    case eventCreationFailed
}

/// The injected closures keep event creation and the permission failure path
/// testable without posting input or changing system state.
struct SystemMediaKeyAction {
    private let accessibilityTrusted: (Bool) -> Bool
    private let postEvent: (SystemMediaKeyEvent) -> Bool

    init(
        accessibilityTrusted: @escaping (Bool) -> Bool = Self.checkAccessibility,
        postEvent: @escaping (SystemMediaKeyEvent) -> Bool = Self.post
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.postEvent = postEvent
    }

    func playPause() -> Result<Void, SystemMediaKeyError> {
        guard accessibilityTrusted(true) else {
            return .failure(.accessibilityPermissionRequired)
        }
        for event in SystemMediaKeyEncoding.playPauseSequence() {
            guard postEvent(event) else { return .failure(.eventCreationFailed) }
        }
        return .success(())
    }

    private static func checkAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func post(_ packet: SystemMediaKeyEvent) -> Bool {
        guard packet.eventType == SystemMediaKeyEncoding.systemDefinedEvent,
              let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: packet.modifierFlags),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: packet.subtype,
                data1: packet.data1,
                data2: packet.data2
              ), let cgEvent = event.cgEvent else { return false }
        cgEvent.post(tap: .cghidEventTap)
        return true
    }
}

/// Uses public CoreAudio output-volume properties. Devices without a writable
/// volume property remain supported, but the slider is shown as unavailable.
struct SystemOutputVolume {
    func isWritable() -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        for element in [0, 1, 2] {
            var property = address(element: AudioObjectPropertyElement(element))
            if AudioObjectHasProperty(device, &property), isSettable(device: device, address: &property) { return true }
        }
        return false
    }

    func read() -> Double? {
        guard let device = defaultOutputDevice() else { return nil }
        if let master = read(device: device, element: kAudioObjectPropertyElementMain) { return master }
        let channels = [1, 2].compactMap { read(device: device, element: AudioObjectPropertyElement($0)) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0.0, +) / Double(channels.count)
    }

    @discardableResult
    func write(_ value: Double) -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        let level = Float(SystemVolumeScale.clamp(value))
        var master = address(element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &master), isSettable(device: device, address: &master) {
            return set(level, device: device, address: &master)
        }
        var wroteAny = false
        for element in [1, 2] {
            var channel = address(element: AudioObjectPropertyElement(element))
            guard AudioObjectHasProperty(device, &channel), isSettable(device: device, address: &channel) else { continue }
            wroteAny = set(level, device: device, address: &channel) || wroteAny
        }
        return wroteAny
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func address(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func read(device: AudioDeviceID, element: AudioObjectPropertyElement) -> Double? {
        var property = address(element: element)
        guard AudioObjectHasProperty(device, &property) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr,
              value.isFinite else { return nil }
        return SystemVolumeScale.clamp(Double(value))
    }

    private func isSettable(device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func set(_ value: Float, device: AudioDeviceID, address: inout AudioObjectPropertyAddress) -> Bool {
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &mutableValue) == noErr
    }
}

@MainActor
final class SystemControlsWindow: NSWindowController, NSWindowDelegate {
    private let volume = SystemOutputVolume()
    private var lastAudibleVolume: Double = 0.5
    private var slider: NSSlider!
    private var volumeLabel: NSTextField!
    private var mediaStatusLabel: NSTextField!
    private var applicationPicker: NSPopUpButton!
    private var applications: [NSRunningApplication] = []

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "系统控制"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContents()
        refreshVolume()
        refreshApplications()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        refreshVolume()
        refreshApplications()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleMute() {
        let current = volume.read() ?? 0
        if current > 0.01 {
            lastAudibleVolume = current
            _ = volume.write(0)
        } else {
            _ = volume.write(lastAudibleVolume > 0.01 ? lastAudibleVolume : 0.5)
        }
        refreshVolume()
    }

    private func buildContents() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        volumeLabel = NSTextField(labelWithString: "主输出音量")
        slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged))
        slider.widthAnchor.constraint(equalToConstant: 380).isActive = true
        root.addArrangedSubview(volumeLabel)
        root.addArrangedSubview(slider)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        let mute = NSButton(title: "静音切换", target: self, action: #selector(toggleMuteAction))
        let media = NSButton(title: "播放 / 暂停", target: self, action: #selector(playPause))
        actions.addArrangedSubview(mute)
        actions.addArrangedSubview(media)
        root.addArrangedSubview(actions)
        mediaStatusLabel = NSTextField(wrappingLabelWithString: "播放控制发送系统媒体键；当前播放器可能不响应。首次使用需要辅助功能权限。")
        root.addArrangedSubview(mediaStatusLabel)
        let accessibilitySettings = NSButton(title: "辅助功能设置…", target: self, action: #selector(openAccessibilitySettings))
        root.addArrangedSubview(accessibilitySettings)

        applicationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        applicationPicker.widthAnchor.constraint(equalToConstant: 270).isActive = true
        let switchButton = NSButton(title: "切换应用", target: self, action: #selector(switchApplication))
        let appRow = NSStackView(views: [applicationPicker, switchButton])
        appRow.orientation = .horizontal
        appRow.spacing = 8
        root.addArrangedSubview(appRow)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "长按 Touch Bar 的“系统控制”可切换静音。播放/暂停使用系统媒体键，效果受当前播放器支持影响。"))
        window?.contentView = root
    }

    private func refreshVolume() {
        guard volume.isWritable(), let value = volume.read() else {
            volumeLabel.stringValue = "主输出不支持软件音量控制"
            slider.isEnabled = false
            return
        }
        slider.doubleValue = value
        slider.isEnabled = true
        volumeLabel.stringValue = value <= 0.01 ? "主输出：静音" : "主输出：\(Int((value * 100).rounded()))%"
        if value > 0.01 { lastAudibleVolume = value }
    }

    private func refreshApplications() {
        applications = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        applicationPicker.removeAllItems()
        for application in applications { applicationPicker.addItem(withTitle: application.localizedName ?? application.bundleIdentifier ?? "应用") }
        applicationPicker.isEnabled = !applications.isEmpty
    }

    @objc private func volumeChanged() {
        if volume.write(slider.doubleValue) { refreshVolume() }
        else { volumeLabel.stringValue = "当前输出设备拒绝更改音量" }
    }

    @objc private func toggleMuteAction() { toggleMute() }

    @objc private func playPause() {
        switch SystemMediaKeyAction().playPause() {
        case .success:
            mediaStatusLabel.stringValue = "已发送系统播放/暂停键；当前播放器可能不响应。"
        case .failure(.accessibilityPermissionRequired):
            mediaStatusLabel.stringValue = "未发送：请在“辅助功能设置”中允许 goodtouchbar，然后再次点击。macOS 已请求授权。"
        case .failure(.eventCreationFailed):
            mediaStatusLabel.stringValue = "未发送：无法创建系统媒体键事件。"
        }
    }

    @objc private func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func switchApplication() {
        guard applications.indices.contains(applicationPicker.indexOfSelectedItem) else { return }
        _ = applications[applicationPicker.indexOfSelectedItem].activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }
}
