import AppKit
import SystemMonitoring
import Darwin
import Foundation
import ObjectiveC.runtime
import os.log

private let globalTouchBarLogger = Logger(
    subsystem: "io.github.yihuirui.goodtouchbar",
    category: "GlobalTouchBar"
)

struct GlobalTouchBarPresentationSnapshot {
    let enabled: Bool
    let supported: Bool
    let presented: Bool
    let actuallyVisible: Bool
    let visibilityCheckedAt: Date?
    let lastError: String?

    static let disabled = GlobalTouchBarPresentationSnapshot(
        enabled: false,
        supported: false,
        presented: false,
        actuallyVisible: false,
        visibilityCheckedAt: nil,
        lastError: nil
    )
}

@MainActor
final class GlobalTouchBarPresenter: NSObject {
    private static let enabledDefaultsKey = "experimentalGlobalTouchBarEnabled"
    private static let trayItemIdentifier = NSTouchBarItem.Identifier(
        "io.github.yihuirui.goodtouchbar.global.tray"
    )

    private var touchBar: NSTouchBar
    private let defaults: UserDefaults
    private var workspaceObserver: NSObjectProtocol?
    private var pendingPresentation: DispatchWorkItem?
    private var visibilityCheckWorkItem: DispatchWorkItem?
    private var visibilityMonitorTimer: Timer?
    private var trayItem: NSCustomTouchBarItem?
    private var recovery = PresentationRecovery()
    private let eventLog = MonitorEventLog(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar/touchbar-events.jsonl"))
    private func resetRecovery() { recovery.reset() }
    private func recordFailure() {
        if recovery.failures == 0 { eventLog.record("presentation_failed") }
        if let delay = recovery.failed(now: ProcessInfo.processInfo.systemUptime) { schedulePresentation(delay: delay) }
        else { lastError = "全局栏暂不可见，请切换应用或刷新"; eventLog.record("presentation_recovery_paused", fields: ["attempts":recovery.failures]) }
    }
    private func recovered() {
        if recovery.failures > 0 { eventLog.record("presentation_recovered", fields:["attempts":recovery.failures]) }
        recovery.reset(); lastError = nil
    }

    private(set) var isEnabled: Bool
    private(set) var isPresented = false
    private(set) var isActuallyVisible = false
    private(set) var visibilityCheckedAt: Date?
    private(set) var lastError: String?

    var onChange: (() -> Void)?

    var isSupported: Bool {
        PrivateTouchBarAPI.supportsSystemModalPresentation
    }

    var snapshot: GlobalTouchBarPresentationSnapshot {
        GlobalTouchBarPresentationSnapshot(
            enabled: isEnabled,
            supported: isSupported,
            presented: isPresented,
            actuallyVisible: isActuallyVisible,
            visibilityCheckedAt: visibilityCheckedAt,
            lastError: lastError
        )
    }

    init(touchBar: NSTouchBar, defaults: UserDefaults = .standard) {
        self.touchBar = touchBar
        self.defaults = defaults
        if defaults.object(forKey: Self.enabledDefaultsKey) == nil {
            isEnabled = true
            defaults.set(true, forKey: Self.enabledDefaultsKey)
        } else {
            isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        }
        super.init()
    }

    func start() {
        guard workspaceObserver == nil else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resetRecovery(); self?.schedulePresentation()
            }
        }

        startVisibilityMonitor()

        if isEnabled {
            schedulePresentation(delay: 0.35)
        } else {
            notifyChange()
        }
    }

    func stop() {
        pendingPresentation?.cancel()
        pendingPresentation = nil
        visibilityCheckWorkItem?.cancel()
        visibilityCheckWorkItem = nil
        visibilityMonitorTimer?.invalidate()
        visibilityMonitorTimer = nil

        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }

        if isPresented {
            _ = PrivateTouchBarAPI.dismiss(touchBar)
        }
        isPresented = false
        isActuallyVisible = false
        visibilityCheckedAt = nil
        removeTrayItem()
    }

    func setEnabled(_ enabled: Bool) {
        resetRecovery()
        guard isEnabled != enabled else {
            if enabled {
                startVisibilityMonitor()
                schedulePresentation()
            }
            return
        }

        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)

        if enabled {
            lastError = nil
            startVisibilityMonitor()
            schedulePresentation()
        } else {
            pendingPresentation?.cancel()
            pendingPresentation = nil
            visibilityCheckWorkItem?.cancel()
            visibilityCheckWorkItem = nil
            visibilityMonitorTimer?.invalidate()
            visibilityMonitorTimer = nil
            if isPresented {
                _ = PrivateTouchBarAPI.dismiss(touchBar)
            }
            isPresented = false
            isActuallyVisible = false
            visibilityCheckedAt = nil
            lastError = nil
            removeTrayItem()
            notifyChange()
        }
    }

    func refresh() {
        resetRecovery()
        schedulePresentation(delay: 0)
    }

    func replaceTouchBar(_ replacement: NSTouchBar) {
        resetRecovery()
        pendingPresentation?.cancel()
        pendingPresentation = nil
        visibilityCheckWorkItem?.cancel()
        visibilityCheckWorkItem = nil
        if isPresented {
            _ = PrivateTouchBarAPI.dismiss(touchBar)
        }
        touchBar = replacement
        isPresented = false
        isActuallyVisible = false
        visibilityCheckedAt = nil
        lastError = nil

        if isEnabled {
            schedulePresentation(delay: 0)
        } else {
            notifyChange()
        }
    }

    @objc private func presentFromTray() {
        resetRecovery()
        schedulePresentation(delay: 0)
    }

    private func schedulePresentation(delay: TimeInterval = 0.12) {
        guard isEnabled, !recovery.exhausted else { return }
        let delay = max(delay, recovery.nextAttempt - ProcessInfo.processInfo.systemUptime)
        pendingPresentation?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.presentNow()
            }
        }
        pendingPresentation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func presentNow() {
        pendingPresentation = nil
        guard isEnabled else { return }

        guard isSupported else {
            isPresented = false
            isActuallyVisible = false
            visibilityCheckedAt = Date()
            lastError = "当前 macOS 不提供实验性系统模态 Touch Bar 接口"
            globalTouchBarLogger.error("Private system modal Touch Bar selector is unavailable")
            recordFailure()
            notifyChange()
            return
        }

        // Re-presenting an already visible system-modal bar can detach its
        // later items when another app becomes active. Keep the existing host.
        if isPresented && touchBar.isVisible {
            isActuallyVisible = true
            visibilityCheckedAt = Date()
            recovered()
            notifyChange()
            return
        }
        if isPresented {
            _ = PrivateTouchBarAPI.dismiss(touchBar)
            isPresented = false
        }

        installTrayItemIfNeeded()
        guard PrivateTouchBarAPI.present(
            touchBar,
            trayItemIdentifier: Self.trayItemIdentifier
        ) else {
            isPresented = false
            isActuallyVisible = false
            visibilityCheckedAt = Date()
            lastError = "调用系统模态 Touch Bar 接口失败"
            globalTouchBarLogger.error("Unable to present the global Touch Bar")
            recordFailure()
            notifyChange()
            return
        }

        isPresented = true
        isActuallyVisible = false
        visibilityCheckedAt = nil
        lastError = nil
        scheduleVisibilityCheck()
        globalTouchBarLogger.notice("Experimental global Touch Bar presented")
        notifyChange()
    }

    private func scheduleVisibilityCheck() {
        visibilityCheckWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkActualVisibility()
            }
        }
        visibilityCheckWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.35,
            execute: workItem
        )
    }

    private func checkActualVisibility() {
        visibilityCheckWorkItem = nil
        guard isEnabled, isPresented else { return }

        isActuallyVisible = touchBar.isVisible
        visibilityCheckedAt = Date()
        if !isActuallyVisible {
            globalTouchBarLogger.warning(
                "System modal Touch Bar call succeeded but visibility is not confirmed"
            )
            isPresented = false
            _ = PrivateTouchBarAPI.dismiss(touchBar)
            recordFailure()
        } else { recovered() }
        notifyChange()
    }

    private func startVisibilityMonitor() {
        visibilityMonitorTimer?.invalidate()
        visibilityMonitorTimer = nil
        guard isEnabled else { return }

        let timer = Timer(
            timeInterval: 5,
            target: self,
            selector: #selector(handleVisibilityMonitor),
            userInfo: nil,
            repeats: true
        )
        visibilityMonitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleVisibilityMonitor() {
        guard isEnabled, isSupported else { return }

        if !isPresented {
            schedulePresentation(delay: 0.05)
            return
        }

        checkActualVisibility()
    }

    private func installTrayItemIfNeeded() {
        guard trayItem == nil else {
            PrivateTouchBarAPI.setControlStripPresence(
                for: Self.trayItemIdentifier,
                visible: true
            )
            return
        }

        let item = NSCustomTouchBarItem(identifier: Self.trayItemIdentifier)
        let button: NSButton
        if let image = NSImage(
            systemSymbolName: "rectangle.split.3x1",
                accessibilityDescription: "GoodTouchBar"
        ) {
            button = NSButton(
                image: image,
                target: self,
                action: #selector(presentFromTray)
            )
        } else {
            button = NSButton(
                title: "TB",
                target: self,
                action: #selector(presentFromTray)
            )
        }
        item.view = button
        item.customizationLabel = "GoodTouchBar"

        guard PrivateTouchBarAPI.addSystemTrayItem(item) else { return }
        trayItem = item
        PrivateTouchBarAPI.setControlStripPresence(
            for: Self.trayItemIdentifier,
            visible: true
        )
    }

    private func removeTrayItem() {
        guard let trayItem else { return }
        PrivateTouchBarAPI.setControlStripPresence(
            for: Self.trayItemIdentifier,
            visible: false
        )
        _ = PrivateTouchBarAPI.removeSystemTrayItem(trayItem)
        self.trayItem = nil
    }

    private func notifyChange() {
        onChange?()
    }
}

private enum PrivateTouchBarAPI {
    private static let presentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:systemTrayItemIdentifier:"
    )
    private static let dismissSelector = NSSelectorFromString(
        "dismissSystemModalTouchBar:"
    )
    private static let addTraySelector = NSSelectorFromString("addSystemTrayItem:")
    private static let removeTraySelector = NSSelectorFromString("removeSystemTrayItem:")
    private static let dfrFrameworkPath =
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"

    static var supportsSystemModalPresentation: Bool {
        class_getClassMethod(NSTouchBar.self, presentSelector) != nil
            && class_getClassMethod(NSTouchBar.self, dismissSelector) != nil
    }

    static func present(
        _ touchBar: NSTouchBar,
        trayItemIdentifier: NSTouchBarItem.Identifier
    ) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, presentSelector) else {
            return false
        }

        typealias Function = @convention(c) (
            AnyClass,
            Selector,
            NSTouchBar,
            NSString?
        ) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(
            NSTouchBar.self,
            presentSelector,
            touchBar,
            trayItemIdentifier.rawValue as NSString
        )
        return true
    }

    static func dismiss(_ touchBar: NSTouchBar) -> Bool {
        guard let method = class_getClassMethod(NSTouchBar.self, dismissSelector) else {
            return false
        }

        typealias Function = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBar.self, dismissSelector, touchBar)
        return true
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        invokeTrayMethod(addTraySelector, item: item)
    }

    static func removeSystemTrayItem(_ item: NSTouchBarItem) -> Bool {
        invokeTrayMethod(removeTraySelector, item: item)
    }

    static func setControlStripPresence(
        for identifier: NSTouchBarItem.Identifier,
        visible: Bool
    ) {
        guard let handle = dlopen(dfrFrameworkPath, RTLD_NOW | RTLD_LOCAL) else { return }
        defer { dlclose(handle) }
        guard let symbol = dlsym(
            handle,
            "DFRElementSetControlStripPresenceForIdentifier"
        ) else {
            return
        }

        typealias Function = @convention(c) (NSString, Bool) -> Void
        let function = unsafeBitCast(symbol, to: Function.self)
        function(identifier.rawValue as NSString, visible)
    }

    private static func invokeTrayMethod(
        _ selector: Selector,
        item: NSTouchBarItem
    ) -> Bool {
        guard let method = class_getClassMethod(NSTouchBarItem.self, selector) else {
            return false
        }

        typealias Function = @convention(c) (
            AnyClass,
            Selector,
            NSTouchBarItem
        ) -> Void
        let function = unsafeBitCast(method_getImplementation(method), to: Function.self)
        function(NSTouchBarItem.self, selector, item)
        return true
    }
}
