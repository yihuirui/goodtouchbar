import Foundation

public enum MetricLevel: Equatable { case unavailable, normal, warning, critical }
public enum MetricThresholds {
    public static let defaults: [String:[Double]] = [
        "system.cpu":[80,95], "system.memory":[80,90], "system.cpuTemperature":[85,95],
        "system.gpuTemperature":[75,85], "system.batteryTemperature":[40,45],
        "system.fans":[80,95], "system.swap":[2,8]
    ]
    public static let editable = ["system.cpu","system.memory","system.cpuTemperature","system.gpuTemperature","system.batteryTemperature","system.fans","system.swap"]
    public static func valid(_ values: [String:[Double]]) -> Bool {
        values.allSatisfy { key, pair in
            guard defaults[key] != nil, pair.count == 2, pair.allSatisfy({ $0.isFinite && $0 >= 0 }), pair[0] < pair[1] else { return false }
            let maxValue: Double = key == "system.swap" ? 1024 : key.contains("Temperature") ? 125 : 100
            return pair[1] <= maxValue
        }
    }
    public static func level(_ key: String, snapshot: MetricsSnapshot, overrides: [String:[Double]] = [:], now: Date = Date()) -> MetricLevel {
        guard let reading = snapshot.readings[key], reading.isFresh(at:now), let value = reading.value else { return .unavailable }
        if key == MetricID.pressure.rawValue { return value == 4 ? .critical : value == 2 ? .warning : value == 1 ? .normal : .unavailable }
        let normalizedKey = [MetricID.fan0.rawValue,MetricID.fan1.rawValue].contains(key) ? MetricID.fans.rawValue : key
        var scaled = value
        if key == MetricID.memory.rawValue {
            guard let total = snapshot.readings["memory.total"], total.isFresh(at:now), let capacity = total.value, capacity > 0 else { return .unavailable }
            scaled = value / capacity * 100
        } else if key == MetricID.swap.rawValue { scaled = value / 1_073_741_824 }
        else if normalizedKey == MetricID.fans.rawValue {
            let fans = snapshot.fans.filter { key == MetricID.fans.rawValue || key == "system.fan\($0.id)" }
            guard !fans.isEmpty else { return .unavailable }
            var ratios: [Double] = []
            for fan in fans {
                guard let actual = fan.actual, let maximum = fan.maximum, actual.isFinite, actual >= 0, maximum.isFinite, maximum > 0 else { return .unavailable }
                ratios.append(actual / maximum * 100)
            }
            scaled = ratios.max() ?? 0
        }
        let custom = overrides[normalizedKey]
        guard let limits = (custom.map { valid([normalizedKey:$0]) } == true ? custom : defaults[normalizedKey]) else { return .normal }
        return scaled >= limits[1] ? .critical : scaled >= limits[0] ? .warning : .normal
    }
    public static func sensorName(_ key: String) -> String {
        switch key { case CoreTemperature.selection: return "CPU 热区最高温度（Intel 核心／M1 热区）"; case "TC0E": return "CPU 虚拟二极管 · TC0E"; case "TC0F": return "CPU 滤波二极管 · TC0F"; case "TC0P": return "CPU 邻近 · TC0P"; default: return key }
    }
    public static func thermalStateText(_ state: ProcessInfo.ThermalState) -> String {
        switch state { case .nominal:return "系统热压力：正常"; case .fair:return "系统热压力：轻度"; case .serious:return "系统热压力：较高"; case .critical:return "系统热压力：严重"; @unknown default:return "系统热压力：未知" }
    }
}
