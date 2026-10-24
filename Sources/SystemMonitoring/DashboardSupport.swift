import Foundation
import Darwin

public struct TrendPoint: Codable, Equatable, Sendable {
    public let time: Date
    public let cpu: Double?
    public let memory: Double?
    public let temperature: Double?
}

/// Reuses available samples; does not start a timer or request any sensor.
public struct MetricHistory {
    public private(set) var points: [TrendPoint] = []
    public init() {}
    public mutating func append(_ snapshot: MetricsSnapshot, now: Date = Date()) {
        points.removeAll { now.timeIntervalSince($0.time) > 3600 || $0.time > now }
        guard points.last.map({ now.timeIntervalSince($0.time) >= 10 }) ?? true else { return }
        func fresh(_ key: String) -> Double? {
            guard let r = snapshot.readings[key], r.isFresh(at: now) else { return nil }; return r.value
        }
        let used = fresh(MetricID.memory.rawValue), total = fresh("memory.total")
        let memory = used.flatMap { u in total.flatMap { t in t > 0 ? min(100, max(0, u / t * 100)) : nil } }
        points.append(TrendPoint(time: now, cpu: fresh(MetricID.cpu.rawValue), memory: memory, temperature: fresh(MetricID.cpuTemperature.rawValue)))
        if points.count > 361 { points.removeFirst(points.count - 361) }
    }
}

public struct IncidentTracker {
    public private(set) var active: Set<String> = []
    private var pending: [String: Date] = [:]
    public init() {}
    /// Debounce intermittent failures; recovery removes the active warning immediately.
    public mutating func update(_ conditions: Set<String>, now: Date = Date()) -> (raised: Set<String>, recovered: Set<String>) {
        let recovered = active.subtracting(conditions)
        active.subtract(recovered)
        pending = pending.filter { conditions.contains($0.key) }
        var raised = Set<String>()
        for key in conditions where !active.contains(key) {
            let start = pending[key] ?? now; pending[key] = start
            if key == "fan_recovery_failed" || now.timeIntervalSince(start) >= 10 {
                active.insert(key); raised.insert(key)
            }
        }
        return (raised, recovered)
    }
}

public enum DiagnosticExport {
    public static let fileNames = ["system-monitor-events.jsonl", "fan-client-events.jsonl", "token-events.jsonl", "touchbar-events.jsonl", "wb-retry-events.jsonl"]
    // Fixed event vocabulary. Free-form messages, paths, scripts and session objects are never exported.
    private static let events: Set<String> = ["monitor_started", "monitor_stopped", "sleep", "wake", "mach_failed", "mach_recovered", "sensor_failed", "sensor_recovered", "sensor_process_started", "sensor_sample", "sensor_timeout", "sensor_request_failed", "sensor_samples", "fan_client_started", "fan_client_stopped", "fan_temperature_warning", "fan_temperature_warning_cleared", "fan_service_connected", "fan_service_disconnected", "fan_control_requested", "fan_control_confirmed", "fan_control_failed", "fan_install_requested", "fan_install_completed", "fan_install_failed", "fan_uninstall_requested", "fan_uninstall_completed", "fan_uninstall_failed", "token_sample", "token_failed", "token_completed", "presentation_failed", "presentation_paused", "presentation_recovery_paused", "token_refresh_succeeded", "token_refresh_failed", "sensor_request_timedOut", "sensor_request_invalidResponse", "sensor_request_timeout", "sensor_request_invalid_response", "sensor_request_cancelled", "sensor_request_unavailable", "presentation_recovered", "retry_clicked", "retry_confirmed", "retry_failed"]
    private static let codes: Set<String> = ["fixed", "boost", "automatic", "release", "sleep", "hardware_write_failed", "write_readback_failed", "restore_not_confirmed", "temperature_high", "temperature_normal", "temperature_unavailable", "temperature_unavailable_or_high", "hardware_unavailable", "invalid_target_or_limits", "fan_limits_unavailable", "lease_not_owned", "fan_not_owned", "fan_already_controlled", "recovery_required", "request_capacity_reached", "sensor_service_failed", "timedOut", "cancelled", "invalidResponse", "unavailable", "ok"]
    public static func sanitizedEvents(_ data: Data) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return data.split(separator: 10).suffix(200).compactMap { line in
            guard line.count <= 16_384,
                  let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let event = record["event"] as? String, events.contains(event) else { return nil }
            var result: [String: Any] = ["event": event]
            if let time = record["time"] as? String, formatter.date(from: time) != nil { result["time"] = time }
            if let id = record["requestID"] as? String, UUID(uuidString: id) != nil { result["requestID"] = id }
            if let code = record["code"] as? String, codes.contains(code) { result["code"] = code }
            for key in ["build", "elapsed_ms", "launches", "samples", "attempts"] {
                if let n = record[key] as? NSNumber, n.doubleValue.isFinite, abs(n.doubleValue) <= 1_000_000_000 { result[key] = n }
            }
            return result
        }
    }
    public static func collectLogs(directory: URL) -> [String: Any] {
        var result: [String: Any] = [:]
        let dir = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return ["availability": "log_directory_unavailable"] }
        defer { close(dir) }
        for name in fileNames {
            let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { result[name] = ["availability": "unavailable"]; continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
                result[name] = ["availability": "unsupported_file"]; continue
            }
            let length = min(131_072, max(0, Int(info.st_size)))
            var bytes = [UInt8](repeating: 0, count: length)
            let count = pread(fd, &bytes, length, max(0, info.st_size - off_t(length)))
            guard count >= 0 else { continue }
            result[name] = sanitizedEvents(Data(bytes.prefix(count)))
        }
        return result
    }
}
