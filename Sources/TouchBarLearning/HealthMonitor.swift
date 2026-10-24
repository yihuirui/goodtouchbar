import AppKit
import Foundation
import os.log

private let healthLogger = Logger(
    subsystem: "io.github.yihuirui.goodtouchbar",
    category: "Health"
)

struct TouchBarRuntimeProbe {
    let windowReady: Bool
    let touchBarEnabled: Bool
    let touchBarInstalled: Bool
    let touchBarItemReady: Bool
    let codexTouchBarItemReady: Bool
    let quotaTouchBarItemReady: Bool
    let workbuddyTouchBarItemReady: Bool
    let tokenTouchBarItemReady: Bool
    let renderCount: Int
    let pomodoroRunning: Bool
    let pomodoroPhase: String
    let pomodoroCompletedToday: Int
    let remainingSeconds: Int
    let codexStatus: String
    let codexUpdatedAt: Date?
    let quotaRemainingPercent: Int?
    let quotaMinimumRemainingPercent: Int?
    let quotaResetAt: Date?
    let workbuddyStatus: String
    let workbuddyUpdatedAt: Date?
    let todayTokens: Int64?
    let todayTokensUpdatedAt: Date?
    let todayTokensStale: Bool
    let touchBarLayoutMode: String
    let touchBarResolvedItemCount: Int
    let touchBarVisibleItemCount: Int
    let touchBarLayoutCheckedAt: Date?
    let globalTouchBarEnabled: Bool
    let globalTouchBarSupported: Bool
    let globalTouchBarPresented: Bool
    let globalTouchBarActuallyVisible: Bool
    let globalTouchBarVisibilityCheckedAt: Date?
    let globalTouchBarLastError: String?
    let lastError: String?
    let betterTouchToolInstalled: Bool
    let betterTouchToolRunning: Bool
    var expectedTouchBarItemCount: Int = 0
    var visibleMetricKeys: [String] = []
    var metricSampledAt: [String: Date] = [:]
    var sensorError: String? = nil
    var fanControlPhase: String? = nil
    var fanControlMessage: String? = nil
    var fanControlConnected: Bool = false
    /// 辅助服务是否已安装到 /Library/PrivilegedHelperTools。没装过就不该报降级。
    var fanControlInstalled: Bool = false
    /// 已安装但客户端签名与服务端策略不一致：必须重装才能恢复控制。
    var fanControlHelperUpdateRequired: Bool = false

    static let empty = TouchBarRuntimeProbe(
        windowReady: false,
        touchBarEnabled: false,
        touchBarInstalled: false,
        touchBarItemReady: false,
        codexTouchBarItemReady: false,
        quotaTouchBarItemReady: false,
        workbuddyTouchBarItemReady: false,
        tokenTouchBarItemReady: false,
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
        touchBarResolvedItemCount: 0,
        touchBarVisibleItemCount: 0,
        touchBarLayoutCheckedAt: nil,
        globalTouchBarEnabled: false,
        globalTouchBarSupported: false,
        globalTouchBarPresented: false,
        globalTouchBarActuallyVisible: false,
        globalTouchBarVisibilityCheckedAt: nil,
        globalTouchBarLastError: nil,
        lastError: "应用窗口尚未创建",
        betterTouchToolInstalled: false,
        betterTouchToolRunning: false
    )
}

struct TouchBarHealthSnapshot: Codable {
    let schemaVersion: Int
    let app: String
    let pid: Int32
    let status: String
    let message: String
    let startedAt: Date
    let updatedAt: Date
    let windowReady: Bool
    let touchBarEnabled: Bool
    let touchBarInstalled: Bool
    let touchBarItemReady: Bool
    let codexTouchBarItemReady: Bool
    let quotaTouchBarItemReady: Bool
    let workbuddyTouchBarItemReady: Bool
    let tokenTouchBarItemReady: Bool
    let renderCount: Int
    let pomodoroRunning: Bool
    let pomodoroPhase: String
    let pomodoroCompletedToday: Int
    let remainingSeconds: Int
    let codexStatus: String
    let codexUpdatedAt: Date?
    let quotaRemainingPercent: Int?
    let quotaMinimumRemainingPercent: Int?
    let quotaResetAt: Date?
    let workbuddyStatus: String
    let workbuddyUpdatedAt: Date?
    let todayTokens: Int64?
    let todayTokensUpdatedAt: Date?
    let todayTokensStale: Bool
    let touchBarLayoutMode: String
    let touchBarResolvedItemCount: Int
    let touchBarVisibleItemCount: Int
    let touchBarLayoutCheckedAt: Date?
    let globalTouchBarEnabled: Bool
    let globalTouchBarSupported: Bool
    let globalTouchBarPresented: Bool
    let globalTouchBarActuallyVisible: Bool
    let globalTouchBarVisibilityCheckedAt: Date?
    let globalTouchBarLastError: String?
    let lastError: String?
    let betterTouchToolInstalled: Bool
    let betterTouchToolRunning: Bool
    let expectedTouchBarItemCount: Int
    let visibleMetricKeys: [String]
    let metricSampledAt: [String: Date]
    let sensorError: String?
    let fanControlPhase: String?
    let fanControlMessage: String?
    let fanControlConnected: Bool
    let fanControlInstalled: Bool
    let fanControlHelperUpdateRequired: Bool
}

@MainActor
final class HealthMonitor: NSObject {
    private let fileManager = FileManager.default
    private let startedAt = Date()
    private var heartbeatTimer: Timer?
    private var probeProvider: (() -> TouchBarRuntimeProbe)?

    private(set) var latestSnapshot: TouchBarHealthSnapshot?
    var onSnapshot: ((TouchBarHealthSnapshot) -> Void)?

    var stateFileURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("GoodTouchBar", isDirectory: true)
            .appendingPathComponent("health.json")
    }

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    func start(provider: @escaping () -> TouchBarRuntimeProbe) {
        probeProvider = provider
        refresh()

        heartbeatTimer?.invalidate()
        let timer = Timer(
            timeInterval: 15,
            target: self,
            selector: #selector(handleHeartbeat),
            userInfo: nil,
            repeats: true
        )
        heartbeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        probeProvider = nil
    }

    @discardableResult
    func refresh() -> TouchBarHealthSnapshot? {
        guard let probeProvider else { return latestSnapshot }

        let snapshot = makeSnapshot(from: probeProvider())
        latestSnapshot = snapshot
        persist(snapshot)
        onSnapshot?(snapshot)
        return snapshot
    }

    func openStateFile() {
        if !fileManager.fileExists(atPath: stateFileURL.path) {
            _ = refresh()
        }
        NSWorkspace.shared.open(stateFileURL)
    }

    @objc private func handleHeartbeat() {
        _ = refresh()
    }

    func makeSnapshot(from probe: TouchBarRuntimeProbe) -> TouchBarHealthSnapshot {
        let status: String
        let message: String

        if let lastError = probe.lastError {
            status = "degraded"
            message = lastError
        } else if probe.fanControlPhase == "recoveryFailed" {
            status = "degraded"
            message = "风扇恢复自动未确认，请检查调速窗口"
        } else if probe.fanControlInstalled && probe.fanControlHelperUpdateRequired {
            // 服务装过，但客户端签名与服务端策略不一致：风扇控制此刻是死的，
            // 不能因为 Touch Bar 正常就报 healthy。
            status = "degraded"
            message = "风扇辅助服务版本不匹配，需重新安装后才能控制风扇"
        } else if probe.fanControlInstalled && !probe.fanControlConnected {
            status = "degraded"
            message = probe.fanControlMessage.map { "风扇辅助服务未连接：\($0)" } ?? "风扇辅助服务未连接"
        } else if probe.touchBarEnabled && probe.globalTouchBarEnabled && !probe.globalTouchBarSupported {
            status = "degraded"
            message = "实验全局 Touch Bar 接口不可用"
        } else if probe.touchBarEnabled, let globalError = probe.globalTouchBarLastError {
            status = "degraded"
            message = globalError
        } else if probe.touchBarEnabled && probe.globalTouchBarEnabled && !probe.globalTouchBarPresented {
            status = "waiting"
            message = "等待实验全局 Touch Bar 呈现"
        } else if probe.touchBarEnabled && probe.globalTouchBarEnabled,
                  probe.globalTouchBarVisibilityCheckedAt != nil,
                  !probe.globalTouchBarActuallyVisible {
            status = "waiting"
            message = "已请求实验全局 Touch Bar，但系统尚未确认可见"
        } else if probe.touchBarEnabled && (!probe.windowReady || !probe.touchBarInstalled) {
            status = "waiting"
            message = "应用窗口或 Touch Bar 尚未就绪"
        } else if probe.touchBarEnabled && (!probe.touchBarItemReady
                    || !probe.codexTouchBarItemReady
                    || !probe.quotaTouchBarItemReady
                    || !probe.workbuddyTouchBarItemReady
                    || !probe.tokenTouchBarItemReady) {
            status = "waiting"
            message = "Touch Bar 已安装，等待已选控件创建"
        } else if probe.touchBarEnabled && probe.touchBarResolvedItemCount != probe.expectedTouchBarItemCount {
            status = "waiting"
            message = "Touch Bar 已选布局尚未完整创建"
        } else if probe.codexStatus == "error" || probe.workbuddyStatus == "error" {
            status = "degraded"
            message = probe.touchBarEnabled
                ? "Touch Bar 已就绪，但有任务报告错误"
                : "菜单栏模式运行中，但有任务报告错误"
        } else if probe.codexStatus == "stale" || probe.workbuddyStatus == "stale" {
            status = "degraded"
            message = probe.touchBarEnabled
                ? "Touch Bar 已就绪，但有状态数据过期"
                : "菜单栏模式运行中，但有状态数据过期"
        } else {
            status = "healthy"
            if !probe.touchBarEnabled {
                let quota = probe.quotaRemainingPercent.map(String.init) ?? "--"
                message = "菜单栏模式 · Touch Bar 已禁用 · ChatGPT \(probe.codexStatus) · WB \(probe.workbuddyStatus) · 额度 \(quota)%"
                return makeSnapshot(
                    from: probe,
                    status: status,
                    message: message
                )
            }
            let displayState = probe.globalTouchBarEnabled
                ? "实验全局模式已呈现"
                : "前台 AppKit 模式"
            let quota = probe.quotaRemainingPercent.map(String.init) ?? "--"
            message = "Touch Bar 已就绪 · \(displayState) · 布局 \(probe.touchBarLayoutMode) \(probe.touchBarVisibleItemCount)/\(probe.touchBarResolvedItemCount) · ChatGPT \(probe.codexStatus) · WB \(probe.workbuddyStatus) · 额度 \(quota)%"
        }

        return makeSnapshot(
            from: probe,
            status: status,
            message: message
        )
    }

    private func makeSnapshot(
        from probe: TouchBarRuntimeProbe,
        status: String,
        message: String
    ) -> TouchBarHealthSnapshot {
        TouchBarHealthSnapshot(
            schemaVersion: 9,
            app: "GoodTouchBar",
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            status: status,
            message: message,
            startedAt: startedAt,
            updatedAt: Date(),
            windowReady: probe.windowReady,
            touchBarEnabled: probe.touchBarEnabled,
            touchBarInstalled: probe.touchBarInstalled,
            touchBarItemReady: probe.touchBarItemReady,
            codexTouchBarItemReady: probe.codexTouchBarItemReady,
            quotaTouchBarItemReady: probe.quotaTouchBarItemReady,
            workbuddyTouchBarItemReady: probe.workbuddyTouchBarItemReady,
            tokenTouchBarItemReady: probe.tokenTouchBarItemReady,
            renderCount: probe.renderCount,
            pomodoroRunning: probe.pomodoroRunning,
            pomodoroPhase: probe.pomodoroPhase,
            pomodoroCompletedToday: probe.pomodoroCompletedToday,
            remainingSeconds: probe.remainingSeconds,
            codexStatus: probe.codexStatus,
            codexUpdatedAt: probe.codexUpdatedAt,
            quotaRemainingPercent: probe.quotaRemainingPercent,
            quotaMinimumRemainingPercent: probe.quotaMinimumRemainingPercent,
            quotaResetAt: probe.quotaResetAt,
            workbuddyStatus: probe.workbuddyStatus,
            workbuddyUpdatedAt: probe.workbuddyUpdatedAt,
            todayTokens: probe.todayTokens,
            todayTokensUpdatedAt: probe.todayTokensUpdatedAt,
            todayTokensStale: probe.todayTokensStale,
            touchBarLayoutMode: probe.touchBarLayoutMode,
            touchBarResolvedItemCount: probe.touchBarResolvedItemCount,
            touchBarVisibleItemCount: probe.touchBarVisibleItemCount,
            touchBarLayoutCheckedAt: probe.touchBarLayoutCheckedAt,
            globalTouchBarEnabled: probe.globalTouchBarEnabled,
            globalTouchBarSupported: probe.globalTouchBarSupported,
            globalTouchBarPresented: probe.globalTouchBarPresented,
            globalTouchBarActuallyVisible: probe.globalTouchBarActuallyVisible,
            globalTouchBarVisibilityCheckedAt: probe.globalTouchBarVisibilityCheckedAt,
            globalTouchBarLastError: probe.globalTouchBarLastError,
            lastError: probe.lastError,
            betterTouchToolInstalled: probe.betterTouchToolInstalled,
            betterTouchToolRunning: probe.betterTouchToolRunning,
            expectedTouchBarItemCount: probe.expectedTouchBarItemCount,
            visibleMetricKeys: probe.visibleMetricKeys,
            metricSampledAt: probe.metricSampledAt,
            sensorError: probe.sensorError,
            fanControlPhase: probe.fanControlPhase,
            fanControlMessage: probe.fanControlMessage,
            fanControlConnected: probe.fanControlConnected,
            fanControlInstalled: probe.fanControlInstalled,
            fanControlHelperUpdateRequired: probe.fanControlHelperUpdateRequired
        )
    }

    private func persist(_ snapshot: TouchBarHealthSnapshot) {
        do {
            let directoryURL = stateFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            healthLogger.error("Unable to persist health snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
