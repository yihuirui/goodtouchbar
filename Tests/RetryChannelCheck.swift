import Foundation
import Darwin
import SystemMonitoring

@main @MainActor struct RetryChannelCheck {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); count += 1; print("PASS: \(label)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func write(pid: Int32, build: Int, running: Bool = true, age: TimeInterval = 0) throws {
            let stamp = formatter.string(from: now.addingTimeInterval(-age))
            let body: [String: Any] = ["running": running, "pid": pid, "sessionID": "fixture",
                                       "protocolVersion": 2, "build": build, "phase": "进行中",
                                       "generating": true, "updatedAt": stamp]
            try JSONSerialization.data(withJSONObject: body)
                .write(to: root.appendingPathComponent("background-status.json"))
            try Data("\(pid)\n".utf8).write(to: root.appendingPathComponent("background.lock"))
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let monitor = WorkBuddyActivityMonitor(directory: root)
        let oldBuild = AppBuild.current == 1 ? AppBuild.current + 1 : AppBuild.current - 1

        // 旧构建的通道：进程活着、锁对得上、时间戳新鲜，但 build 号不是当前版本。
        try write(pid: selfPID, build: oldBuild)
        monitor.refresh(now: now)
        check(monitor.snapshot.state == .stale, "旧构建的通道判为 stale 而不是正常")
        check(monitor.snapshot.title == "通道需更新", "标题提示通道需更新")
        check(monitor.snapshot.detail.contains("build \(oldBuild)")
              && monitor.snapshot.detail.contains("\(AppBuild.current)"),
              "提示里同时给出旧构建号与当前构建号")

        // 同一份状态，构建号对得上就应该按正常状态解析。
        try write(pid: selfPID, build: AppBuild.current)
        monitor.refresh(now: now)
        check(monitor.snapshot.state == .running, "构建号一致时按正常进行中解析")

        // 没有 build 字段的旧状态文件不应被误判。
        let legacy: [String: Any] = ["running": true, "pid": selfPID, "sessionID": "legacy",
                                     "protocolVersion": 1, "phase": "已完成",
                                     "updatedAt": formatter.string(from: now)]
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: root.appendingPathComponent("background-status.json"))
        monitor.refresh(now: now)
        check(monitor.snapshot.state == .completed, "缺少 build 字段的旧状态仍按原逻辑解析")

        print("\(count) retry channel checks passed")
    }
}
