import Foundation

/// Agent 速度来源。
///
/// - WorkBuddy 国际版：`~/.workbuddy-ai/projects`
/// - WorkBuddy 国内版：`~/.workbuddy/projects`
/// - Codex：`~/.codex/sessions`
///
/// 三家日志结构不同，但都能还原出「一次响应输出了多少词元、花了多久」，
/// 因此统一折算成 token/s 显示。
enum AgentSpeedSource: String, CaseIterable, Equatable {
    case workbuddyInternational
    case workbuddyDomestic
    case codex

    var displayName: String {
        switch self {
        case .workbuddyInternational: return "WorkBuddy 国际版"
        case .workbuddyDomestic: return "WorkBuddy 国内版"
        case .codex: return "Codex"
        }
    }

    /// 菜单与设置里的短名，宽度有限。
    var shortName: String {
        switch self {
        case .workbuddyInternational: return "国际版"
        case .workbuddyDomestic: return "国内版"
        case .codex: return "Codex"
        }
    }

    /// Touch Bar 上的前缀。
    var touchBarTag: String {
        switch self {
        case .workbuddyInternational: return "WB"
        case .workbuddyDomestic: return "WB·CN"
        case .codex: return "CX"
        }
    }

    var relativeRoot: String {
        switch self {
        case .workbuddyInternational: return ".workbuddy-ai/projects"
        case .workbuddyDomestic: return ".workbuddy/projects"
        case .codex: return ".codex/sessions"
        }
    }

    /// Codex 只认 rollout 文件，同目录还有别的索引文件。
    var fileNamePrefix: String? {
        switch self {
        case .codex: return "rollout-"
        case .workbuddyInternational, .workbuddyDomestic: return nil
        }
    }

    func root(home: URL) -> URL {
        relativeRoot
            .split(separator: "/")
            .reduce(home) { $0.appendingPathComponent(String($1), isDirectory: true) }
    }
}

/// 一次模型响应的实测结果。
struct AgentSpeedStep: Equatable {
    /// 输出词元少于这个数时首 token 延迟占主导，速度噪声太大。
    static let minimumOutputTokens: Int64 = 8
    /// 短于这个时长的区间不可信（同一批行会被几乎同时写入）。
    static let minimumDuration: TimeInterval = 0.05

    let model: String?
    let outputTokens: Int64
    let startedAt: Date?
    let endedAt: Date

    var duration: TimeInterval? {
        guard let startedAt, endedAt > startedAt else { return nil }
        let value = endedAt.timeIntervalSince(startedAt)
        guard value >= Self.minimumDuration else { return nil }
        return value
    }

    /// 速度 = 输出词元 ÷ 实测耗时（含首 token 延迟），与 Agent Speed 的 spec 一致。
    var speed: Double? {
        guard outputTokens >= Self.minimumOutputTokens, let duration else { return nil }
        return Double(outputTokens) / duration
    }
}

/// 一个会话文件解析出来的摘要。
struct AgentSpeedParse: Equatable {
    var steps: [AgentSpeedStep] = []
    var latestActivity: Date?
    var pendingToolCalls: Int = 0
    var outputTokens: Int64 = 0
}

/// WorkBuddy 会话文件：每行一个 JSON，`providerData` 里带 `messageId`／`model`／`rawUsage`。
enum WorkBuddyTranscriptParser {
    private struct MutableStep {
        var model: String?
        var outputTokens: Int64 = 0
        var startedAt: Int64?
        var endedAt: Int64?

        mutating func merge(_ provider: [String: Any], timestamp: Int64?) {
            if let usage = provider["rawUsage"] as? [String: Any] {
                if let output = (usage["completion_tokens"] as? NSNumber)?.int64Value {
                    outputTokens = max(outputTokens, output)
                }
            }
            if let model { self.model = model }
            guard let timestamp else { return }
            startedAt = min(startedAt ?? timestamp, timestamp)
            endedAt = max(endedAt ?? timestamp, timestamp)
        }
    }

    /// - Parameter data: 会话文件的一段内容，通常取尾部；首行若被截断会自动丢弃。
    static func parse(_ data: Data) -> AgentSpeedParse {
        var order: [String] = []
        var records: [String: MutableStep] = [:]
        var anchor: Int64?
        var latest: Int64?
        var pending: Set<String> = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }

            let type = object["type"] as? String
            let timestamp = (object["timestamp"] as? NSNumber)?.int64Value
            if let timestamp { latest = max(latest ?? timestamp, timestamp) }

            switch type {
            case "message" where object["role"] as? String == "user":
                // 用户发话后模型开始生成，这是首个 step 的计时起点。
                anchor = timestamp ?? anchor
                continue
            case "function_call_result":
                // 工具结果回填后模型才开始下一步生成。
                anchor = timestamp ?? anchor
                if let callID = object["callId"] as? String { pending.remove(callID) }
                continue
            case "function_call":
                if let callID = object["callId"] as? String { pending.insert(callID) }
                // 不 continue：有的 step 只有工具调用行、没有推理行，仍要参与计时。
            default:
                break
            }

            guard let provider = object["providerData"] as? [String: Any],
                  let messageID = provider["messageId"] as? String
            else { continue }

            let model = (provider["model"] as? String) ?? (provider["requestModelName"] as? String)
            if records[messageID] == nil {
                order.append(messageID)
                records[messageID] = MutableStep(model: model, startedAt: anchor)
            }
            records[messageID]?.merge(provider, timestamp: timestamp)
        }

        var parse = AgentSpeedParse()
        for key in order {
            guard let record = records[key], let ended = record.endedAt else { continue }
            let step = AgentSpeedStep(
                model: record.model,
                outputTokens: record.outputTokens,
                startedAt: record.startedAt.map(date(fromMilliseconds:)),
                endedAt: date(fromMilliseconds: ended)
            )
            parse.steps.append(step)
            parse.outputTokens += step.outputTokens
        }
        parse.latestActivity = latest.map(date(fromMilliseconds:))
        parse.pendingToolCalls = pending.count
        return parse
    }

    static func date(fromMilliseconds value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1000)
    }
}

/// Codex rollout：`token_usage_record` 带精确 `output_tokens`，
/// `turn_context` 带模型名，工具输出行标记下一段生成的起点。
enum CodexTranscriptParser {
    static func parse(_ data: Data) -> AgentSpeedParse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var parse = AgentSpeedParse()
        var anchor: Date?
        var model: String?
        var pending: Set<String> = []
        var latest: Date?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String
            let timestamp = (object["timestamp"] as? String).flatMap(formatter.date(from:))
            if let timestamp { latest = max(latest ?? timestamp, timestamp) }

            if type == "turn_context" {
                if let value = payload?["model"] as? String, !value.isEmpty { model = value }
                continue
            }

            if type == "event_msg" {
                if payloadType == "task_started" || payloadType == "user_message" {
                    anchor = timestamp ?? anchor
                }
                continue
            }

            guard type == "response_item" else {
                if type == "token_usage_record" {
                    append(record: payload, at: timestamp, anchor: &anchor, model: model, parse: &parse)
                }
                continue
            }

            switch payloadType {
            case "function_call", "custom_tool_call":
                if let callID = payload?["call_id"] as? String { pending.insert(callID) }
            case "function_call_output", "custom_tool_call_output":
                if let callID = payload?["call_id"] as? String { pending.remove(callID) }
                anchor = timestamp ?? anchor
            default:
                break
            }
        }

        parse.latestActivity = latest
        parse.pendingToolCalls = pending.count
        return parse
    }

    private static func append(
        record payload: [String: Any]?,
        at timestamp: Date?,
        anchor: inout Date?,
        model: String?,
        parse: inout AgentSpeedParse
    ) {
        guard let usage = payload?["usage"] as? [String: Any],
              let output = (usage["output_tokens"] as? NSNumber)?.int64Value,
              let end = timestamp
        else { return }
        let step = AgentSpeedStep(
            model: model,
            outputTokens: output,
            startedAt: anchor,
            endedAt: end
        )
        parse.steps.append(step)
        parse.outputTokens += output
        // 没有工具输出时，下一段生成的起点就是这次响应的结束时刻。
        anchor = end
    }
}

struct AgentSpeedSnapshot: Equatable {
    enum State: String, Equatable {
        case idle
        case running
        case completed
        case stale
        case error
    }

    let source: AgentSpeedSource
    let state: State
    let speed: Double?
    let model: String?
    let outputTokens: Int64
    let updatedAt: Date?
    let detail: String

    static func idle(_ source: AgentSpeedSource) -> AgentSpeedSnapshot {
        AgentSpeedSnapshot(
            source: source,
            state: .idle,
            speed: nil,
            model: nil,
            outputTokens: 0,
            updatedAt: nil,
            detail: "未检测到会话"
        )
    }

    static func format(_ speed: Double) -> String {
        String(format: "%.1f t/s", speed)
    }

    var speedText: String? {
        guard state == .running || state == .completed, let speed else { return nil }
        return Self.format(speed)
    }

    /// Touch Bar 紧凑文本，例如 `WB 86`。
    var touchBarText: String {
        guard let speed, state == .running || state == .completed else {
            return "\(source.touchBarTag)·待命"
        }
        return "\(source.touchBarTag) \(Int(speed.rounded()))"
    }

    /// 菜单子项一行，例如 `国际版 · 86.3 t/s`。
    var rowText: String {
        switch state {
        case .running, .completed:
            guard let speedText else { return "\(source.shortName) · 待命" }
            return "\(source.shortName) · \(speedText)"
        case .idle: return "\(source.shortName) · 待命"
        case .stale: return "\(source.shortName) · 过期"
        case .error: return "\(source.shortName) · 读取失败"
        }
    }

    /// 完整描述，菜单标题与诊断用。
    var menuText: String {
        switch state {
        case .idle: return "\(source.displayName)：待命"
        case .error: return "\(source.displayName)：读取失败"
        case .stale: return "\(source.displayName)：超过 30 分钟无活动"
        case .running, .completed:
            guard let speedText else { return "\(source.displayName)：待命" }
            return "\(source.displayName)：\(speedText) · \(detail)"
        }
    }

    var needsAttention: Bool {
        state == .stale || state == .error
    }
}

/// 三个来源的合集，按 `AgentSpeedSource.allCases` 顺序排列。
struct AgentSpeedBundle: Equatable {
    let snapshots: [AgentSpeedSnapshot]

    static let idle = AgentSpeedBundle(
        snapshots: AgentSpeedSource.allCases.map(AgentSpeedSnapshot.idle)
    )

    func snapshot(for source: AgentSpeedSource) -> AgentSpeedSnapshot {
        snapshots.first { $0.source == source } ?? .idle(source)
    }

    /// 最近活跃的来源；都过期时退回到最近有活动的那个。
    var primary: AgentSpeedSnapshot {
        let live = snapshots.filter { $0.state != .stale && $0.state != .idle }
        let pool = live.isEmpty ? snapshots : live
        return pool.max { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case let (left?, right?):
                if left == right { return lhs.source.rawValue > rhs.source.rawValue }
                return left < right
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil): return lhs.source.rawValue > rhs.source.rawValue
            }
        } ?? .idle(.workbuddyInternational)
    }

    var touchBarText: String {
        primary.touchBarText
    }

    var activeCount: Int {
        snapshots.filter { $0.state == .running }.count
    }
}

/// 读取三个来源的会话日志，实时算出最近一次响应的输出速度。
@MainActor
final class AgentSpeedMonitor: NSObject {
    nonisolated private static let maxTailBytes = 512 * 1024
    /// 独立队列：不跟 Codex 状态监控共用串行队列，避免互相拖慢。
    nonisolated private static let queue = DispatchQueue(
        label: "io.github.yihuirui.goodtouchbar.agent-speed",
        qos: .utility
    )
    /// 最近活动在这个窗口内视为“正在生成”。
    nonisolated private static let activeWindow: TimeInterval = 20
    /// 超过这个时间没有任何活动就不再显示速度。
    nonisolated private static let staleWindow: TimeInterval = 30 * 60
    /// 目录枚举结果的复用窗口。
    ///
    /// 会话目录只增不减（本机已有 360+ 个 jsonl），3 秒一轮的全树枚举没必要每次都做。
    /// 枚举结果按来源缓存，窗口内只对已知文件重新 stat；文件被删或过期才重新枚举。
    nonisolated private static let enumerationTTL: TimeInterval = 6

    private struct Transcript {
        let url: URL
        let modifiedAt: Date
        let size: Int64
    }

    private let home: URL
    private let sources: [AgentSpeedSource]
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0
    private var cached: [String: (modifiedAt: Date, size: Int64, snapshot: AgentSpeedSnapshot)] = [:]
    /// 每个来源最近一次目录枚举的结果与时间点。
    private var enumeration: [AgentSpeedSource: (at: Double, transcript: Transcript?)] = [:]

    private(set) var bundle = AgentSpeedBundle.idle
    var onChange: (() -> Void)?

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sources: [AgentSpeedSource] = AgentSpeedSource.allCases
    ) {
        self.home = home
        self.sources = sources
        super.init()
    }

    func start() {
        refresh()
        timer?.invalidate()
        let timer = Timer(
            timeInterval: 3,
            target: self,
            selector: #selector(handleRefresh),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        inFlight = false
    }

    func refresh() {
        guard !inFlight else { return }
        inFlight = true
        let sources = self.sources
        let home = self.home
        let previous = cached
        let previousEnumeration = enumeration
        let gen = generation

        Self.queue.async { [weak self] in
            var next: [String: (modifiedAt: Date, size: Int64, snapshot: AgentSpeedSnapshot)] = [:]
            var nextEnumeration: [AgentSpeedSource: (at: Double, transcript: Transcript?)] = [:]
            var snapshots: [AgentSpeedSnapshot] = []
            let now = ProcessInfo.processInfo.systemUptime

            for source in sources {
                let resolved = Self.transcript(
                    for: source,
                    home: home,
                    cached: previousEnumeration[source],
                    now: now
                )
                nextEnumeration[source] = resolved.entry
                guard let transcript = resolved.transcript else {
                    snapshots.append(.idle(source))
                    continue
                }
                let key = transcript.url.path
                if let hit = previous[key],
                   hit.modifiedAt == transcript.modifiedAt,
                   hit.size == transcript.size {
                    next[key] = hit
                    snapshots.append(hit.snapshot)
                    continue
                }
                let snapshot = Self.read(source: source, transcript: transcript)
                next[key] = (transcript.modifiedAt, transcript.size, snapshot)
                snapshots.append(snapshot)
            }

            let bundle = AgentSpeedBundle(snapshots: snapshots)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.inFlight = false
                self.cached = next
                self.enumeration = nextEnumeration
                self.update(bundle)
            }
        }
    }

    @objc private func handleRefresh() {
        refresh()
    }

    private func update(_ next: AgentSpeedBundle) {
        guard next != bundle else { return }
        bundle = next
        onChange?()
    }

    // MARK: - 后台读取

    /// 取该来源当前要读的会话文件。
    ///
    /// 命中枚举缓存且文件仍在时，只重新 stat 一次；否则做一次全树枚举。
    /// 返回新的缓存条目与本次要读的文件，两者一起回写，避免重复枚举。
    nonisolated private static func transcript(
        for source: AgentSpeedSource,
        home: URL,
        cached entry: (at: Double, transcript: Transcript?)?,
        now: Double
    ) -> (entry: (at: Double, transcript: Transcript?), transcript: Transcript?) {
        if let entry,
           now - entry.at < enumerationTTL,
           now >= entry.at,
           let known = entry.transcript,
           let refreshed = statTranscript(known.url) {
            return (entry, refreshed)
        }
        let found = newestTranscript(for: source, home: home)
        return ((now, found), found)
    }

    /// 只重新读一次时间戳与大小，不碰目录。
    nonisolated private static func statTranscript(_ url: URL) -> Transcript? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey,
        ]),
        values.isRegularFile == true,
        let modifiedAt = values.contentModificationDate
        else { return nil }
        return Transcript(url: url, modifiedAt: modifiedAt, size: Int64(values.fileSize ?? 0))
    }

    nonisolated private static func newestTranscript(
        for source: AgentSpeedSource,
        home: URL
    ) -> Transcript? {
        let root = source.root(home: home)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }

        var newest: Transcript?
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let prefix = source.fileNamePrefix, !url.lastPathComponent.hasPrefix(prefix) { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ]),
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate
            else { continue }
            if let current = newest, current.modifiedAt >= modifiedAt { continue }
            newest = Transcript(
                url: url,
                modifiedAt: modifiedAt,
                size: Int64(values.fileSize ?? 0)
            )
        }
        return newest
    }

    nonisolated private static func read(
        source: AgentSpeedSource,
        transcript: Transcript
    ) -> AgentSpeedSnapshot {
        guard let data = readTail(url: transcript.url, maxBytes: maxTailBytes) else {
            return AgentSpeedSnapshot(
                source: source,
                state: .error,
                speed: nil,
                model: nil,
                outputTokens: 0,
                updatedAt: transcript.modifiedAt,
                detail: "会话日志不可读"
            )
        }

        let parse: AgentSpeedParse
        switch source {
        case .workbuddyInternational, .workbuddyDomestic:
            parse = WorkBuddyTranscriptParser.parse(data)
        case .codex:
            parse = CodexTranscriptParser.parse(data)
        }

        guard let latest = parse.latestActivity else {
            return AgentSpeedSnapshot(
                source: source,
                state: .idle,
                speed: nil,
                model: nil,
                outputTokens: 0,
                updatedAt: nil,
                detail: "会话刚开始"
            )
        }

        // 取最近一个算得出速度的 step；工具还在跑时沿用上一次实测值。
        let measured = parse.steps.last { $0.speed != nil }
        let model = measured?.model ?? parse.steps.last?.model
        let age = Date().timeIntervalSince(latest)

        let state: AgentSpeedSnapshot.State
        if parse.pendingToolCalls > 0 || age <= activeWindow {
            state = .running
        } else if age <= staleWindow {
            state = .completed
        } else {
            state = .stale
        }

        let detail: String
        if parse.pendingToolCalls > 0 {
            detail = "工具执行中"
        } else if let model, let measured {
            detail = "\(model) · \(measured.outputTokens) 词元"
        } else if let model {
            detail = model
        } else {
            detail = "已连接"
        }

        return AgentSpeedSnapshot(
            source: source,
            state: state,
            speed: state == .stale ? nil : measured?.speed,
            model: model,
            outputTokens: parse.outputTokens,
            updatedAt: latest,
            detail: state == .stale ? "超过 30 分钟无活动" : detail
        )
    }

    nonisolated private static func readTail(url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        do {
            try handle.seek(toOffset: start)
        } catch {
            return nil
        }
        guard var data = try? handle.readToEnd() else { return nil }
        // 起始位置落在行中间时丢掉首行，避免解析到半个 JSON。
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = data[data.index(after: newline)...]
        }
        return data
    }
}
