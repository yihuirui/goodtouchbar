import Foundation

public enum FanControlAction: String, Codable, Sendable {
    case status, fixed, boost, automatic, heartbeat, release, sleep
}

public struct FanControlRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let action: FanControlAction
    public let targets: [Int: Double]
    public let leaseID: String?
    public init(action: FanControlAction, targets: [Int: Double] = [:], leaseID: String? = nil, requestID: String = UUID().uuidString, protocolVersion: Int = 1) {
        self.protocolVersion = protocolVersion; self.requestID = requestID; self.action = action
        self.targets = targets; self.leaseID = leaseID
    }
}

public struct FanDeviceReading: Codable, Equatable, Sendable {
    public let id: Int
    public let actualRPM: Double?
    public let minimumRPM: Double?
    public let maximumRPM: Double?
    public let targetRPM: Double?
    public let automatic: Bool?
    public init(id: Int, actualRPM: Double?, minimumRPM: Double?, maximumRPM: Double?, targetRPM: Double?, automatic: Bool?) {
        self.id = id; self.actualRPM = actualRPM; self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM; self.targetRPM = targetRPM; self.automatic = automatic
    }
}

public struct FanHardwareSnapshot: Codable, Equatable, Sendable {
    public let fans: [FanDeviceReading]
    public let cpuTemperature: Double?
    public let gpuTemperature: Double?
    public let sampledUptime: Double
    public init(fans: [FanDeviceReading], cpuTemperature: Double?, gpuTemperature: Double?, sampledUptime: Double) {
        self.fans = fans; self.cpuTemperature = cpuTemperature; self.gpuTemperature = gpuTemperature; self.sampledUptime = sampledUptime
    }
}

public protocol FanDiagnosticError: Error { var diagnosticCode: String { get } }

public protocol FanHardware: AnyObject {
    func snapshot() throws -> FanHardwareSnapshot
    func setTarget(id: Int, rpm: Double) throws
    func setManual(id: Int) throws
    func setAutomatic(id: Int) throws
}

public enum FanControlPhase: String, Codable, Sendable {
    case automatic, controlling, recovering, recoveryFailed
}

public struct FanControlStatus: Codable, Equatable, Sendable {
    public let phase: FanControlPhase
    public let leaseID: String?
    public let ownedFanIDs: [Int]
    public let targets: [Int: Double]
    public let leaseExpiresAt: Double?
    public let boostExpiresAt: Double?
    public let fans: [FanDeviceReading]
    public let cpuTemperature: Double?
    public let gpuTemperature: Double?
    public let error: String?
    public let generation: UInt64
    public let hardwareDiagnostic: String?
    public init(phase: FanControlPhase = .automatic, leaseID: String? = nil, ownedFanIDs: [Int] = [], targets: [Int: Double] = [:], leaseExpiresAt: Double? = nil, boostExpiresAt: Double? = nil, fans: [FanDeviceReading] = [], cpuTemperature: Double? = nil, gpuTemperature: Double? = nil, error: String? = nil, generation: UInt64 = 0, hardwareDiagnostic: String? = nil) {
        self.phase = phase; self.leaseID = leaseID; self.ownedFanIDs = ownedFanIDs; self.targets = targets
        self.leaseExpiresAt = leaseExpiresAt; self.boostExpiresAt = boostExpiresAt; self.fans = fans
        self.cpuTemperature = cpuTemperature; self.gpuTemperature = gpuTemperature; self.error = error; self.generation = generation; self.hardwareDiagnostic = hardwareDiagnostic
    }
}

public extension FanControlStatus {
    /// Advisory only: high temperature does not deny or end a fixed-RPM lease.
    var temperatureWarning: String? {
        guard [cpuTemperature,gpuTemperature].contains(where: { $0.map { $0.isFinite && $0 >= 95 && $0 <= 125 } == true }) else { return nil }
        return "温度较高（≥95°C），建议提高转速或恢复自动；高温不会阻止设置或取消固定转速。"
    }
}

public struct FanControlReply: Codable, Equatable, Sendable {
    public let requestID: String
    public let ok: Bool
    public let code: String
    public let status: FanControlStatus
    public init(ok: Bool, code: String, status: FanControlStatus, requestID: String = "") { self.requestID = requestID; self.ok = ok; self.code = code; self.status = status }
}

public struct FanControlEvent: Codable, Sendable {
    public let requestID: String?
    public let stage: String?
    public let fanID: Int?
    public let hardwareError: String?
    public let event: String
    public let code: String?
    public let fanIDs: [Int]
    public let targets: [Int: Double]
    public let generation: UInt64
    public init(event: String, code: String? = nil, fanIDs: [Int] = [], targets: [Int: Double] = [:], generation: UInt64 = 0, requestID: String? = nil, stage: String? = nil, fanID: Int? = nil, hardwareError: String? = nil) {
        self.requestID = requestID; self.stage = stage; self.fanID = fanID; self.hardwareError = hardwareError
        self.event = event; self.code = code; self.fanIDs = fanIDs; self.targets = targets; self.generation = generation
    }
}
