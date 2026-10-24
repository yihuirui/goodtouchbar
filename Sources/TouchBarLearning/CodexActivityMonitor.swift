import Foundation

struct CodexActivitySnapshot: Equatable {
    enum State: String, Equatable {
        case idle
        case running
        case waiting
        case completed
        case stale
        case error
    }

    let state: State
    let title: String
    let detail: String
    let updatedAt: Date?
    let model: String?

    static let idle = CodexActivitySnapshot(
        state: .idle,
        title: "待命",
        detail: "没有检测到最近任务",
        updatedAt: nil,
        model: nil
    )

    var windowText: String {
        detail.isEmpty ? "ChatGPT状态：\(title)" : "ChatGPT状态：\(title) · \(detail)"
    }

    var touchBarText: String {
        switch state {
        case .idle: return "ChatGPT· 待命"
        case .running: return "ChatGPT· 执行"
        case .waiting: return "ChatGPT· 等确认"
        case .completed: return "ChatGPT· 完成"
        case .stale: return "ChatGPT· 过期"
        case .error: return "ChatGPT· 错误"
        }
    }

    var compactTouchBarText: String {
        switch state {
        case .idle: return "ChatGPT·待命"
        case .running: return "ChatGPT·执行"
        case .waiting: return "ChatGPT·确认"
        case .completed: return "ChatGPT·完成"
        case .stale: return "ChatGPT·过期"
        case .error: return "ChatGPT·错误"
        }
    }

    var statusBarText: String {
        switch state {
        case .idle: return "ChatGPT·待命"
        case .running: return "ChatGPT·执行"
        case .waiting: return "ChatGPT·确认"
        case .completed: return "ChatGPT·完成"
        case .stale: return "ChatGPT·过期"
        case .error: return "ChatGPT·错误"
        }
    }

    var needsAttention: Bool {
        state == .waiting || state == .stale || state == .error
    }
}

@MainActor
final class CodexActivityMonitor: NSObject {
    nonisolated private static let maxTailBytes = 512 * 1024
    nonisolated private static let maxEventAge: TimeInterval = 30 * 60
    nonisolated private static let completedDisplayDuration: TimeInterval = 8

    private let sessionDirectory: URL
    private var timer: Timer?
    private var lastRollout: LocalJSONLFileSupport.FileRecord?
    private var inFlight = false, generation = 0

    private(set) var snapshot = CodexActivitySnapshot.idle
    var onChange: (() -> Void)?

    init(sessionDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.sessionDirectory = sessionDirectory
        super.init()
    }

    func start() {
        refresh()

        timer?.invalidate()
        let newTimer = Timer(
            timeInterval: 10,
            target: self,
            selector: #selector(handleRefresh),
            userInfo: nil,
            repeats: true
        )
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1; inFlight = false
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let directory = sessionDirectory, previous = lastRollout, old = snapshot, gen = generation
        LocalJSONLFileSupport.queue.async { [weak self] in
            let rollout = LocalJSONLFileSupport.recentFiles(in: directory).first
            let next = rollout == previous ? Self.expireIfNeeded(old) : (rollout.map(Self.readSnapshot) ?? .idle)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.inFlight = false; self.lastRollout = rollout; self.update(next)
            }
        }
    }

    @objc private func handleRefresh() {
        refresh()
    }

    nonisolated private static func readSnapshot(
        from rollout: LocalJSONLFileSupport.FileRecord
    ) -> CodexActivitySnapshot {
        guard let events = readEvents(from: rollout.url)
        else {
            return CodexActivitySnapshot(
                state: .error,
                title: "无法读取",
                detail: "rollout 日志不可访问",
                updatedAt: rollout.modifiedAt,
                model: nil
            )
        }

        var latestIndex: Int?
        if !events.isEmpty {
            for index in stride(from: events.count - 1, through: 0, by: -1) {
                if isMeaningful(events[index]) {
                    latestIndex = index
                    break
                }
            }
        }

        guard let latestIndex else { return .idle }
        let latest = events[latestIndex]
        let updatedAt = eventDate(latest) ?? rollout.modifiedAt

        let payload = latest["payload"] as? [String: Any] ?? [:]
        let payloadType = payload["type"] as? String
        let toolName = payload["name"] as? String
        let model = modelName(from: latest)

        if isErrorEvent(latest) {
            if Date().timeIntervalSince(updatedAt) > maxEventAge {
                return staleSnapshot(model: model, updatedAt: updatedAt)
            }
            return CodexActivitySnapshot(
                state: .error,
                title: "任务出错",
                detail: errorMessage(from: latest),
                updatedAt: updatedAt,
                model: model
            )
        }

        if Date().timeIntervalSince(updatedAt) > maxEventAge {
            if payloadType == "task_complete" {
                return .idle
            }
            return staleSnapshot(model: model, updatedAt: updatedAt)
        }

        if payloadType == "task_complete" {
            return CodexActivitySnapshot(
                state: .completed,
                title: "已完成",
                detail: model ?? "最近任务",
                updatedAt: updatedAt,
                model: model
            )
        }

        if payloadType == "function_call" || payloadType == "custom_tool_call" {
            if isWaitingTool(toolName) {
                return CodexActivitySnapshot(
                    state: .waiting,
                    title: "等你确认",
                    detail: toolName ?? "需要授权",
                    updatedAt: updatedAt,
                    model: model
                )
            }

            return CodexActivitySnapshot(
                state: .running,
                title: toolTitle(toolName),
                detail: toolName ?? "工具调用",
                updatedAt: updatedAt,
                model: model
            )
        }

        if payloadType == "function_call_output"
            || payloadType == "custom_tool_call_output"
            || payloadType == "patch_apply_end" {
            let previousToolName = previousToolName(in: events, before: latestIndex)
            return CodexActivitySnapshot(
                state: .running,
                title: "刚完成工具",
                detail: previousToolName ?? "继续处理中",
                updatedAt: updatedAt,
                model: model
            )
        }

        return CodexActivitySnapshot(
            state: .running,
            title: "思考中",
            detail: model ?? "正在处理任务",
            updatedAt: updatedAt,
            model: model
        )
    }

    private func update(_ next: CodexActivitySnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }

    nonisolated private static func expireIfNeeded(
        _ snapshot: CodexActivitySnapshot
    ) -> CodexActivitySnapshot {
        guard let updatedAt = snapshot.updatedAt,
              Date().timeIntervalSince(updatedAt) > expiration(for: snapshot)
        else {
            return snapshot
        }
        switch snapshot.state {
        case .idle, .completed:
            return .idle
        case .running, .waiting:
            return staleSnapshot(model: snapshot.model, updatedAt: updatedAt)
        case .stale, .error:
            return snapshot
        }
    }

    nonisolated private static func expiration(for snapshot: CodexActivitySnapshot) -> TimeInterval {
        snapshot.state == .completed ? completedDisplayDuration : maxEventAge
    }

    nonisolated private static func staleSnapshot(
        model: String?,
        updatedAt: Date
    ) -> CodexActivitySnapshot {
        CodexActivitySnapshot(
            state: .stale,
            title: "数据过期",
            detail: "超过 30 分钟未更新",
            updatedAt: updatedAt,
            model: model
        )
    }

    nonisolated private static func readEvents(from url: URL) -> [[String: Any]]? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }

        let start = max(0, size - Int64(maxTailBytes))
        handle.seek(toFileOffset: UInt64(start))
        let data = (try? handle.read(upToCount: maxTailBytes)) ?? Data()
        handle.closeFile()

        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        let events = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return events
    }

    nonisolated private static func isMeaningful(_ event: [String: Any]) -> Bool {
        let eventType = event["type"] as? String
        let payload = event["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String

        if eventType == "response_item" {
            return [
                "function_call",
                "function_call_output",
                "custom_tool_call",
                "custom_tool_call_output",
                "reasoning",
                "message",
                "error",
            ].contains(payloadType)
        }

        if eventType == "event_msg" {
            return [
                "task_started",
                "task_complete",
                "task_failed",
                "turn_aborted",
                "error",
                "user_message",
                "agent_message",
                "agent_reasoning",
                "patch_apply_end",
            ].contains(payloadType)
        }

        return false
    }

    nonisolated private static func isErrorEvent(_ event: [String: Any]) -> Bool {
        let eventType = event["type"] as? String
        let payload = event["payload"] as? [String: Any]
        let payloadType = payload?["type"] as? String
        let errorTypes = [
            "error",
            "task_failed",
            "turn_aborted",
            "model_error",
            "tool_error",
        ]

        return errorTypes.contains(eventType ?? "")
            || errorTypes.contains(payloadType ?? "")
            || event["error"] != nil
            || payload?["error"] != nil
    }

    nonisolated private static func errorMessage(from event: [String: Any]) -> String {
        let payload = event["payload"] as? [String: Any]
        if let message = payload?["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = event["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = payload?["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        return "最近任务没有成功完成"
    }

    nonisolated private static func previousToolName(
        in events: [[String: Any]],
        before index: Int
    ) -> String? {
        guard index > 0 else { return nil }
        for candidate in stride(from: index - 1, through: 0, by: -1) {
            let payload = events[candidate]["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String
            if payloadType == "function_call" || payloadType == "custom_tool_call" {
                return payload?["name"] as? String
            }
        }
        return nil
    }

    nonisolated private static func eventDate(_ event: [String: Any]) -> Date? {
        guard let timestamp = event["timestamp"] as? String else { return nil }
        return LocalJSONLFileSupport.eventDate(timestamp)
    }

    nonisolated private static func modelName(from event: [String: Any]) -> String? {
        let payload = event["payload"] as? [String: Any]
        let providerData = event["providerData"] as? [String: Any]
            ?? payload?["provider_data"] as? [String: Any]
        return providerData?["model"] as? String
    }

    nonisolated private static func isWaitingTool(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.lowercased().range(of: "askuser|approval|permission", options: .regularExpression) != nil
    }

    nonisolated private static func toolTitle(_ name: String?) -> String {
        let lowered = name?.lowercased() ?? ""
        if lowered.range(of: "apply_patch|edit|write|patch", options: .regularExpression) != nil {
            return "修改文件"
        }
        if lowered.range(of: "exec|shell|bash|terminal|command", options: .regularExpression) != nil {
            return "执行命令"
        }
        if lowered.range(of: "browser|chrome|web|search|read|grep", options: .regularExpression) != nil {
            return "查看资料"
        }
        return "调用工具"
    }
}
