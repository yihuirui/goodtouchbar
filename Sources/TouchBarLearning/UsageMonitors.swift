import Foundation
import SystemMonitoring

enum LocalJSONLFileSupport {
    static let queue = DispatchQueue(label: "io.github.yihuirui.goodtouchbar.session-index", qos: .utility)
    // Access only on queue; one shared directory index for activity and quota.
    private static var cached: [String: (Double, [FileRecord])] = [:]
    static func recentFiles(in directory: URL) -> [FileRecord] {
        let key = directory.path, now = ProcessInfo.processInfo.systemUptime
        if let entry = cached[key], now-entry.0 < 2 { return entry.1 }
        let files = collectFiles(in: directory, namePrefix: "rollout-").sorted { $0.modifiedAt > $1.modifiedAt }
        if cached.count >= 8 { cached.removeAll() }
        cached[key] = (now, files); return files
    }
    static func eventDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    struct FileRecord: Equatable {
        let url: URL
        let modifiedAt: Date
        let size: Int64
    }

    static func collectFiles(
        in directory: URL,
        namePrefix: String? = nil,
        nameSuffix: String = ".jsonl"
    ) -> [FileRecord] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var files: [FileRecord] = []
        let suffix = String(nameSuffix.dropFirst())
        for case let entry as URL in enumerator {
            guard let values = try? entry.resourceValues(forKeys: [
                .isDirectoryKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ]),
            values.isDirectory != true,
            entry.pathExtension == suffix,
                  namePrefix.map({ entry.lastPathComponent.hasPrefix($0) }) ?? true,
                  let modifiedAt = values.contentModificationDate
            else {
                continue
            }

            files.append(FileRecord(
                url: entry,
                modifiedAt: modifiedAt,
                size: Int64(values.fileSize ?? 0)
            ))
        }
        return files
    }

    static func newestFile(
        in directory: URL,
        namePrefix: String? = nil,
        nameSuffix: String = ".jsonl"
    ) -> FileRecord? {
        collectFiles(
            in: directory,
            namePrefix: namePrefix,
            nameSuffix: nameSuffix
        ).max { $0.modifiedAt < $1.modifiedAt }
    }

    static func readLines(from url: URL, maxBytes: Int) -> [String]? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }

        let start = max(0, size - Int64(maxBytes))
        handle.seek(toFileOffset: UInt64(start))
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        handle.closeFile()

        var text = String(decoding: data, as: UTF8.self)
        if start > 0 {
            guard let newline = text.firstIndex(of: "\n") else { return [] }
            text = String(text[text.index(after: newline)...])
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func readObjects(from url: URL, maxBytes: Int) -> [[String: Any]] {
        readLines(from: url, maxBytes: maxBytes)?.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } ?? []
    }
}

struct CodexQuotaWindowSnapshot: Equatable {
    let label: String
    let remainingPercent: Int
    let resetAt: Date?
    let resetText: String
}

struct CodexQuotaSnapshot: Equatable {
    let remainingPercent: Int?
    let resetAt: Date?
    let resetText: String
    let windowLabel: String?
    let windows: [CodexQuotaWindowSnapshot]
    let updatedAt: Date?
    let updatedAgeText: String?
    let isStale: Bool
    var awaitingReset = false

    static let unavailable = CodexQuotaSnapshot(
        remainingPercent: nil,
        resetAt: nil,
        resetText: "",
        windowLabel: nil,
        windows: [],
        updatedAt: nil,
        updatedAgeText: nil,
        isStale: true
    )

    var windowText: String {
        guard !windows.isEmpty else { return awaitingReset ? "使用量：5小时／7天 待更新" : "使用量：5小时 -- · 7天 --" }
        let details = ["5小时", "7天"].map { label -> String in
            guard let window = windows.first(where: { $0.label == label }) else { return "\(label) --" }
            let reset = window.resetText.isEmpty ? "" : " · \(window.resetText)"
            let freshness = updatedAgeText.map { " · 更新于\($0)" } ?? " · 更新时间未知"
            let stale = isStale ? " · 数据较旧" : ""
            return "\(window.label)余 \(window.remainingPercent)%\(reset)\(freshness)\(stale)"
        }
        return "使用量：" + details.joined(separator: " · ")
    }

    var touchBarText: String {
        if windows.isEmpty && awaitingReset { return "⏳5小时待更新 · 📅7天待更新" }
        let stale = isStale ? "·旧" : ""
        return ["5小时", "7天"].map { label in
            let icon = label == "5小时" ? "⏳" : "📅"
            guard let window = windows.first(where: { $0.label == label }) else { return "\(icon)\(label) --" }
            let countdown = label == "5小时" && !window.resetText.isEmpty ? " (\(window.resetText)重置)" : ""
            return "\(icon)\(label)\(window.remainingPercent)%\(stale)\(countdown)"
        }.joined(separator: " · ")
    }

    var menuText: String {
        windowText
    }

    var minimumRemainingPercent: Int? {
        windows.first(where: { $0.label == "7天" })?.remainingPercent
            ?? windows.first(where: { $0.label == "5小时" })?.remainingPercent
    }

    static func ageText(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分钟前" }
        if minutes < 24 * 60 { return "\(minutes / 60)小时前" }
        return "\(minutes / (24 * 60))天前"
    }
}

@MainActor
final class CodexQuotaMonitor: NSObject {
    nonisolated private static let maxFiles = 12
    nonisolated private static let maxTailBytes = 1024 * 1024
    nonisolated private static let maxEventAge: TimeInterval = 12 * 60 * 60
    nonisolated private static let weeklyWindowMinutes = 7 * 24 * 60
    nonisolated private static let supportedWindowMinutes = [300, weeklyWindowMinutes]

    private let sessionDirectory: URL
    private var timer: Timer?
    private var lastFiles: [LocalJSONLFileSupport.FileRecord]?
    private var inFlight = false, generation = 0

    private(set) var snapshot = CodexQuotaSnapshot.unavailable
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
            timeInterval: 30,
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
        let directory = sessionDirectory, previous = lastFiles, oldSnapshot = snapshot, gen = generation
        LocalJSONLFileSupport.queue.async { [weak self] in
            let files = Self.recentFiles(from: directory)
            let next = Self.refreshCountdown(files == previous ? oldSnapshot : Self.readSnapshot(from: files))
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.inFlight = false; self.lastFiles = files; self.update(next)
            }
        }
    }

    @objc private func handleRefresh() {
        refresh()
    }

    nonisolated private static func recentFiles(
        from directory: URL
    ) -> [LocalJSONLFileSupport.FileRecord] {
        Array(LocalJSONLFileSupport.recentFiles(in: directory).prefix(maxFiles))
    }

    nonisolated private static func readSnapshot(
        from files: [LocalJSONLFileSupport.FileRecord]
    ) -> CodexQuotaSnapshot {

        var latestWindows: [Int: WindowSnapshot] = [:]
        for file in files {
            let events = LocalJSONLFileSupport.readObjects(
                from: file.url,
                maxBytes: maxTailBytes
            )

            // A rollout can contain several metering buckets. The default
            // `codex` bucket is the account quota this UI reports; newer
            // `base_model_inference` / `gpt-reserve` events must not replace it.
            // Search backwards for the latest authoritative event instead of
            // stopping at the file's newest token_count event.
            guard let event = events.reversed().first(where: { event in
                guard let payload = event["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let limits = payload["rate_limits"] as? [String: Any]
                else {
                    return false
                }
                return isAuthoritativeLimit(limits) && containsSupportedWindow(limits)
            }) else {
                continue
            }

            let updatedAt = eventDate(event)
            let timestamp = updatedAt ?? file.modifiedAt
            let payload = event["payload"] as? [String: Any] ?? [:]
            let limits = payload["rate_limits"] as? [String: Any] ?? [:]
            let now = Date()
            guard timestamp <= now.addingTimeInterval(60) else { continue }
            addWindow(
                limits["primary"] as? [String: Any],
                timestamp: timestamp,
                updatedAt: updatedAt,
                now: now,
                to: &latestWindows
            )
            addWindow(
                limits["secondary"] as? [String: Any],
                timestamp: timestamp,
                updatedAt: updatedAt,
                now: now,
                to: &latestWindows
            )
        }

        guard !latestWindows.isEmpty else { return .unavailable }
        let windows = supportedWindowMinutes.compactMap { minutes -> CodexQuotaWindowSnapshot? in
            guard let window = latestWindows[minutes] else { return nil }
            return CodexQuotaWindowSnapshot(
                label: minutes == 300 ? "5小时" : "7天",
                remainingPercent: window.remaining,
                resetAt: window.resetAt,
                resetText: formatResetCountdown(window.resetAt) ?? ""
            )
        }
        let preferred = windows.first(where: { $0.label == "7天" }) ?? windows[0]
        let updatedAt = latestWindows.values.compactMap(\.updatedAt).min()

        return CodexQuotaSnapshot(
            remainingPercent: preferred.remainingPercent,
            resetAt: preferred.resetAt,
            resetText: preferred.resetText,
            windowLabel: preferred.label,
            windows: windows,
            updatedAt: updatedAt,
            updatedAgeText: updatedAt.map { CodexQuotaSnapshot.ageText($0) },
            isStale: updatedAt.map { Date().timeIntervalSince($0) > maxEventAge } ?? true
        )
    }

    private func update(_ next: CodexQuotaSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onChange?()
    }

    nonisolated private static func refreshCountdown(
        _ snapshot: CodexQuotaSnapshot
    ) -> CodexQuotaSnapshot {
        guard !snapshot.windows.isEmpty else { return snapshot }
        let now = Date()
        let activeWindows = snapshot.windows.filter { $0.resetAt.map { $0 > now } ?? true }.map { window in
            CodexQuotaWindowSnapshot(label: window.label, remainingPercent: window.remainingPercent,
                                     resetAt: window.resetAt, resetText: formatResetCountdown(window.resetAt) ?? "")
        }
        let updatedAgeText = snapshot.updatedAt.map {
            CodexQuotaSnapshot.ageText($0, now: now)
        }
        let isStale = snapshot.updatedAt.map {
            now.timeIntervalSince($0) > maxEventAge
        } ?? true
        let preferred = activeWindows.first(where: { $0.label == "7天" }) ?? activeWindows.first
        return CodexQuotaSnapshot(
            remainingPercent: preferred?.remainingPercent,
            resetAt: preferred?.resetAt,
            resetText: preferred?.resetText ?? "待更新",
            windowLabel: preferred?.label,
            windows: activeWindows,
            updatedAt: snapshot.updatedAt,
            updatedAgeText: updatedAgeText,
            isStale: isStale,
            awaitingReset: activeWindows.isEmpty
        )
    }

    private struct WindowSnapshot {
        let remaining: Int
        let resetAt: Date?
        let timestamp: Date
        let updatedAt: Date?
    }

    nonisolated private static func addWindow(
        _ value: [String: Any]?,
        timestamp: Date,
        updatedAt: Date?,
        now: Date,
        to windows: inout [Int: WindowSnapshot]
    ) {
        guard let value,
              isSupportedWindow(value),
              let duration = number(value["window_minutes"]),
              let usedPercent = number(value["used_percent"])
        else {
            return
        }

        let resetAt = unixDate(value["resets_at"])
        let isRecent = now.timeIntervalSince(timestamp) <= maxEventAge
        let isCurrentQuotaWindow = resetAt.map { $0 > now } ?? false
        guard isRecent || isCurrentQuotaWindow else { return }

        let minutes = Int(duration.rounded())
        if let current = windows[minutes], current.timestamp >= timestamp { return }
        windows[minutes] = WindowSnapshot(
            remaining: Int(max(0, min(100, (100 - usedPercent).rounded()))),
            resetAt: resetAt,
            timestamp: timestamp,
            updatedAt: updatedAt
        )
    }

    nonisolated private static func containsSupportedWindow(_ limits: [String: Any]) -> Bool {
        [limits["primary"], limits["secondary"]].contains { value in
            guard let value = value as? [String: Any] else { return false }
            return isSupportedWindow(value)
        }
    }

    nonisolated private static func isSupportedWindow(_ value: [String: Any]) -> Bool {
        guard let minutes = number(value["window_minutes"]) else { return false }
        return supportedWindowMinutes.contains(Int(minutes.rounded()))
    }

    nonisolated private static func isAuthoritativeLimit(_ limits: [String: Any]) -> Bool {
        if let limitID = limits["limit_id"] as? String {
            let normalized = limitID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !normalized.isEmpty {
                return normalized == "codex"
            }
        }

        // Older rollout records may omit limit_id. Keep those as legacy Codex
        // records, but never accept a reserve-only record by its display name.
        if let limitName = limits["limit_name"] as? String {
            return limitName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() != "gpt-reserve"
        }
        return true
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
        return nil
    }

    nonisolated private static func unixDate(_ value: Any?) -> Date? {
        guard let numeric = number(value), numeric > 0 else { return nil }
        let seconds = numeric > 1_000_000_000_000 ? numeric / 1000 : numeric
        guard (946684800...4102444800).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    nonisolated private static func eventDate(_ event: [String: Any]) -> Date? {
        guard let timestamp = event["timestamp"] as? String else { return nil }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: timestamp) {
            return date
        }
        return ISO8601DateFormatter().date(from: timestamp)
    }

    nonisolated private static func formatResetCountdown(_ date: Date?) -> String? {
        guard let date else { return nil }
        let totalMinutes = max(0, Int(ceil(date.timeIntervalSinceNow / 60)))
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return "\(days)天\(hours)时" }
        if hours > 0 { return "\(hours)时\(minutes)分" }
        return "\(minutes)分"
    }
}

struct WorkBuddyActivitySnapshot: Equatable {
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

    static let idle = WorkBuddyActivitySnapshot(
        state: .idle,
        title: "待命",
        detail: "没有检测到最近任务",
        updatedAt: nil
    )

    var windowText: String {
        detail.isEmpty ? "WB AI：\(title)" : "WB AI：\(title) · \(detail)"
    }

    var touchBarText: String {
        switch state {
        case .idle: return "WB状态· 待命"
        case .running: return "WB状态· 执行中"
        case .waiting: return "WB状态· 等确认"
        case .completed: return "WB状态· 完成"
        case .stale: return "WB状态· 过期"
        case .error: return "WB状态· 错误"
        }
    }

    var compactTouchBarText: String {
        "WB AI·\(title)"
    }

    var statusBarText: String {
        switch state {
        case .idle: return "WB·待命"
        case .running: return "WB·执行"
        case .waiting: return "WB·确认"
        case .completed: return "WB·完成"
        case .stale: return "WB·过期"
        case .error: return "WB·错误"
        }
    }

    var needsAttention: Bool {
        state == .waiting || state == .stale || state == .error
    }

    var menuText: String {
        windowText
    }
}


struct TokenUsageSnapshot: Equatable {
    let tokens: Int64?
    let updatedAt: Date?
    let stale: Bool

    static let unavailable = TokenUsageSnapshot(
        tokens: nil,
        updatedAt: nil,
        stale: true
    )

    var windowText: String {
        guard let tokens else { return "词元：--" }
        return "词元：\(Self.exactTokenText(tokens))" + (stale ? " · 旧" : "")
    }

    var touchBarText: String {
        guard let tokens else { return "💰--" }
        return "💰\(Self.shortTokenText(tokens))" + (stale ? "·旧" : "")
    }

    var menuText: String {
        guard let tokens else { return "词元：--" }
        let age = updatedAt.map { " · \(Self.ageText($0))" } ?? ""
        return "词元：\(Self.exactTokenText(tokens))\(age)"
    }

    private static func exactTokenText(_ tokens: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: tokens)) ?? String(tokens)
    }

    static func shortTokenText(_ tokens: Int64) -> String {
        if tokens >= 100_000_000 {
            return String(format: "%.1f亿", Double(tokens) / 100_000_000)
        }
        if tokens >= 10_000 {
            return "\(Int((Double(tokens) / 10_000).rounded()))万"
        }
        if tokens >= 1_000 {
            return "\(Int((Double(tokens) / 1_000).rounded()))k"
        }
        return String(tokens)
    }

    private static func ageText(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes == 0 { return "刚刚" }
        if minutes < 60 { return "\(minutes)分钟前" }
        return "\(minutes / 60)小时前"
    }
}

private enum TokenUsageReader {
    static func todayKey() -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: Date())
    }
    static func read(openTokenURL: URL, legacyCacheURL: URL, today: String, runner: BoundedProcess) -> (TokenUsageSnapshot, String?) {
        var failure = "executable_unavailable"
        if FileManager.default.isExecutableFile(atPath: openTokenURL.path) {
            let result = runner.run(executable: openTokenURL.path, arguments: ["preview", "--since", today, "--json"], timeout: 10, stdoutLimit: 4*1024*1024)
            failure = result.failure ?? (result.stdoutTruncated ? "output_limit" : "invalid_output")
            if result.succeeded && !result.stdoutTruncated,
               let object = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
               let rows = object["rows"] as? [[String: Any]] {
                var total: Int64 = 0, valid = true
                for row in rows where row["date"] as? String == today {
                    for key in ["input", "output", "cache_read", "cache_write"] {
                        let value = (row[key] as? NSNumber)?.int64Value ?? 0
                        let sum = total.addingReportingOverflow(max(0,value))
                        if sum.overflow { valid = false } else { total = sum.partialValue }
                    }
                }
                if valid { return (.init(tokens: total, updatedAt: Date(), stale: false), nil) }
                failure = "invalid_total"
            }
        }
        if failure == "cancelled" { return (.unavailable, failure) }
        if let size = try? legacyCacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
           let data = try? Data(contentsOf: legacyCacheURL), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["date"] as? String == today, let tokens = (object["tokens"] as? NSNumber)?.int64Value,
           let timestamp = (object["updatedAt"] as? NSNumber)?.doubleValue, timestamp.isFinite {
            let date = Date(timeIntervalSince1970: timestamp > 1_000_000_000_000 ? timestamp/1000 : timestamp)
            if (0..<600).contains(-date.timeIntervalSinceNow) { return (.init(tokens: max(0,tokens), updatedAt: date, stale: true), failure) }
        }
        return (.unavailable, failure)
    }
}

@MainActor
final class TokenUsageMonitor: NSObject {
    private let cacheFile: URL, openTokenURL: URL
    private var timer: Timer?, runner: BoundedProcess?
    private var enabled = true, generation = 0
    private var nextRefresh: Double = 0
    private var cachedDay = ""
    private let log: MonitorEventLog
    private(set) var snapshot = TokenUsageSnapshot.unavailable
    var onChange: (() -> Void)?
    init(cacheFile: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("touch-bar-agent-status/.state/token-cache.json"),
         openTokenURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opentoken"), eventLog: MonitorEventLog? = nil) {
        self.cacheFile = cacheFile; self.openTokenURL = openTokenURL
        self.log = eventLog ?? MonitorEventLog(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar/token-events.jsonl"))
        super.init()
    }
    func setEnabled(_ value: Bool) {
        if value { enabled = true; start() }
        else { enabled = false; stop(); snapshot = .unavailable }
    }
    func start() {
        guard enabled, timer == nil else { return }
        refresh(force: false)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh(force: false) } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); timer = nil; generation += 1
        runner?.cancel(); runner = nil; nextRefresh = 0
    }
    func refresh(force: Bool = true) {
        guard enabled, runner == nil else { return }
        let day = TokenUsageReader.todayKey()
        if cachedDay != day { snapshot = .unavailable; cachedDay = day; nextRefresh = 0; onChange?() }
        guard force || ProcessInfo.processInfo.systemUptime >= nextRefresh else { return }
        nextRefresh = ProcessInfo.processInfo.systemUptime + 120
        let run = BoundedProcess(); runner = run
        let gen = generation, executable = openTokenURL, cache = cacheFile, began = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (next, error) = TokenUsageReader.read(openTokenURL: executable, legacyCacheURL: cache, today: day, runner: run)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.runner = nil
                self.log.record(error == nil ? "token_refresh_succeeded" : "token_refresh_failed", code: error, fields: ["elapsed_ms":Int((ProcessInfo.processInfo.systemUptime-began)*1000)])
                guard TokenUsageReader.todayKey() == day else { self.snapshot = .unavailable; self.nextRefresh = 0; self.onChange?(); return }
                if next.tokens == nil, let date = self.snapshot.updatedAt, -date.timeIntervalSinceNow < 600 {
                    self.snapshot = .init(tokens: self.snapshot.tokens, updatedAt: date, stale: true)
                } else { self.snapshot = next }
                self.onChange?()
            }
        }
    }
}
