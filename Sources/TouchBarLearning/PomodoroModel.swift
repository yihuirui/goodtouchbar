import Foundation
import os.log

private let pomodoroLogger = Logger(
    subsystem: "io.github.yihuirui.goodtouchbar",
    category: "Pomodoro"
)

@MainActor
final class PomodoroModel: NSObject {
    enum CompletionKind: Equatable {
        case focusFinished
        case restFinished
    }

    enum Phase: String, Codable {
        case focus
        case shortBreak
        case longBreak

        var label: String {
            switch self {
            case .focus: return "专注"
            case .shortBreak: return "短休息"
            case .longBreak: return "长休息"
            }
        }

        var icon: String {
            switch self {
            case .focus: return "🍅"
            case .shortBreak, .longBreak: return "☕"
            }
        }
    }

    private struct PersistedState: Codable {
        let phase: Phase
        let remainingSeconds: Int
        let isRunning: Bool
        let endDate: Date?
        let completedToday: Int
        let totalCompleted: Int
        let statsDayStart: TimeInterval
    }

    static let focusDuration = 25 * 60
    static let shortBreakDuration = 5 * 60
    static let longBreakDuration = 15 * 60

    private(set) var phase: Phase = .focus
    private(set) var remaining = PomodoroModel.focusDuration
    private(set) var isRunning = false
    private(set) var completedToday = 0
    private(set) var totalCompleted = 0

    var onChange: (() -> Void)?
    var onCompletion: ((String, CompletionKind) -> Void)?

    private let fileManager = FileManager.default
    private let stateFileURL: URL
    private let backupStateFileURL: URL
    private var restoreFailed = false
    private var endDate: Date?
    private var statsDayStart: TimeInterval
    private var timer: Timer?

    init(stateFileURL overrideURL: URL? = nil, restoreState: Bool = true) {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let stateFileURL = overrideURL ?? applicationSupport
            .appendingPathComponent("GoodTouchBar", isDirectory: true)
            .appendingPathComponent("pomodoro.json")
        self.stateFileURL = stateFileURL
        backupStateFileURL = stateFileURL.appendingPathExtension("backup")
        statsDayStart = Self.startOfDay(Date()).timeIntervalSince1970
        super.init()
        if restoreState { restore() }
    }

    func toggle() {
        isRunning ? pause() : start()
    }

    func start() {
        refreshDayIfNeeded()
        guard !isRunning else { return }
        if remaining <= 0 || remaining > duration(for: phase) {
            remaining = duration(for: phase)
        }
        beginRunning()
        persist()
        notifyChange()
    }

    func pause() {
        guard isRunning else { return }
        syncTime()
        guard isRunning else { return }
        stopTimer()
        persist()
        notifyChange()
    }

    func reset() {
        stopTimer()
        restoreFailed = false
        phase = .focus
        remaining = Self.focusDuration
        persist()
        notifyChange()
    }

    func startShortBreak() {
        startBreak(.shortBreak)
    }

    func startLongBreak() {
        startBreak(.longBreak)
    }

    func refresh() {
        refreshDayIfNeeded()
        syncTime()
        notifyChange()
    }

    func flush() {
        refreshDayIfNeeded()
        syncTime()
        persist()
    }

    var displayText: String {
        "\(phase.label) \(timeText)"
    }

    var touchBarText: String {
        "\(phase.icon)\(timeText)"
    }

    var compactTouchBarText: String {
        "\(phase.icon)\(timeText)"
    }

    var actionText: String {
        isRunning ? "暂停" : "开始"
    }

    var statsText: String {
        "今日完成 \(completedToday) · 累计 \(totalCompleted)"
    }

    var menuText: String {
        "\(phase.icon) \(phase.label) \(timeText) · \(isRunning ? "暂停" : "开始") · 今日 \(completedToday)"
    }

    var statusBarText: String? {
        guard isRunning else { return nil }
        return "\(phase.icon) \(timeText)"
    }

    var statusBarSummaryText: String {
        "\(phase.icon) \(timeText)"
    }

    private var timeText: String {
        let minutes = max(0, remaining) / 60
        let seconds = max(0, remaining) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startBreak(_ breakPhase: Phase) {
        stopTimer()
        phase = breakPhase
        remaining = duration(for: breakPhase)
        beginRunning()
        persist()
        notifyChange()
    }

    private func duration(for phase: Phase) -> Int {
        switch phase {
        case .focus: return Self.focusDuration
        case .shortBreak: return Self.shortBreakDuration
        case .longBreak: return Self.longBreakDuration
        }
    }

    private func beginRunning() {
        isRunning = true
        endDate = Date().addingTimeInterval(TimeInterval(remaining))
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let newTimer = Timer(
            timeInterval: 1,
            target: self,
            selector: #selector(handleTick),
            userInfo: nil,
            repeats: true
        )
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
    }

    private func stopTimer() {
        isRunning = false
        endDate = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func handleTick() {
        guard isRunning else { return }
        syncTime()
        notifyChange()
    }

    private func syncTime() {
        guard isRunning, let endDate else { return }

        let secondsLeft = Int(ceil(endDate.timeIntervalSinceNow))
        if secondsLeft > 0 {
            remaining = secondsLeft
            return
        }

        finishPhase()
    }

    private func finishPhase() {
        let finishedPhase = phase
        stopTimer()
        remaining = 0

        if finishedPhase == .focus {
            completedToday += 1
            totalCompleted += 1

            let nextPhase: Phase = completedToday.isMultiple(of: 4)
                ? .longBreak
                : .shortBreak
            phase = nextPhase
            remaining = duration(for: nextPhase)
            beginRunning()
            onCompletion?("专注完成，自动开始\(nextPhase.label)", .focusFinished)
        } else {
            phase = .focus
            remaining = Self.focusDuration
            onCompletion?("休息结束，可以开始下一轮专注", .restFinished)
        }

        persist()
    }

    private func restore() {
        if let state = decodeState(at: stateFileURL) {
            apply(state)
            return
        }

        if let state = decodeState(at: backupStateFileURL) {
            pomodoroLogger.notice("Restored Pomodoro state from backup")
            apply(state)
            return
        }

        guard fileManager.fileExists(atPath: stateFileURL.path) else { return }
        restoreFailed = true
        pomodoroLogger.error("Unable to restore Pomodoro state; preserving the existing file")
    }

    private func decodeState(at url: URL) -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PersistedState.self, from: data)
    }

    private func apply(_ state: PersistedState) {
        phase = state.phase
        remaining = max(0, min(state.remainingSeconds, duration(for: state.phase)))
        completedToday = max(0, state.completedToday)
        totalCompleted = max(0, state.totalCompleted)
        statsDayStart = state.statsDayStart
        refreshDayIfNeeded()

        guard state.isRunning else { return }

        if let savedEndDate = state.endDate, savedEndDate > Date() {
            endDate = savedEndDate
            isRunning = true
            scheduleTimer()
        } else {
            isRunning = true
            finishPhase()
        }
    }

    private func refreshDayIfNeeded() {
        let today = Self.startOfDay(Date()).timeIntervalSince1970
        guard statsDayStart != today else { return }
        statsDayStart = today
        completedToday = 0
        persist()
    }

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func persist() {
        guard !restoreFailed else {
            pomodoroLogger.error("Skipping Pomodoro persistence after a failed restore")
            return
        }

        do {
            let directoryURL = stateFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let state = PersistedState(
                phase: phase,
                remainingSeconds: remaining,
                isRunning: isRunning,
                endDate: endDate,
                completedToday: completedToday,
                totalCompleted: totalCompleted,
                statsDayStart: statsDayStart
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)

            if fileManager.fileExists(atPath: stateFileURL.path) {
                try? fileManager.removeItem(at: backupStateFileURL)
                do {
                    try fileManager.copyItem(at: stateFileURL, to: backupStateFileURL)
                } catch {
                    pomodoroLogger.error(
                        "Unable to create Pomodoro backup: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            try data.write(to: stateFileURL, options: .atomic)
        } catch {
            pomodoroLogger.error("Unable to persist state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func notifyChange() {
        onChange?()
    }
}
