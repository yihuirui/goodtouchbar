import AppKit
import CryptoKit
import Darwin
import FanControlCore
import FanHardware
import SystemMonitoring

@MainActor
protocol FanControlTransport: AnyObject {
    var onDisconnect: (() -> Void)? { get set }
    func send(_ data: Data, completion: @escaping (Result<Data, Error>) -> Void)
    func invalidate()
}

@MainActor
final class XPCFanControlTransport: FanControlTransport {
    var onDisconnect: (() -> Void)?
    private var connection: NSXPCConnection?

    func send(_ data: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        guard GoodTouchBarDeviceCapabilities.current.canUseIntelFanHelper else {
            completion(.failure(NSError(domain: "FanControl", code: 78, userInfo: [NSLocalizedDescriptionKey: "当前运行环境未确认 Intel 原生主机；拒绝连接风扇辅助服务"])))
            return
        }
        let connection: NSXPCConnection
        if let existing = self.connection { connection = existing }
        else {
            connection = NSXPCConnection(machServiceName: "io.github.yihuirui.goodtouchbar.fan-helper", options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: GoodTouchFanHelperProtocol.self)
            connection.invalidationHandler = { [weak self, weak connection] in
                Task { @MainActor in
                    guard let self, let connection, self.connection === connection else { return }
                    self.connection = nil; self.onDisconnect?()
                }
            }
            connection.interruptionHandler = { [weak self, weak connection] in
                Task { @MainActor in
                    guard let self, let connection, self.connection === connection else { return }
                    self.invalidate(); self.onDisconnect?()
                }
            }
            self.connection = connection; connection.resume()
        }
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            Task { @MainActor in completion(.failure(error)) }
        }) as? GoodTouchFanHelperProtocol else {
            completion(.failure(NSError(domain: "FanControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "辅助服务暂不可用"])))
            return
        }
        proxy.handle(data) { response in Task { @MainActor in completion(.success(response)) } }
    }

    func invalidate() {
        let connection = self.connection; self.connection = nil
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil; connection?.invalidate()
    }
}

@MainActor
final class FanControlClient: NSObject {
    typealias InstallerRunner = (_ install: Bool, _ bundle: URL, _ uid: uid_t, _ completion: @escaping (Result<Void, Error>) -> Void) -> Void
    private let transport: FanControlTransport
    private let installer: InstallerRunner
    private let runningControllers: () -> [String]
    let fanControlAvailable: Bool
    private let runtimeCapabilities: GoodTouchBarDeviceCapabilities
    private let clock: () -> Double
    private let log: MonitorEventLog
    private var connectionFailureLogged = false
    private var temperatureWarningLogged = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var requestInFlight: String?
    private var requestTimeout: DispatchWorkItem?
    private var ownedLease: String?
    private var pendingQuickAutomatic: Bool?
    var quickModePending: Bool { pendingQuickAutomatic != nil }
    private var nextHeartbeat: Double = 0
    private var nextPoll: Double = 0
    var windowVisible = false
    var quickControlsVisible = false
    private let presetDefaults: UserDefaults?
    private(set) var savedFixedTargets: [Int: Double] = [:]
    private var disconnects = 0
    private(set) var helperUpdateRequired = false
    private let checksInstalledHelper: Bool
    private var connectionNotice = "辅助服务尚未连接"
    private var notice: (text: String, until: Double)?
    private var sleeping = false
    private var operationGeneration: UInt64 = 0
    private(set) var status: FanControlStatus?
    private(set) var connected = false
    private(set) var busy = false
    private(set) var installationBusy = false
    private(set) var lastReplyUptime: Double?
    var onChange: (() -> Void)?

    init(transport: FanControlTransport? = nil, installer: InstallerRunner? = nil,
         runningControllers: (() -> [String])? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, eventLog: MonitorEventLog? = nil, presetDefaults: UserDefaults? = nil,
         capabilities: GoodTouchBarDeviceCapabilities = .current) {
        self.runtimeCapabilities = capabilities
        // Injected transports and installers are deterministic test doubles; they
        // never reach the privileged production helper.
        self.fanControlAvailable = capabilities.canUseIntelFanHelper
        self.presetDefaults = presetDefaults ?? (transport == nil ? .standard : nil)
        if let stored = self.presetDefaults?.dictionary(forKey: "fanConfirmedFixedTargets") {
            for (key, value) in stored { if let id = Int(key), id >= 0, id < 10, let rpm = value as? Double, rpm.isFinite, rpm > 0 { savedFixedTargets[id] = rpm } }
        }
        self.checksInstalledHelper = transport == nil
        self.transport = transport ?? XPCFanControlTransport()
        self.installer = installer ?? Self.runAuthorizedInstaller
        self.runningControllers = runningControllers ?? Self.knownRunningControllers
        self.clock = clock
        self.log = eventLog ?? MonitorEventLog(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar/fan-client-events.jsonl"))
        super.init()
        self.transport.onDisconnect = { [weak self] in self?.connectionLost() }
    }

    var isInstalled: Bool {
        guard fanControlAvailable else { return false }
        return FileManager.default.isExecutableFile(atPath: "/Library/PrivilegedHelperTools/io.github.yihuirui.goodtouchbar.fan-helper")
    }
    var hasControl: Bool { ownedLease != nil && connected && status?.phase == .controlling }
    var statusFresh: Bool { connected && lastReplyUptime.map { clock() - $0 >= 0 && clock() - $0 < 4 } == true }
    var leaseRemaining: Int? { remaining(status?.leaseExpiresAt, maximum: 15) }
    var boostRemaining: Int? { remaining(status?.boostExpiresAt, maximum: 302) }
    private func remaining(_ deadline: Double?, maximum: Double) -> Int? {
        guard statusFresh, let deadline, deadline.isFinite else { return nil }
        let difference = deadline - clock()
        guard difference.isFinite, difference >= -1, difference <= maximum else { return nil }
        return max(0, Int(ceil(difference)))
    }
    var conflictingControllers: [String] { runningControllers() }
    var message: String {
        guard fanControlAvailable else { return "风扇由 macOS 自动管理（只读）；未加载 Intel 辅助服务" }
        if installationBusy { return "正在等待系统授权或处理辅助服务…" }
        if statusFresh, status?.phase == .recoveryFailed { return "恢复系统自动失败，请检查日志和风扇状态" }
        if let notice, clock() < notice.until, statusFresh || lastReplyUptime == nil { return notice.text }
        guard statusFresh, let status else { return helperUpdateRequired ? "辅助服务版本较旧，请点安装／更新辅助服务" : connectionNotice }
        switch status.phase {
        case .automatic:
            return status.fans.isEmpty ? "辅助服务已连接，正在读取风扇" : status.fans.allSatisfy { $0.automatic == true } ? "风扇由系统自动控制" : "本应用未接管风扇；当前模式见下方"
        case .controlling: return status.boostExpiresAt == nil ? "固定转速运行中" : "限时强力散热运行中"
        case .recovering: return "正在恢复系统自动控制"
        case .recoveryFailed: return "恢复系统自动失败，请检查日志和风扇状态"
        }
    }

    func start() {
        guard fanControlAvailable else { connectionNotice = runtimeCapabilities.fanCapabilityReason; onChange?(); return }
        guard timer == nil else { return }
        checkHelperVersion()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.timer != nil else { return }; self.tick() }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self, self.timer != nil else { return }; self.prepareForSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timer != nil else { return }; self.sleeping = false; self.ownedLease = nil
                self.connectionLost(); self.nextPoll = 0; self.tick()
            }
        })
        log.record("fan_client_started"); tick()
    }

    func stop(release: Bool = true) {
        let wasRunning = timer != nil
        timer?.invalidate(); timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        operationGeneration &+= 1
        if release, let lease = ownedLease, let data = try? JSONEncoder().encode(FanControlRequest(action: .release, leaseID: lease)) {
            // Disconnect also causes Helper to release this connection's lease.
            transport.send(data) { _ in }
        }
        requestTimeout?.cancel(); requestTimeout = nil; requestInFlight = nil
        pendingQuickAutomatic = nil
        ownedLease = nil; connected = false; busy = false; transport.invalidate()
        if wasRunning { log.record("fan_client_stopped") }
    }

    func refresh() {
        guard fanControlAvailable else { return }
        guard !installationBusy, !sleeping, !busy else { return }
        nextPoll = clock() + (windowVisible || quickControlsVisible || ownedLease != nil ? 1 : 10); send(FanControlRequest(action: .status))
    }

    func applyFixed(targets: [Int: Double]) {
        guard fanControlAvailable else { setNotice("此运行环境仅支持读取风扇状态，不能写入转速"); return }
        guard canBeginControl() else { return }
        guard !targets.isEmpty, targets.count <= 10, targets.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            setNotice("请输入有效的风扇转速"); return
        }
        send(FanControlRequest(action: .fixed, targets: targets, leaseID: ownedLease))
    }

    var canReuseFixedTargets: Bool {
        guard statusFresh, let fans = status?.fans, !fans.isEmpty, Set(fans.map(\.id)) == Set(savedFixedTargets.keys) else { return false }
        return fans.allSatisfy { fan in
            guard let rpm = savedFixedTargets[fan.id], let low = fan.minimumRPM, let high = fan.maximumRPM else { return false }
            return rpm.isFinite && low.isFinite && high.isFinite && rpm.rounded() == rpm && rpm >= low && rpm <= high
        }
    }
    func applySavedFixed() {
        guard canReuseFixedTargets else { setNotice("请先在风扇窗口设置并应用固定转速"); return }
        applyFixed(targets: savedFixedTargets)
    }

    /// A single explicit click owns one pending intent; polling never cancels it.
    func toggleFixedMode() {
        guard fanControlAvailable else { setNotice("此运行环境仅支持读取风扇状态，不能写入转速"); return }
        guard !installationBusy, !sleeping, pendingQuickAutomatic == nil else { return }
        pendingQuickAutomatic = hasControl || status?.phase == .recoveryFailed
        if busy { onChange?(); return }
        if !statusFresh { refresh(); return }
        performPendingQuickMode()
    }
    private func performPendingQuickMode() {
        guard !busy, let automatic = pendingQuickAutomatic else { return }
        pendingQuickAutomatic = nil
        guard connected, statusFresh, !installationBusy, !sleeping else { setNotice("风扇状态暂不可用，请连接辅助服务后重试"); return }
        if automatic { restoreAutomatic(); return }
        guard status?.phase == .automatic else { setNotice("风扇正在由其他控制会话管理，请先恢复自动"); return }
        if !savedFixedTargets.isEmpty {
            guard canReuseFixedTargets else { setNotice("保存转速与当前风扇范围不符，请在调速窗口更新"); return }
            applySavedFixed(); return
        }
        guard let fans = status?.fans, !fans.isEmpty else { setNotice("没有有效风扇读数"); return }
        var targets: [Int:Double] = [:]
        for fan in fans {
            guard fan.automatic == true, let actual = fan.actualRPM, actual.isFinite, actual > 0,
                  let low = fan.minimumRPM, let high = fan.maximumRPM, low.isFinite, high.isFinite, low > 0, high >= low else { setNotice("风扇范围或当前转速无效，无法切换固定模式"); return }
            targets[fan.id] = min(high.rounded(.down),max(low.rounded(.up),actual.rounded()))
        }
        applyFixed(targets:targets)
    }

    func boost() {
        guard fanControlAvailable else { setNotice("此运行环境仅支持读取风扇状态，不能写入转速"); return }
        guard canBeginControl() else { return }
        send(FanControlRequest(action: .boost, leaseID: ownedLease))
    }

    func restoreAutomatic() {
        guard fanControlAvailable else { return }
        guard !installationBusy, !sleeping, !busy else { return }
        send(FanControlRequest(action: .automatic, leaseID: ownedLease))
    }

    func install() {
        guard fanControlAvailable else { setNotice("未确认 Intel 原生环境，禁止安装 Intel 辅助服务"); return }
        runInstallation(install: true)
    }
    func uninstall() {
        guard fanControlAvailable else { setNotice("未确认 Intel 原生环境，禁止操作 Intel 辅助服务"); return }
        runInstallation(install: false)
    }

    private func checkHelperVersion() {
        guard checksInstalledHelper else { return }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/io.github.yihuirui.goodtouchbar.fan-helper")
        let installed = URL(fileURLWithPath:"/Library/PrivilegedHelperTools/io.github.yihuirui.goodtouchbar.fan-helper")
        let gen = operationGeneration
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let bundledHash = (try? Data(contentsOf:bundled)).map { SHA256.hash(data:$0) }
            let installedHash = (try? Data(contentsOf:installed)).map { SHA256.hash(data:$0) }
            let mismatch = bundledHash != nil && installedHash != nil && bundledHash != installedHash
            DispatchQueue.main.async {
                guard let self, self.operationGeneration == gen else { return }
                self.helperUpdateRequired = mismatch; self.onChange?()
            }
        }
    }
    private func canBeginControl() -> Bool {
        guard !helperUpdateRequired else { setNotice("辅助服务版本较旧，请点安装／更新辅助服务"); return false }
        guard !installationBusy, !sleeping, !busy else { setNotice("请等待当前操作完成"); return false }
        guard statusFresh else { setNotice("请先连接辅助服务并读取风扇状态"); refresh(); return false }
        let others = runningControllers()
        guard others.isEmpty else { setNotice("请先在 " + others.joined(separator: "、") + " 中恢复自动并退出，再由本应用接管"); return false }
        return true
    }

    func tick() {
        guard fanControlAvailable else { return }
        guard !installationBusy, !sleeping else { onChange?(); return }
        let now = clock()
        if !busy {
            if let ownedLease, now >= nextHeartbeat {
                nextHeartbeat = now + 2
                send(FanControlRequest(action: .heartbeat, leaseID: ownedLease))
            } else if now >= nextPoll { nextPoll = now + (windowVisible || quickControlsVisible || ownedLease != nil ? 1 : 10); send(FanControlRequest(action: .status)) }
        }
        onChange?()
    }

    private func prepareForSleep() {
        sleeping = true
        if let lease = ownedLease, let data = try? JSONEncoder().encode(FanControlRequest(action: .sleep, leaseID: lease)) {
            transport.send(data) { _ in }
        }
        connectionLost(); onChange?()
    }

    private func send(_ request: FanControlRequest) {
        guard fanControlAvailable else { setNotice("未确认 Intel 原生环境，风扇操作已禁用"); return }
        guard !busy, let data = try? JSONEncoder().encode(request) else { return }
        if ![.status, .heartbeat].contains(request.action) { log.record("fan_control_requested", code: request.action.rawValue, requestID: request.requestID) }
        busy = true; requestInFlight = request.requestID; onChange?()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.requestInFlight == request.requestID else { return }
            self.connectionLost(); self.onChange?()
        }
        requestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
        transport.send(data) { [weak self] result in
            guard let self, self.requestInFlight == request.requestID else { return }
            self.requestTimeout?.cancel(); self.requestTimeout = nil; self.requestInFlight = nil; self.busy = false
            switch result {
            case .failure:
                self.connectionLost()
            case .success(let data):
                guard data.count <= 65_536, let reply = try? JSONDecoder().decode(FanControlReply.self, from: data), reply.requestID == request.requestID, reply.code.utf8.count <= 128, reply.status.fans.count <= 10, reply.status.targets.count <= 10 else {
                    self.connectionLost(); self.setNotice("辅助服务响应无效，正在确认恢复状态"); return
                }
                if !self.connected {
                    self.log.record("fan_service_connected"); self.connectionFailureLogged = false
                    if self.notice?.text == "辅助服务已安装，正在连接…" { self.notice = nil }
                }
                self.disconnects = 0
                self.status = reply.status; self.connected = true; self.lastReplyUptime = self.clock()
                let temperatureWarning = reply.status.temperatureWarning != nil
                if temperatureWarning != self.temperatureWarningLogged {
                    self.temperatureWarningLogged = temperatureWarning
                    self.log.record(temperatureWarning ? "fan_temperature_warning" : "fan_temperature_warning_cleared", code:temperatureWarning ? "temperature_high" : "temperature_normal")
                }
                if ![.status, .heartbeat].contains(request.action) { self.log.record(reply.ok ? "fan_control_confirmed" : "fan_control_failed", code: reply.code, requestID: request.requestID) }
                if reply.ok && reply.status.phase == .controlling && reply.status.leaseID != nil && [.fixed, .boost].contains(request.action) {
                    if request.action == .fixed {
                        self.savedFixedTargets = request.targets
                        self.presetDefaults?.set(Dictionary(uniqueKeysWithValues: request.targets.map { (String($0.key), $0.value) }), forKey: "fanConfirmedFixedTargets")
                    }
                    self.ownedLease = reply.status.leaseID; self.nextHeartbeat = self.clock() + 2; self.nextPoll = self.clock() + 1
                } else if reply.ok && [.automatic, .release, .sleep].contains(request.action) { self.ownedLease = nil }
                if reply.status.phase != .controlling || (self.ownedLease != nil && reply.status.leaseID != self.ownedLease) { self.ownedLease = nil }
                if !reply.ok {
                    let diagnostic = reply.status.hardwareDiagnostic.map { " · " + String($0.prefix(160)) } ?? ""
                    self.setNotice(Self.message(for: reply.code) + diagnostic + ([.status, .heartbeat].contains(request.action) ? "" : " · 编号 " + String(request.requestID.prefix(8))))
                }
                else if ![.status, .heartbeat].contains(request.action) {
                    let allAutomatic = !reply.status.fans.isEmpty && reply.status.fans.allSatisfy { $0.automatic == true }
                    let controlConfirmed = reply.status.phase == .controlling && self.ownedLease != nil
                    let text: String
                    switch request.action {
                    case .automatic: text = allAutomatic ? "已确认恢复系统自动控制" : "本应用已释放控制，当前模式见下方"
                    case .boost: text = controlConfirmed ? "已开启 5 分钟强力散热" : "控制未生效，当前状态见下方"
                    case .fixed: text = controlConfirmed ? "已应用固定转速" : "控制未生效，当前状态见下方"
                    default: text = "操作完成"
                    }
                    self.setNotice(text)
                }
            }
            self.onChange?()
            self.performPendingQuickMode()
        }
    }

    private func connectionLost() {
        pendingQuickAutomatic = nil
        requestTimeout?.cancel(); requestTimeout = nil; requestInFlight = nil
        if !connectionFailureLogged { log.record("fan_service_disconnected"); connectionFailureLogged = true }
        let hadControl = ownedLease != nil || status?.phase == .controlling || status?.phase == .recovering || status?.phase == .recoveryFailed
        ownedLease = nil; connected = false; busy = false; lastReplyUptime = nil; notice = nil
        connectionNotice = hadControl ? "辅助服务连接中断，正在确认是否恢复自动" : isInstalled ? "辅助服务未连接；升级 App 后请点安装／更新辅助服务" : "请先安装并授权风扇辅助服务"
        disconnects = min(disconnects + 1, 4)
        nextPoll = clock() + min(30, 5 * pow(2, Double(disconnects-1))); transport.invalidate(); onChange?()
    }

    private func setNotice(_ value: String) { notice = (value, clock() + 10); onChange?() }

    private func runInstallation(install: Bool) {
        guard fanControlAvailable else { setNotice("未确认 Intel 原生环境，禁止操作 Intel 辅助服务"); return }
        guard !installationBusy, !busy else { setNotice("请等待当前操作完成"); return }
        pendingQuickAutomatic = nil
        installationBusy = true; operationGeneration &+= 1
        log.record(install ? "fan_install_requested" : "fan_uninstall_requested")
        let generation = operationGeneration
        // Root installer restores and verifies the old session before replacing/removing files.
        requestTimeout?.cancel(); requestInFlight = nil; transport.invalidate()
        ownedLease = nil; connected = false; busy = false; lastReplyUptime = nil; notice = nil; onChange?()
        installer(install, Bundle.main.bundleURL, getuid()) { [weak self] result in
            guard let self, self.operationGeneration == generation else { return }
            self.installationBusy = false
            switch result {
            case .success:
                self.log.record(install ? "fan_install_completed" : "fan_uninstall_completed")
                self.helperUpdateRequired = false; self.checkHelperVersion()
                self.status = nil; self.connectionNotice = install ? "辅助服务已安装，正在连接…" : "辅助服务已卸载"
                self.setNotice(install ? "辅助服务已安装，正在连接…" : "辅助服务已卸载，运行日志已保留")
                self.nextPoll = self.clock() + (install ? 0 : 5)
                if install { self.refresh() }
            case .failure(let error):
                self.log.record(install ? "fan_install_failed" : "fan_uninstall_failed")
                self.setNotice("辅助服务操作未完成：" + String(error.localizedDescription.prefix(220)))
            }
            self.onChange?()
        }
    }

    static func message(for code: String) -> String {
        let messages: [String: String] = [
            "hardware_unavailable": "硬件读取失败，无法确认风扇状态", "lease_not_owned": "当前会话未持有这次控制，不能修改其他会话的风扇",
            "fan_not_owned": "检测到外部手动控制，本应用没有接管这些风扇", "fan_already_controlled": "风扇已被其他控制器接管，请先恢复自动",
            "temperature_unavailable_or_high": "旧辅助服务仍有温度限制，请安装／更新辅助服务", "invalid_target_or_limits": "请输入本机范围内的整数 RPM",
            "fan_limits_unavailable": "无法读取安全转速边界，调速未启用", "ownership_persistence_failed": "无法保存恢复记录，控制未启用或恢复状态待确认",
            "recovery_required": "恢复自动尚未确认，暂不能重新接管", "write_readback_failed": "调速未获读回确认，已开始恢复自动",
            "hardware_write_failed": "硬件写入失败，已开始恢复自动", "restore_not_confirmed": "恢复自动未获读回确认，请检查风扇状态",
            "request_id_reused": "控制请求标识冲突，请重新操作", "request_capacity_reached": "本次服务控制请求已达上限，请恢复自动后更新服务",
            "ok": "操作完成", "busy": "其他控制操作正在进行", "owned_by_other_client": "风扇已由其他会话接管",
            "client_mismatch": "本会话没有控制权限", "lease_not_active": "本次控制已结束", "lease_expired": "控制连接超时，已开始恢复自动",
            "invalid_request": "控制请求无效", "invalid_targets": "转速设置无效", "invalid_fan": "所选风扇不可用",
            "target_out_of_range": "转速超出本机风扇可用范围", "unsupported_hardware": "本机风扇尚不支持安全调速",
            "temperature_high": "温度较高，建议提高转速或恢复自动", "temperature_unsafe": "旧辅助服务温度限制，请安装／更新辅助服务",
            "temperature_unavailable": "温度数据不可用，无法启用固定转速", "sensor_unavailable": "传感器暂不可用，已开始恢复自动",
            "manual_conflict": "检测到其他控制器的手动设置，请先恢复自动", "already_manual": "风扇当前由其他控制器手动控制",
            "readback_failed": "写入未获读回确认，已开始恢复自动", "write_failed": "调速写入失败，已开始恢复自动",
            "restore_failed": "恢复系统自动失败，请检查日志和风扇状态", "recovery_failed": "恢复系统自动失败，请检查日志和风扇状态",
            "recovery_pending": "正在恢复系统自动，暂不能重新接管", "persistence_failed": "无法保存恢复记录，控制未启用",
            "protocol_mismatch": "辅助服务版本不匹配，请重新安装", "unauthorized": "当前程序未获辅助服务授权，请重新安装"
        ]
        return messages[code] ?? "操作未完成（\(code)），请查看风扇状态和日志"
    }

    private static func knownRunningControllers() -> [String] {
        return NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier.flatMap(knownControllerName(for:)) }
            .sorted()
    }

    static func knownControllerName(for bundleIdentifier: String) -> String? {
        let names = [
            "com.besttouchtool.app": "BestTouchTool",
            "eu.exelban.Stats": "Stats",
            "com.crystalidea.macsfancontrol": "Macs Fan Control",
            "com.eidac.smcFanControl": "smcFanControl",
        ]
        return names[bundleIdentifier]
    }

    private static func runAuthorizedInstaller(install: Bool, bundle: URL, uid: uid_t, completion: @escaping (Result<Void, Error>) -> Void) {
        let script = bundle.appendingPathComponent("Contents/Resources/FanControl/" + (install ? "install-helper.sh" : "uninstall-helper.sh"))
        guard FileManager.default.fileExists(atPath: script.path) else {
            completion(.failure(NSError(domain: "FanInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "安装脚本缺失，请使用完整的新安装包"])))
            return
        }
        let command = "/bin/sh " + shellQuote(script.path) + " " + shellQuote(bundle.path) + " " + shellQuote(String(uid))
        let appleScript = "do shell script " + appleScriptLiteral(command) + " with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-e", appleScript]
            process.standardOutput = output; process.standardError = errors
            do {
                try process.run()
                let group = DispatchGroup(); let box = InstallerOutput()
                group.enter(); DispatchQueue.global(qos: .utility).async { box.consume(output.fileHandleForReading, isError: false); group.leave() }
                group.enter(); DispatchQueue.global(qos: .utility).async { box.consume(errors.fileHandleForReading, isError: true); group.leave() }
                process.waitUntilExit(); group.wait()
                let result: Result<Void, Error> = process.terminationStatus == 0 ? .success(()) : .failure(NSError(domain: "FanInstaller", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: box.errorText]))
                try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
                DispatchQueue.main.async { completion(result) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
}

private final class InstallerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data(), error = Data()
    func consume(_ handle: FileHandle, isError: Bool) {
        var prefix = Data()
        do {
            while let data = try handle.read(upToCount: 4096), !data.isEmpty {
                if prefix.count < 16_384 { prefix.append(data.prefix(16_384 - prefix.count)) }
            }
        } catch { /* Process exit can close a pipe concurrently. */ }
        lock.lock(); if isError { error = prefix } else { output = prefix }; lock.unlock()
    }
    var errorText: String {
        lock.lock(); defer { lock.unlock() }
        let value = String(data: error.isEmpty ? output : error, encoding: .utf8) ?? "系统授权已取消或安装失败"
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
    }
}
