import Foundation
import Darwin

/// Aggregate fresh per-core readings only. Never substitute a diode/proximity value.
public enum CoreTemperature {
    public static let selection = "cpu.coreMax"
    public static let intelKeys = (0...9).flatMap { ["TC\($0)C", "TC\($0)c"] }
    public static let m1ThermalZoneKeys = ["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]
    public static let m1GPUThermalZoneKeys = ["Tg05", "Tg0D", "Tg0L", "Tg0T"]

    public static var chip: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }

    public static var keys: [String] {
        cpuKeys(capabilities: .current, chipName: chip)
    }

    public static var gpuKeys: [String] {
        gpuKeys(capabilities: .current, chipName: chip)
    }

    public static func cpuKeys(capabilities: GoodTouchBarDeviceCapabilities, chipName: String) -> [String] {
        if capabilities.hostSupportsArm64 == true {
            return chipName.hasPrefix("Apple M1") ? m1ThermalZoneKeys : []
        }
        guard capabilities.canUseIntelFanHelper else { return [] }
        return intelKeys
    }

    public static func gpuKeys(capabilities: GoodTouchBarDeviceCapabilities, chipName: String) -> [String] {
        capabilities.hostSupportsArm64 == true && chipName.hasPrefix("Apple M1")
            ? m1GPUThermalZoneKeys : []
    }
    public struct Summary {
        public let maximum: MetricReading
        public let average: MetricReading
        public let count: Int
    }
    public static func summarize(_ readings: [String:MetricReading], now: Date = Date()) -> Summary {
        summarize(readings, keys: keys, now: now)
    }

    public static func summarize(_ readings: [String:MetricReading], keys: [String], now: Date = Date()) -> Summary {
        func isUsable(_ reading: MetricReading) -> Bool {
            reading.isFresh(at: now) && reading.error == nil
                && reading.value.map { (10...125).contains($0) } == true
        }
        let valid: [MetricReading]
        if keys == intelKeys {
            // AppleSMC exposes the same per-core value with upper/lower-case
            // aliases on some machines. Prefer the canonical uppercase key,
            // falling back only when it is unavailable or stale.
            valid = stride(from: 0, to: intelKeys.count, by: 2).compactMap { index in
                let pair = intelKeys[index..<min(index + 2, intelKeys.count)]
                return pair.compactMap { readings[$0] }.first(where: isUsable)
            }
        } else {
            valid = keys.compactMap { readings[$0] }.filter(isUsable)
        }
        let values = valid.compactMap(\.value)
        let date = valid.map(\.sampledAt).min() ?? now
        let error = values.isEmpty ? "core_temperature_unavailable" : nil
        let source = keys.contains(where: { $0.hasPrefix("Tp") }) ? "AppleSMC CPU thermal zones" : "AppleSMC CPU cores"
        return Summary(maximum:MetricReading(values.max(),unit:"°C",source:source + " max",sampledAt:date,error:error),
                       average:MetricReading(values.isEmpty ? nil : values.reduce(0,+) / Double(values.count),unit:"°C",source:source + " average",sampledAt:date,error:error),count:values.count)
    }
    /// One-time, user-requested upgrade; later manual sensor/threshold choices remain intact.
    public static func migratedConfiguration(_ object: [String:Any]) -> [String:Any] {
        guard (object["coreTemperatureDisplayVersion"] as? Int ?? 0) < 1 else { return object }
        var result = object
        result["coreTemperatureDisplayVersion"] = 1
        result["cpuTemperatureKey"] = selection
        var thresholds = result["metricThresholds"] as? [String:Any] ?? [:]
        thresholds["system.cpuTemperature"] = [85,95]
        result["metricThresholds"] = thresholds
        return result
    }
}

public enum CPUPowerStatus {
    public static let speedKey = "cpu.speedLimit"
    public static let schedulerKey = "cpu.schedulerLimit"
    public static let countKey = "cpu.availableCPUs"
    public static func text(_ readings: [String:MetricReading], now: Date = Date()) -> String {
        func fresh(_ key:String) -> Double? {
            guard let r = readings[key], r.isFresh(at:now), let v = r.value, v >= 0, v <= 100 else { return nil }
            return v
        }
        guard let speed = fresh(speedKey) else { return "系统性能限制：未知" }
        let scheduler = fresh(schedulerKey)
        let limited = speed < 100 || scheduler.map { $0 < 100 } == true
        let state = limited ? "已报告限制" : scheduler == 100 ? "未报告速度／调度限制" : "速度无限制，调度未知"
        var text = "系统性能：\(state) · 速度上限 \(Int(speed))%"
        if let scheduler, scheduler < 100 { text += " · 调度 \(Int(scheduler))%" }
        return text
    }
}
