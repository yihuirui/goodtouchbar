import Foundation
import Darwin
@main struct RetryStatusCheck {
    @MainActor static func main() throws {
        let now = Date()
        let value: [String: Any] = ["running":true,"phase":"等待后台重试","seconds":30,"attempts":2]
        let waiting = WorkBuddyActivityMonitor.decode(value, date: now.addingTimeInterval(-4), alive:true, now:now)
        precondition(waiting.title == "重试26s" && waiting.state == .waiting)
        precondition(WorkBuddyActivityMonitor.decode(value,date:now.addingTimeInterval(-31),alive:true,now:now).state == .stale)
        precondition(WorkBuddyActivityMonitor.decode(value,date:now,alive:false,now:now).title == "监控停止")
        let failed: [String: Any] = ["running":false,"phase":"已达本轮 10 次重试上限","error":true]
        precondition(WorkBuddyActivityMonitor.decode(failed,date:now,alive:false).state == .error)
        let manual: [String: Any] = ["running":true,"phase":"模型报错，需人工处理"]
        precondition(WorkBuddyActivityMonitor.decode(manual,date:now,alive:true).state == .error)
        let active: [String: Any] = ["running":true,"phase":"进行中","generating":true]
        precondition(WorkBuddyActivityMonitor.decode(active,date:now,alive:true).title == "进行中")
        let pausedActive: [String: Any] = ["running": true, "phase": "进行中", "generating": true,
            "retryEnabled": false, "retryPausedReason": "已达本轮 10 次重试上限"]
        let pausedSnapshot = WorkBuddyActivityMonitor.decode(pausedActive, date: now, alive: true, now: now)
        precondition(pausedSnapshot.title == "进行中" && pausedSnapshot.detail.contains("自动重试已暂停"))
        let pausedBusy: [String: Any] = ["running": true, "phase": "自动重试已暂停", "generating": false,
            "retryEnabled": false, "retryPausedReason": "已手动暂停自动重试"]
        precondition(WorkBuddyActivityMonitor.decode(pausedBusy, date: now, alive: true, now: now).title == "重试暂停")
        let tenSeconds: [String: Any] = ["running": true, "phase": "等待后台重试", "seconds": 10]
        precondition(WorkBuddyActivityMonitor.decode(tenSeconds, date: now, alive: true, now: now).title == "重试10s")
        let restartFailure = WorkBuddyActivityMonitor.parseCommandFailure("{\"ok\":false,\"code\":\"restart_required\",\"message\":\"需要重新打开 WorkBuddy 后开始监控\"}")
        precondition(restartFailure.restartRequired)
        precondition(!WorkBuddyActivityMonitor.parseCommandFailure("node stack trace").restartRequired)
        precondition(WorkBuddyActivityMonitor.parseCommandFailure("node stack trace").message.count < 50)
        let compact = WorkBuddyActivityMonitor.decode(active, date: now, alive: true, now: now)
        precondition(compact.menuText == "WB AI：进行中")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("background-status.json")
        let lock = directory.appendingPathComponent("background.lock")
        let monitor = WorkBuddyActivityMonitor(directory: directory)
        func save(_ fields: [String: Any], date: Date = now) throws {
            var fields = fields
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            fields["updatedAt"] = formatter.string(from: date)
            fields["pid"] = getpid()
            try JSONSerialization.data(withJSONObject: fields).write(to: file, options: .atomic)
            try String(getpid()).write(to: lock, atomically: true, encoding: .utf8)
        }
        monitor.refresh(now: now)
        precondition(monitor.snapshot.title == "未监控")
        monitor.beginCommand("update", now: now)
        precondition(monitor.snapshot.title == "操作中")
        monitor.completeCommand("update", succeeded: true, message: "ready", now: now)
        precondition(monitor.snapshot.title == "未监控")
        monitor.refresh(now: now.addingTimeInterval(9))
        precondition(monitor.snapshot.title == "未监控")

        // Regression: an update result must never hide a live generating worker.
        try save(active)
        monitor.beginCommand("update", now: now)
        precondition(monitor.snapshot.title == "进行中")
        monitor.completeCommand("update", succeeded: true, message: "ready", now: now)
        precondition(monitor.snapshot.title == "进行中")
        monitor.completeCommand("start", succeeded: false, message: "test failure", now: now)
        precondition(monitor.snapshot.title == "进行中" && monitor.snapshot.detail.contains("test failure"))
        monitor.refresh(now: now.addingTimeInterval(11))
        precondition(monitor.snapshot.title == "进行中" && !monitor.snapshot.detail.contains("test failure"))
        monitor.refresh(now: now.addingTimeInterval(31))
        precondition(monitor.snapshot.title == "连接异常")

        // A failed command clears automatically; a fresh heartbeat can recover first.
        monitor.completeCommand("start", succeeded: false, message: "failure", now: now.addingTimeInterval(31))
        precondition(monitor.snapshot.title == "操作失败")
        try save(active, date: now.addingTimeInterval(32))
        monitor.refresh(now: now.addingTimeInterval(32))
        precondition(monitor.snapshot.title == "进行中")
        monitor.refresh(now: now.addingTimeInterval(42))
        precondition(!monitor.snapshot.detail.contains("failure"))
        try "invalid JSON".write(to: file, atomically: true, encoding: .utf8)
        monitor.refresh(now: now.addingTimeInterval(43))
        precondition(monitor.snapshot.title == "读取异常")
        try FileManager.default.removeItem(at: file)
        monitor.refresh(now: now.addingTimeInterval(44))
        precondition(monitor.snapshot.title == "未监控")
        try save(["running": false, "phase": "已达本轮 20 分钟上限"], date: now.addingTimeInterval(45))
        monitor.refresh(now: now.addingTimeInterval(45))
        precondition(monitor.snapshot.title == "监控停止")
        monitor.completeCommand("update", succeeded: false, message: "disconnected", now: now.addingTimeInterval(45))
        precondition(monitor.snapshot.title == "操作失败")
        monitor.refresh(now: now.addingTimeInterval(56))
        precondition(monitor.snapshot.title == "监控停止")
        print("PASS: live status priority, command expiry/recovery, missing/corrupt files, stopped monitoring")
        print("PASS: countdown, stale heartbeat, stopped worker, exhausted budget, manual error, generating")
    }
}
