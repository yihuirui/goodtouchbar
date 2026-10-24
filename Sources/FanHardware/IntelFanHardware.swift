// AppleSMC ABI layout adapted from Stats (MIT), copyright Serhiy Mytrovtsiy.
// See Licenses/Stats-MIT.txt. Exposes fan operations only; no arbitrary public key writer.
import Foundation
import IOKit
import FanControlCore
import SystemMonitoring

internal struct FanSMCData {
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


public enum FanHardwareError: FanDiagnosticError {
    case unsupportedArchitecture, unavailable, invalidKey, invalidMetadata, io(Int32), smc(UInt8)
    case unsupportedFanMode, invalidFan, invalidBounds, invalidTarget, verificationFailed
    public var diagnosticCode: String {
        switch self {
        case .io(let code): return "iokit_\(code)"
        case .smc(let code): return "smc_\(code)"
        case .unsupportedArchitecture: return "unsupported_architecture"
        case .unavailable: return "unavailable"
        case .invalidKey: return "invalid_key"
        case .invalidMetadata: return "invalid_metadata"
        case .unsupportedFanMode: return "unsupported_fan_mode"
        case .invalidFan: return "invalid_fan"
        case .invalidBounds: return "invalid_bounds"
        case .invalidTarget: return "invalid_target"
        case .verificationFailed: return "readback_mismatch"
        }
    }
}

private struct FanSMCOperationError: FanDiagnosticError { let diagnosticCode: String }

private struct FanSMCValue {
    let key: UInt32
    let type: String
    let size: Int
    var bytes: [UInt8]
    var number: Double? { SMCDecode.number(type: type, bytes: bytes) }
}

/// Serialize all calls on the helper control queue. No methods shell out or execute caller paths.
public final class IntelFanHardware: FanControlCore.FanHardware {
    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: FanSMCData.keyInfo_t] = [:]
    private var gpuChipKeys: [String] = []
    public init() throws {
        #if !arch(x86_64)
        throw FanHardwareError.unsupportedArchitecture
        #else
        guard GoodTouchBarDeviceCapabilities.current.canUseIntelFanHelper else {
            throw FanHardwareError.unsupportedArchitecture
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanHardwareError.unavailable }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw FanHardwareError.io(result) }
        // Bind chip sensors once for this connection. A present-but-currently-invalid
        // sensor stays bound and prevents control until its reading is valid again.
        gpuChipKeys = ["TCGC","TGDD","TG0D"].filter { (try? value($0)) != nil }
        #endif
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(_ input: inout FanSMCData) throws -> FanSMCData {
        var output = FanSMCData(), size = MemoryLayout<FanSMCData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<FanSMCData>.stride, &output, &size)
        let key = String(bytes:[24,16,8,0].map { UInt8(truncatingIfNeeded:input.key >> $0) },encoding:.ascii) ?? "unknown"
        let operation = input.data8 == 6 ? "write" : input.data8 == 9 ? "metadata" : "read"
        guard result == KERN_SUCCESS else { throw FanSMCOperationError(diagnosticCode:"\(key):\(operation):iokit_\(result)") }
        guard size >= MemoryLayout<FanSMCData>.size else { throw FanSMCOperationError(diagnosticCode:"\(key):\(operation):short_response") }
        guard output.result == 0 else { throw FanSMCOperationError(diagnosticCode:"\(key):\(operation):smc_\(output.result)") }
        return output
    }
    private func value(_ key: String) throws -> FanSMCValue {
        guard key.utf8.count == 4 else { throw FanHardwareError.invalidKey }
        let code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var input = FanSMCData(); input.key = code
        let info: FanSMCData.keyInfo_t
        if let cached = infoCache[code] { info = cached }
        else {
            input.data8 = 9
            let result = try call(&input)
            guard result.keyInfo.dataSize > 0, result.keyInfo.dataSize <= 32 else { throw FanHardwareError.invalidMetadata }
            info = result.keyInfo; infoCache[code] = info
        }
        input.keyInfo = info; input.data8 = 5
        let output: FanSMCData
        do { output = try call(&input) } catch { infoCache.removeValue(forKey: code); throw error }
        let type = String(bytes: [24,16,8,0].map { UInt8(truncatingIfNeeded: info.dataType >> $0) }, encoding: .ascii) ?? ""
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return FanSMCValue(key: code, type: type, size: Int(info.dataSize), bytes: bytes)
    }
    private func writeFan(_ value: FanSMCValue) throws {
        // This private method can only be reached through typed fan operations below.
        guard GoodTouchBarDeviceCapabilities.current.canUseIntelFanHelper else {
            throw FanHardwareError.unsupportedArchitecture
        }
        guard value.size > 0, value.size <= 32, value.bytes.count == value.size else { throw FanHardwareError.invalidMetadata }
        var input = FanSMCData(); input.key = value.key; input.keyInfo.dataSize = UInt32(value.size); input.data8 = 6
        withUnsafeMutableBytes(of: &input.bytes) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: value.bytes)
        }
        _ = try call(&input)
    }
    private func validateID(_ id: Int) throws {
        guard (0...9).contains(id), let count = try value("FNum").number,
              count.rounded() == count, count >= 1, count <= 10, id < Int(count) else { throw FanHardwareError.invalidFan }
    }
    public func snapshot() throws -> FanHardwareSnapshot {
        let sampledAt = ProcessInfo.processInfo.systemUptime
        guard let count = try value("FNum").number, count.rounded() == count, count >= 1, count <= 10 else { throw FanHardwareError.invalidFan }
        let modeMask = try? value("FS! ")
        var fans: [FanDeviceReading] = []
        for id in 0..<Int(count) {
            let md = try? value("F\(id)Md")
            let automatic: Bool?
            if let mask = modeMask?.number, mask >= 0, mask <= 65_535, let mdValue = md?.number, [0,1,3].contains(mdValue) {
                let maskAutomatic = Int(mask) & (1 << id) == 0
                let mdAutomatic = mdValue == 0 || mdValue == 3
                automatic = maskAutomatic == mdAutomatic ? maskAutomatic : nil
            } else if let mask = modeMask?.number, mask >= 0, mask <= 65_535 {
                automatic = Int(mask) & (1 << id) == 0
            } else if let mode = md?.number, [0,1,3].contains(mode) { automatic = mode != 1 }
            else { automatic = nil }
            let actual = try? value("F\(id)Ac").number
            let minimum = try? value("F\(id)Mn").number
            let maximum = try? value("F\(id)Mx").number
            let target = try? value("F\(id)Tg").number
            fans.append(FanDeviceReading(id: id, actualRPM: actual, minimumRPM: minimum, maximumRPM: maximum, targetRPM: target, automatic: automatic))
        }
        // Do not silently switch the identity of the CPU safety sensor between reads.
        let cpu = (try? value("TC0E").number).flatMap { (10...125).contains($0) ? $0 : nil }
        var gpuReadings: [Double] = [], validGPU = !gpuChipKeys.isEmpty
        for key in gpuChipKeys {
            if let reading = try? value(key).number, reading.isFinite, (10...125).contains(reading) { gpuReadings.append(reading) }
            else { validGPU = false }
        }
        let gpu = validGPU ? gpuReadings.max() : nil
        return FanHardwareSnapshot(fans: fans, cpuTemperature: cpu, gpuTemperature: gpu, sampledUptime: sampledAt)
    }
    public func setTarget(id: Int, rpm: Double) throws {
        try validateID(id)
        guard let minimum = try value("F\(id)Mn").number, let maximum = try value("F\(id)Mx").number,
              minimum.isFinite, maximum.isFinite, minimum > 0, minimum < maximum, maximum <= 20_000 else { throw FanHardwareError.invalidBounds }
        guard rpm.isFinite, rpm >= minimum, rpm <= maximum else { throw FanHardwareError.invalidTarget }
        var target = try value("F\(id)Tg")
        target.bytes = try FanEncoding.target(rpm: rpm, type: target.type, size: target.size)
        try writeFan(target)
        guard let readback = try value("F\(id)Tg").number, abs(readback - rpm) <= 1 else { throw FanHardwareError.verificationFailed }
    }
    public func setManual(id: Int) throws { try setMode(id: id, manual: true) }
    public func setAutomatic(id: Int) throws { try setMode(id: id, manual: false) }
    private func setMode(id: Int, manual: Bool) throws {
        try validateID(id)
        // Update every available Intel control mechanism; never change another fan's bit.
        let md = try? value("F\(id)Md")
        let mask = try? value("FS! ")
        guard md != nil || mask != nil else { throw FanHardwareError.unsupportedFanMode }
        if var md {
            guard md.type == "ui8 ", md.size == 1 else { throw FanHardwareError.invalidMetadata }
            md.bytes = [manual ? 1 : 0]; try writeFan(md)
        }
        if var mask {
            guard mask.type == "ui16", mask.size == 2, let raw = mask.number, raw >= 0, raw <= 65_535 else { throw FanHardwareError.invalidMetadata }
            let result = try FanEncoding.modeMask(UInt16(raw), fanID: id, manual: manual)
            mask.bytes = [UInt8(result >> 8), UInt8(result & 0xff)]; try writeFan(mask)
        }
        if md != nil {
            guard let readback = try value("F\(id)Md").number, manual ? readback == 1 : (readback == 0 || readback == 3) else { throw FanHardwareError.verificationFailed }
        }
        if mask != nil {
            guard let readback = try value("FS! ").number, readback >= 0, readback <= 65_535,
                  (Int(readback) & (1 << id) != 0) == manual else { throw FanHardwareError.verificationFailed }
        }
    }
}
