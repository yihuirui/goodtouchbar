import Foundation
import Darwin
import SystemMonitoring

/// Shares the original helper's lock/status directory: never start two retry workers.
@MainActor
final class WorkBuddyActivityMonitor: NSObject {
    private let directory: URL
    private var timer: Timer?
    private var commandRunning = false
    private struct CommandNotice {
        let snapshot: WorkBuddyActivitySnapshot
        let expiresAt: Date
    }
    private var commandNotice: CommandNotice?
    var commandInFlight: Bool { commandRunning }

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/GoodTouchBar/WorkBuddyRetry")) {
        self.directory = directory
        super.init()
    }
    private(set) var snapshot = WorkBuddyActivitySnapshot(
        state: .idle, title: "未监控", detail: "点击“开始监控与自动重试”并确认后即可启动", updatedAt: nil)
    var onChange: (() -> Void)?
    var onRestartRequired: ((String) -> Void)?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    // Stopping UI polling does not silently terminate a separately started helper.
    func stop() { timer?.invalidate(); timer = nil }

    func refresh(now: Date = Date()) {
        if let notice = commandNotice, now >= notice.expiresAt { commandNotice = nil }
        let status = readStatus(now: now)
        let notice = commandNotice?.snapshot
        // A valid, live worker always owns the title; operation feedback is detail only.
        if status.live {
            let detail = status.snapshot.detail + (notice.map { " · 操作提示：\($0.detail)" } ?? "")
            update(.init(state: status.snapshot.state, title: status.snapshot.title,
                         detail: detail, updatedAt: status.snapshot.updatedAt))
        } else {
            update(notice ?? status.snapshot)
        }
    }

    private func readStatus(now: Date) -> (snapshot: WorkBuddyActivitySnapshot, live: Bool) {
        let file = directory.appendingPathComponent("background-status.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return (.init(state: .idle, title: "未监控",
                          detail: "点击“开始监控”",
                          updatedAt: nil), false)
        }
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (.init(state: .stale, title: "读取异常",
                          detail: "无法读取重试监控状态，暂不能确认聊天是否进行中", updatedAt: nil), false)
        }
        let date = (value["updatedAt"] as? String).flatMap { text -> Date? in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        let pid = (value["pid"] as? NSNumber)?.int32Value ?? 0
        let lockPID = (try? String(contentsOf: directory.appendingPathComponent("background.lock"), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let alive = pid > 0 && lockPID == pid && (Darwin.kill(pid, 0) == 0 || errno == EPERM)
        let age = date.map { now.timeIntervalSince($0) }
        let live = value["running"] as? Bool == true && alive && age.map { $0 >= -5 && $0 < 30 } == true
        // 后台通道是独立 node 进程，换 App 版本时旧进程不会自己退出，会一直占着
        // background.lock 写旧构建号的状态。这里把"通道来自旧版本"直接暴露出来，
        // 否则升级后看到的一直是旧行为，日志里也一直写旧版本号。
        let workerBuild = (value["build"] as? NSNumber)?.intValue ?? 0
        if live, workerBuild > 0, workerBuild != AppBuild.current {
            return (.init(state: .stale, title: "通道需更新",
                          detail: "监控通道来自 build \(workerBuild)，与当前 build \(AppBuild.current) 不一致，请点“更新会话与自动重试”并确认",
                          updatedAt: date), false)
        }
        return (Self.decode(value, date: date, alive: alive, now: now), live)
    }

    func beginCommand(_ command: String, now: Date = Date()) {
        commandRunning = true
        let labels = ["start": "正在开始监控", "update": "正在更新监控会话", "stop": "正在停止监控"]
        commandNotice = .init(snapshot: .init(state: .waiting, title: "操作中",
            detail: labels[command] ?? "正在操作", updatedAt: now),
            expiresAt: now.addingTimeInterval(command == "stop" ? 20 : 75))
        refresh(now: now)
    }

    func completeCommand(_ command: String, succeeded: Bool, message: String?, now: Date = Date()) {
        commandRunning = false
        if !succeeded {
            commandNotice = .init(snapshot: .init(state: .error, title: "操作失败",
                detail: message ?? "命令未完成，请检查后台通道", updatedAt: now),
                expiresAt: now.addingTimeInterval(10))
        } else {
            commandNotice = nil
        }
        refresh(now: now)
    }

    static func decode(_ value: [String: Any], date: Date?, alive: Bool, now: Date = Date()) -> WorkBuddyActivitySnapshot {
        let phase = value["phase"] as? String ?? "状态未知"
        let pausedReason = value["retryPausedReason"] as? String
        let detail = pausedReason == nil ? "" : "自动重试已暂停，点开始监控可重新开始"
        func result(_ state: WorkBuddyActivitySnapshot.State, _ title: String) -> WorkBuddyActivitySnapshot {
            .init(state: state, title: title, detail: detail, updatedAt: date)
        }
        guard value["running"] as? Bool == true, alive else {
            let hint = value["error"] as? Bool == true ? "点更新监控会话可重新绑定" : ""
            return .init(state: value["error"] as? Bool == true ? .error : .idle,
                         title: "监控停止", detail: hint, updatedAt: date)
        }
        guard let date, (-5..<30).contains(now.timeIntervalSince(date)) else { return result(.stale, "连接异常") }
        if phase == "等待后台重试", let seconds = value["seconds"] as? Int {
            let remaining = max(0, seconds - Int(max(0, now.timeIntervalSince(date))))
            return result(.waiting, "重试\(remaining)s")
        }
        if phase == "自动重试已暂停", value["generating"] as? Bool != true { return result(.waiting, "重试暂停") }
        if phase == "模型报错，需人工处理" { return result(.error, "需处理") }
        if phase.contains("确认模型错误") || phase.contains("确认繁忙") { return result(.waiting, "模型拥堵") }
        if phase.contains("确认同一聊天") || phase.contains("已确认同一聊天") { return result(.running, "重试中") }
        if value["generating"] as? Bool == true { return result(.running, "进行中") }
        if phase == "已完成" { return result(.completed, "已完成") }
        return result(.idle, "待命")
    }

    func control(_ command: String, allowRestart: Bool = false) {
        guard !commandRunning, ["start", "update", "stop"].contains(command) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/usr/local/bin/node", "/opt/homebrew/bin/node", "\(home)/.local/bin/node"]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let resources = Bundle.main.resourceURL else {
            completeCommand(command, succeeded: false,
                            message: "需要 Node.js 22+（/usr/local/bin/node、/opt/homebrew/bin/node 或 ~/.local/bin/node）")
            return
        }
        let script = resources.appendingPathComponent("WorkBuddyRetry/background-monitor.mjs")
        beginCommand(command)
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [script.path, command] + (allowRestart ? ["--allow-restart"] : [])
            // 让 node 侧日志写出与 App 一致的构建号，不再各自硬编码。
            var environment = ProcessInfo.processInfo.environment
            environment["WB_RETRY_BUILD"] = String(AppBuild.current)
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var message: String?
            var succeeded = false
            var restartRequired = false
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + (command == "stop" ? 20 : 75)) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                succeeded = process.terminationReason == .exit && process.terminationStatus == 0
                if !succeeded {
                    let failure = Self.parseCommandFailure(output)
                    restartRequired = failure.restartRequired
                    message = failure.message
                }
            } catch { message = "无法启动重试工具：\(error.localizedDescription)" }
            let finalMessage = message
            let finalSucceeded = succeeded
            let needsRestart = restartRequired
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.completeCommand(command, succeeded: finalSucceeded, message: finalMessage)
                if needsRestart && !allowRestart { self.onRestartRequired?(command) }
            }
        }
    }
    nonisolated static func parseCommandFailure(_ output: String) -> (restartRequired: Bool, message: String) {
        if let data = output.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let restart = value["code"] as? String == "restart_required"
            let message = value["message"] as? String ?? "操作失败，请重试"
            return (restart, String(message.prefix(90)))
        }
        return (false, "操作失败，请检查 Node.js 和运行日志")
    }

    private func update(_ next: WorkBuddyActivitySnapshot) {
        guard next != snapshot else { return }
        snapshot = next; onChange?()
    }
}
