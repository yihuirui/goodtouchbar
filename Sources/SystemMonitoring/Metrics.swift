import Foundation

public enum MetricID: String, CaseIterable, Codable {
    case cpu = "system.cpu", memory = "system.memory", pressure = "system.pressure", swap = "system.swap"
    case cpuTemperature = "system.cpuTemperature", gpuTemperature = "system.gpuTemperature", batteryTemperature = "system.batteryTemperature"
    case fans = "system.fans", fan0 = "system.fan0", fan1 = "system.fan1"
    public var name: String {
        switch self {
        case .cpu: return "CPU 使用率"
        case .memory: return "内存已用／总量"
        case .pressure: return "内存压力"
        case .swap: return "交换内存"
        case .cpuTemperature: return "CPU 温度"
        case .gpuTemperature: return "GPU 邻近温度"
        case .batteryTemperature: return "电池温度"
        case .fans: return "风扇转速（合并）"
        case .fan0: return "风扇 1 转速"
        case .fan1: return "风扇 2 转速"
        }
    }
    public var needsSensors: Bool { ![.cpu, .memory, .pressure, .swap].contains(self) }
    public static let performancePreset: [String] = [cpu, memory, cpuTemperature, fans].map(\.rawValue)
}

public struct MetricReading: Codable, Equatable, Sendable {
    public let value: Double?
    public let unit: String
    public let source: String
    public let sampledAt: Date
    public let error: String?
    public init(_ value: Double?, unit: String, source: String, sampledAt: Date = Date(), error: String? = nil) {
        self.value = value?.isFinite == true ? value : nil
        self.unit = unit; self.source = source; self.sampledAt = sampledAt; self.error = error
    }
    public func isFresh(at now: Date = Date(), maxAge: TimeInterval = 12) -> Bool {
        value != nil && now.timeIntervalSince(sampledAt) >= -2 && now.timeIntervalSince(sampledAt) <= maxAge
    }
}

public struct FanReading: Codable, Equatable, Sendable {
    public let id: Int
    public let actual: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let target: Double?
    public let mode: String
    public init(id: Int, actual: Double?, minimum: Double?, maximum: Double?, target: Double?, mode: String) {
        self.id = id; self.actual = actual; self.minimum = minimum; self.maximum = maximum; self.target = target; self.mode = mode
    }
}

public struct SensorRequest: Codable, Sendable {
    public let version: Int
    public let requestID: String
    public let temperatureKeys: [String]
    public let includeFans: Bool
    public init(requestID: String = UUID().uuidString, temperatureKeys: [String], includeFans: Bool) {
        version = 1; self.requestID = requestID; self.temperatureKeys = temperatureKeys; self.includeFans = includeFans
    }
}
public struct SensorResponse: Codable, Sendable {
    public let version: Int
    public let requestID: String
    public let sampledAt: Date
    public let temperatures: [String: MetricReading]
    public let fans: [FanReading]
    public let error: String?
    public init(requestID: String, temperatures: [String: MetricReading], fans: [FanReading], error: String?) {
        version = 1; self.requestID = requestID; sampledAt = Date(); self.temperatures = temperatures; self.fans = fans; self.error = error
    }
}

public struct CPUCounters: Equatable {
    public let user, system, nice, idle: UInt32
    public init(user: UInt32, system: UInt32, nice: UInt32, idle: UInt32) {
        self.user = user; self.system = system; self.nice = nice; self.idle = idle
    }
    public func utilization(since old: CPUCounters?) -> Double? {
        guard let old else { return nil }
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        guard total > 0 else { return nil }
        return min(100, max(0, Double(busy) / Double(total) * 100))
    }
}

public enum MemoryMath {
    public static func used(total: Double, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64, compressed: UInt64, purgeable: UInt64, external: UInt64, pageSize: Double) -> Double? {
        guard total > 0, pageSize > 0 else { return nil }
        let pages = Double(active) + Double(inactive) + Double(speculative) + Double(wired) + Double(compressed) - Double(purgeable) - Double(external)
        let result = pages * pageSize
        guard result >= 0, result <= total else { return nil }
        return result
    }
    public static func pressureName(_ value: Double?) -> String {
        switch value { case 1: return "正常"; case 2: return "偏高"; case 4: return "紧张"; default: return "未知" }
    }
}

public struct MetricsSnapshot {
    public var readings: [String: MetricReading] = [:]
    public var fans: [FanReading] = []
    public var sensorError: String?
    public init() {}
    public func text(for key: String, now: Date = Date()) -> String {
        guard let id = MetricID(rawValue: key) else { return key }
        let label: String
        switch id {
        case .cpu: label = "CPU"
        case .memory: label = "内存"
        case .pressure: label = "压力"
        case .swap: label = "交换"
        case .cpuTemperature: label = "CPU"
        case .gpuTemperature: label = "GPU邻近"
        case .batteryTemperature: label = "电池"
        case .fans: label = "风扇"
        case .fan0: label = "风扇1"
        case .fan1: label = "风扇2"
        }
        guard let r = readings[key], r.isFresh(at: now), let v = r.value else { return "\(label) --" }
        switch id {
        case .cpu: return String(format: "CPU %.0f%%", v)
        case .memory:
            let total = readings["memory.total"]?.value ?? 0
            return String(format: "内存 %.1f/%.0fG", v / 1_073_741_824, total / 1_073_741_824)
        case .pressure: return "压力 \(MemoryMath.pressureName(v))"
        case .swap: return String(format: "交换 %.1fG", v / 1_073_741_824)
        case .cpuTemperature, .gpuTemperature, .batteryTemperature: return String(format: "%@ %.0f°C", label, v)
        case .fans:
            let parts = fans.map { $0.actual.map { String(format: "%.0f", $0) } ?? "--" }
            return "风扇 " + parts.joined(separator: "/")
        case .fan0, .fan1: return String(format: "%@ %.0f", label, v)
        }
    }
}

public enum DisplayLayout {
    public static func unique(_ keys: [String]) -> [String] {
        var seen = Set<String>(); return keys.filter { seen.insert($0).inserted }
    }
    public static func fit(_ keys: [String], budget: Double, moreWidth: Double = 64, width: (String) -> Double) -> (visible: [String], overflow: [String]) {
        let keys = unique(keys)
        let allWidth = keys.reduce(0) { $0 + width($1) } + Double(max(0, keys.count - 1)) * 8
        if allWidth <= budget { return (keys, []) }
        var visible: [String] = [], used = moreWidth
        for (index, key) in keys.enumerated() {
            let next = width(key) + 8
            if used + next > max(moreWidth, budget) { return (visible, Array(keys[index...])) }
            used += next; visible.append(key)
        }
        return (visible, [])
    }
}
