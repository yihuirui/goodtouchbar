import Foundation

/// State machine owned by the Helper's serial control queue. The independent Helper
/// watchdog must restart a blocked hardware process; this class does not claim that
/// Swift can cancel a synchronous IOKit call.
public final class FanControlEngine {
    private let hardware: any FanHardware
    private let eventSink: (FanControlEvent) -> Void
    private let ownershipSink: ([Int]) throws -> Void
    private let leaseDuration: Double = 10
    private let boostDuration: Double = 300
    private var phase: FanControlPhase = .automatic
    private var owner: String?
    private var leaseID: String?
    private var owned = Set<Int>()
    private var targets: [Int: Double] = [:]
    private var leaseDeadline: Double?
    private var boostDeadline: Double?
    private var snapshot: FanHardwareSnapshot?
    private var hardwareUnavailable = false
    private var temperatureWarningActive = false
    private var errorCode: String?
    private var generation: UInt64 = 0
    private var lastNow: Double = 0
    private var requestContext: String?
    private var lastHardwareDiagnostic: String?
    private var recoveryAttempts = 0
    private var nextRecoveryAt: Double?
    private struct PriorRequest { let request: FanControlRequest; let ok: Bool; let code: String }
    // Cache mutating requests for the whole daemon run. Refuse excess commands rather
    // than evicting old IDs and accidentally reapplying a delayed manual command.
    private var priorRequests: [String: PriorRequest] = [:]
    private let maximumRememberedRequests = 1024

    public init(hardware: any FanHardware, eventSink: @escaping (FanControlEvent) -> Void = { _ in }, ownershipSink: @escaping ([Int]) throws -> Void = { _ in }) {
        self.hardware = hardware; self.eventSink = eventSink; self.ownershipSink = ownershipSink
    }

    public func handle(_ request: FanControlRequest, clientID: String, now: Double) -> FanControlReply {
        guard request.protocolVersion == 1, UUID(uuidString: request.requestID) != nil,
              !clientID.isEmpty, clientID.utf8.count <= 256 else {
            return reply(false, "invalid_request", request)
        }
        requestContext = request.requestID
        defer { requestContext = nil }
        guard acceptClock(now) else { return reply(false, "invalid_clock", request) }
        advance(now: now)
        let mutating = ![FanControlAction.status, .heartbeat].contains(request.action)
        let cacheKey = clientID + ":" + request.requestID
        if let prior = priorRequests[cacheKey] {
            guard prior.request == request else { return reply(false, "request_id_reused", request) }
            // Return present state, never a cached controlling state after a lease expired.
            return reply(prior.ok, "duplicate_" + prior.code, request)
        }
        let releasing = [FanControlAction.automatic, .release, .sleep].contains(request.action)
        if mutating && !releasing && priorRequests.count >= maximumRememberedRequests {
            return reply(false, "request_capacity_reached", request)
        }
        let result: FanControlReply
        switch request.action {
        case .status:
            result = reply(phase != .recoveryFailed && !hardwareUnavailable, hardwareUnavailable ? "hardware_unavailable" : (errorCode ?? "status"), request)
        case .heartbeat:
            guard phase == .controlling, !owned.isEmpty, owner == clientID,
                  request.leaseID == leaseID, let deadline = leaseDeadline, now < deadline else {
                return reply(false, "lease_not_active", request)
            }
            leaseDeadline = now + leaseDuration
            generation &+= 1
            result = reply(true, "lease_renewed", request)
        case .automatic, .release, .sleep:
            guard owned.isEmpty || (owner == clientID && request.leaseID == leaseID) || owner == nil else {
                result = reply(false, "lease_not_owned", request)
                break
            }
            if owned.isEmpty {
                if request.action == .automatic {
                    if hardwareUnavailable || snapshot?.fans.isEmpty != false {
                        result = reply(false, "hardware_unavailable", request)
                    } else if snapshot?.fans.allSatisfy({ $0.automatic == true }) != true {
                        result = reply(false, "fan_not_owned", request)
                    } else {
                        errorCode = nil
                        result = reply(true, "automatic", request)
                    }
                } else { result = reply(true, "not_controlling", request) }
            } else {
                restore(now: now, reason: request.action == .sleep ? "sleep" : "user_release", resetAttempts: true)
                result = reply(owned.isEmpty, owned.isEmpty ? "automatic" : "recovery_failed", request)
            }
        case .fixed, .boost:
            result = start(request, clientID: clientID, now: now)
        }
        if mutating && priorRequests.count < maximumRememberedRequests { priorRequests[cacheKey] = PriorRequest(request: request, ok: result.ok, code: result.code) }
        return result
    }

    @discardableResult
    public func tick(now: Double) -> FanControlStatus {
        if acceptClock(now) { advance(now: now) }
        return status()
    }

    @discardableResult
    public func clientDisconnected(clientID: String, now: Double) -> FanControlStatus {
        let safeNow = now.isFinite && now >= lastNow ? now : lastNow
        if owner == clientID && !owned.isEmpty { restore(now: safeNow, reason: "client_disconnected", resetAttempts: true) }
        return status()
    }

    /// Called only for IDs loaded from the root-owned outstanding-control marker.
    /// No marker means no automatic write to a fan controlled by another application.
    @discardableResult
    public func recover(fanIDs: [Int], now: Double) -> FanControlStatus {
        let valid = Set(fanIDs.filter { (0...9).contains($0) })
        guard valid.count == Set(fanIDs).count else {
            phase = .recoveryFailed; errorCode = "invalid_recovery_marker"; return status()
        }
        guard !valid.isEmpty else { return status() }
        guard now.isFinite, now >= 0 else { errorCode = "invalid_clock"; return status() }
        lastNow = max(lastNow, now)
        owned.formUnion(valid)
        owner = nil; leaseID = nil; leaseDeadline = nil; boostDeadline = nil
        restore(now: now, reason: "startup_recovery", resetAttempts: true)
        return status()
    }

    public func currentStatus() -> FanControlStatus { status() }

    private func acceptClock(_ now: Double) -> Bool {
        guard now.isFinite, now >= 0, now >= lastNow else {
            if !owned.isEmpty { restore(now: lastNow, reason: "invalid_clock", resetAttempts: true) }
            errorCode = "invalid_clock"
            return false
        }
        lastNow = now; return true
    }

    private func refresh(now: Double) -> Bool {
        do {
            let value = try hardware.snapshot()
            guard value.sampledUptime.isFinite, value.sampledUptime >= 0,
                  now - value.sampledUptime >= -1, now - value.sampledUptime <= 3,
                  value.fans.count <= 10, Set(value.fans.map(\.id)).count == value.fans.count,
                  value.fans.allSatisfy({ (0...9).contains($0.id) }) else {
                snapshot = nil; hardwareUnavailable = true; return false
            }
            snapshot = value; hardwareUnavailable = false
            let warning = [value.cpuTemperature,value.gpuTemperature].contains { $0.map { $0.isFinite && $0 >= 95 && $0 <= 125 } == true }
            if warning != temperatureWarningActive {
                temperatureWarningActive = warning
                emit(warning ? "temperature_warning" : "temperature_warning_cleared",code:warning ? "temperature_high" : "temperature_normal")
            }
            return true
        } catch { snapshot = nil; hardwareUnavailable = true; return false }
    }

    private func temperaturesValid() -> Bool {
        guard let cpu = snapshot?.cpuTemperature, let gpu = snapshot?.gpuTemperature,
              cpu.isFinite, gpu.isFinite, (10...125).contains(cpu), (10...125).contains(gpu) else { return false }
        return true
    }

    private func advance(now: Double) {
        if phase == .recoveryFailed || phase == .recovering {
            if let next = nextRecoveryAt, now >= next, recoveryAttempts < 3 {
                restore(now: now, reason: errorCode ?? "recovery_retry", resetAttempts: false)
            } else { _ = refresh(now: now) }
            return
        }
        guard !owned.isEmpty else { _ = refresh(now: now); return }
        if let deadline = leaseDeadline, now >= deadline {
            restore(now: now, reason: "lease_expired", resetAttempts: true); return
        }
        if let deadline = boostDeadline, now >= deadline {
            restore(now: now, reason: "boost_expired", resetAttempts: true); return
        }
        guard refresh(now: now) else { restore(now: now, reason: "hardware_unavailable", resetAttempts: true); return }
        guard temperaturesValid() else {
            restore(now: now, reason: "temperature_unavailable", resetAttempts: true); return
        }
        guard controlledTargetsMatch() else {
            restore(now: now, reason: "external_control_or_readback_changed", resetAttempts: true); return
        }
    }

    private func bounded(_ fan: FanDeviceReading) -> Bool {
        guard let low = fan.minimumRPM, let high = fan.maximumRPM,
              low.isFinite, high.isFinite, low > 0, high >= low, high <= 16383,
              let actual = fan.actualRPM, actual.isFinite, actual >= 0, actual <= high * 1.25 + 100 else { return false }
        return true
    }

    private func controlledTargetsMatch() -> Bool {
        guard let snapshot else { return false }
        for id in owned {
            guard let fan = snapshot.fans.first(where: { $0.id == id }), bounded(fan), fan.automatic == false,
                  let target = fan.targetRPM, target.isFinite, let wanted = targets[id], abs(target - wanted) <= 1 else { return false }
        }
        return true
    }

    private func start(_ request: FanControlRequest, clientID: String, now: Double) -> FanControlReply {
        guard phase != .recoveryFailed && phase != .recovering else { return reply(false, "recovery_required", request) }
        guard owned.isEmpty || (owner == clientID && request.leaseID == leaseID) else { return reply(false, "lease_not_owned", request) }
        guard !owned.isEmpty || request.leaseID == nil else { return reply(false, "lease_not_active", request) }
        guard refresh(now: now), let snapshot, !snapshot.fans.isEmpty else { return reply(false, "hardware_unavailable", request) }
        guard temperaturesValid() else { return reply(false, "temperature_unavailable", request) }
        var wanted = targets
        if request.action == .boost {
            guard request.targets.isEmpty else { return reply(false, "invalid_targets", request) }
            wanted = [:]
            for fan in snapshot.fans {
                guard bounded(fan), let maximum = fan.maximumRPM else { return reply(false, "fan_limits_unavailable", request) }
                wanted[fan.id] = maximum.rounded(.down)
            }
        } else {
            guard !request.targets.isEmpty, request.targets.count <= 10 else { return reply(false, "invalid_targets", request) }
            for (id, rpm) in request.targets { wanted[id] = rpm }
        }
        for (id, rpm) in wanted {
            guard let fan = snapshot.fans.first(where: { $0.id == id }), bounded(fan),
                  rpm.isFinite, rpm.rounded() == rpm, let low = fan.minimumRPM, let high = fan.maximumRPM,
                  rpm >= low, rpm <= high else { return reply(false, "invalid_target_or_limits", request) }
            if !owned.contains(id) && fan.automatic != true { return reply(false, "fan_already_controlled", request) }
        }
        let nextOwned = owned.union(wanted.keys)
        do { try ownershipSink(nextOwned.sorted()) }
        catch { return reply(false, "ownership_persistence_failed", request) }
        owned = nextOwned; targets = wanted
        owner = clientID
        if leaseID == nil { leaseID = UUID().uuidString }
        leaseDeadline = now + leaseDuration
        boostDeadline = request.action == .boost ? now + boostDuration : nil
        phase = .controlling; errorCode = nil; lastHardwareDiagnostic = nil; recoveryAttempts = 0; nextRecoveryAt = nil; generation &+= 1
        emit("control_requested", code: request.action.rawValue)
        var writeStage = "setManual", writeFanID: Int?
        do {
            for id in wanted.keys.sorted() {
                guard let rpm = wanted[id] else { continue }
                // Automatic control may reject or overwrite the target register.
                // Take ownership first; the durable marker already covers partial failure.
                writeFanID = id; writeStage = "setManual"
                try hardware.setManual(id: id)
                writeStage = "setTarget"; try hardware.setTarget(id: id, rpm: rpm)
            }
            guard refresh(now: now), temperaturesValid(), controlledTargetsMatch() else {
                diagnostic(stage: "readback", fanID: nil, code: "state_mismatch")
                restore(now: now, reason: "write_readback_failed", resetAttempts: true)
                return reply(false, "write_readback_failed", request)
            }
            emit("control_confirmed", code: request.action.rawValue)
            return reply(true, request.action == .boost ? "boost_started" : "fixed_started", request)
        } catch {
            diagnostic(stage: writeStage, fanID: writeFanID, code: (error as? FanDiagnosticError)?.diagnosticCode ?? "hardware_error")
            restore(now: now, reason: "hardware_write_failed", resetAttempts: true)
            return reply(false, "hardware_write_failed", request)
        }
    }

    private func restore(now: Double, reason: String, resetAttempts: Bool) {
        guard !owned.isEmpty else { return }
        if resetAttempts { recoveryAttempts = 0 }
        recoveryAttempts += 1; phase = .recovering
        // Recovery ends the active lease. Keep the durable fan IDs until readback
        // succeeds, but allow any authenticated connection to retry releasing them.
        // The original connection may already be gone or have dropped its lease.
        owner = nil; leaseID = nil
        leaseDeadline = nil; boostDeadline = nil; generation &+= 1
        emit("restore_requested", code: reason)
        for id in owned.sorted() {
            do { try hardware.setAutomatic(id: id) }
            catch { diagnostic(stage: "setAutomatic", fanID: id, code: (error as? FanDiagnosticError)?.diagnosticCode ?? "hardware_error") }
        }
        let readBack = refresh(now: now)
        let confirmed = readBack && owned.allSatisfy { id in snapshot?.fans.first(where: { $0.id == id })?.automatic == true }
        if confirmed {
            do {
                try ownershipSink([])
                emit("restore_confirmed", code: reason)
                owned = []; targets = [:]; owner = nil; leaseID = nil
                phase = .automatic; errorCode = reason == "user_release" ? nil : reason
                nextRecoveryAt = nil; recoveryAttempts = 0
                return
            } catch { errorCode = "ownership_persistence_failed" }
        } else { errorCode = "restore_not_confirmed" }
        phase = .recoveryFailed
        nextRecoveryAt = recoveryAttempts < 3 ? now + Double(recoveryAttempts) : nil
        emit("restore_failed", code: errorCode)
    }

    private func status() -> FanControlStatus {
        FanControlStatus(phase: phase, leaseID: leaseID, ownedFanIDs: owned.sorted(), targets: targets,
                         leaseExpiresAt: leaseDeadline, boostExpiresAt: boostDeadline, fans: snapshot?.fans ?? [],
                         cpuTemperature: snapshot?.cpuTemperature, gpuTemperature: snapshot?.gpuTemperature,
                         error: errorCode ?? (hardwareUnavailable ? "hardware_unavailable" : nil), generation: generation, hardwareDiagnostic:lastHardwareDiagnostic)
    }
    private func reply(_ ok: Bool, _ code: String, _ request: FanControlRequest) -> FanControlReply {
        FanControlReply(ok: ok, code: code, status: status(), requestID: request.requestID)
    }
    private func diagnostic(stage: String, fanID: Int?, code: String) {
        lastHardwareDiagnostic = "\(stage) fan \(fanID.map(String.init) ?? "-"): \(code)"
        eventSink(FanControlEvent(event: "hardware_operation_failed", code: code, fanIDs: owned.sorted(), targets: targets, generation: generation, requestID: requestContext, stage: stage, fanID: fanID, hardwareError: code))
    }
    private func emit(_ event: String, code: String?) {
        eventSink(FanControlEvent(event: event, code: code, fanIDs: owned.sorted(), targets: targets, generation: generation, requestID: requestContext))
    }
}
