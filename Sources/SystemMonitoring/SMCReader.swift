// AppleSMC structure layout adapted from Stats, copyright Serhiy Mytrovtsiy.
// Distributed under MIT; see THIRD-PARTY-NOTICES.md and Licenses/Stats-MIT.txt.
import Foundation
import IOKit

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)
    
    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    
    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    
    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    
    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}


public enum SMCDecode {
    public static func number(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "ui8 ": return bytes.count == 1 ? Double(bytes[0]) : nil
        case "ui16": return bytes.count == 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32": return bytes.count == 4 ? Double(bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) : nil
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << UInt32($1.offset * 8)) }
            let f = Float(bitPattern: bits); return f.isFinite ? Double(f) : nil
        default: return nil
        }
    }
}

/// Read-only SMC connection. Call from a single worker process, never a UI thread.
public final class SMCReader {
    public static let temperatureKeys = ["TC0E", "TC0F", "TC0P", "TG0P", "TB0T"] + CoreTemperature.keys
    private var connection: io_connect_t = 0
    private var cache: [UInt32: SMCKeyData_t.keyInfo_t] = [:]
    public private(set) var error: String?
    public init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { error = "smc_unavailable"; return }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result != KERN_SUCCESS { error = "smc_open_\(result)" }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(_ input: inout SMCKeyData_t, _ output: inout SMCKeyData_t) -> Bool {
        var size = MemoryLayout<SMCKeyData_t>.stride
        return IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCKeyData_t>.stride, &output, &size) == KERN_SUCCESS && output.result == 0
    }
    public func read(_ key: String) -> Double? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var input = SMCKeyData_t(), output = SMCKeyData_t(); input.key = code
        let info: SMCKeyData_t.keyInfo_t
        if let existing = cache[code] { info = existing }
        else {
            input.data8 = 9
            guard call(&input, &output), output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else { return nil }
            info = output.keyInfo; cache[code] = info
        }
        input.keyInfo = info; input.data8 = 5
        guard call(&input, &output) else { cache.removeValue(forKey: code); return nil }
        let type = String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: info.dataType >> $0) }, encoding: .ascii) ?? ""
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCDecode.number(type: type, bytes: bytes)
    }
    public func sample(_ request: SensorRequest) -> SensorResponse {
        var temperatures: [String: MetricReading] = [:]
        for key in Set(request.temperatureKeys).intersection(Self.temperatureKeys) {
            let raw = read(key)
            let value = raw.flatMap { (10...125).contains($0) ? $0 : nil }
            temperatures[key] = MetricReading(value, unit: "°C", source: "AppleSMC \(key)", error: value == nil ? "sensor_unavailable" : nil)
        }
        var fans: [FanReading] = []
        if request.includeFans, let count = read("FNum"), count >= 0, count <= 10, count.rounded() == count {
            let modes = read("FS! ").map(Int.init)
            for id in 0..<Int(count) {
                let maxSpeed = read("F\(id)Mx")
                let actual = read("F\(id)Ac").flatMap { v in v >= 0 && v <= max(20_000, (maxSpeed ?? 0) * 1.1) ? v : nil }
                let modeKey = read("F\(id)Md")
                let mode: String
                if let md = modeKey { mode = md == 0 || md == 3 ? "自动" : md == 1 ? "手动" : "未知" }
                else if let modes { mode = modes & (1 << id) == 0 ? "自动" : "手动" }
                else { mode = "未知" }
                fans.append(FanReading(id: id, actual: actual, minimum: read("F\(id)Mn"), maximum: maxSpeed, target: read("F\(id)Tg"), mode: mode))
            }
        }
        return SensorResponse(requestID: request.requestID, temperatures: temperatures, fans: fans, error: error ?? (request.includeFans && fans.isEmpty ? "fans_unavailable" : nil))
    }
}
