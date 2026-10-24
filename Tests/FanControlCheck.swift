import Foundation
#if canImport(FanControlCore)
import FanControlCore
#endif

private enum MockFailure: Error { case requested }
private final class MockHardware: FanHardware {
    struct Fan {
        var id: Int, actual: Double, low: Double, high: Double, target: Double
        var automatic: Bool
    }
    var fans: [Fan] = [Fan(id:0,actual:2200,low:1800,high:5600,target:2200,automatic:true),Fan(id:1,actual:2000,low:1700,high:5200,target:2000,automatic:true)]
    var now: Double = 100
    var cpu: Double? = 60, gpu: Double? = 55
    var age: Double = 0
    var failSnapshot = false
    var failTargetID: Int?, failManualID: Int?
    var failAutoIDs = Set<Int>()
    var ignoreTargets = false
    var rejectTargetWhileAutomatic = false
    var calls: [String] = []
    var beforeSnapshot: (() -> Void)?
    var beforeWrite: ((Int) -> Void)?
    func snapshot() throws -> FanHardwareSnapshot {
        beforeSnapshot?()
        if failSnapshot { throw MockFailure.requested }
        let readings = fans.map { FanDeviceReading(id:$0.id,actualRPM:$0.actual,minimumRPM:$0.low,maximumRPM:$0.high,targetRPM:$0.target,automatic:$0.automatic) }
        return FanHardwareSnapshot(fans:readings,cpuTemperature:cpu,gpuTemperature:gpu,sampledUptime:now-age)
    }
    func setTarget(id: Int, rpm: Double) throws {
        beforeWrite?(id)
        calls.append("target:\(id)")
        if id == failTargetID { throw MockFailure.requested }
        if rejectTargetWhileAutomatic && fans.first(where: {$0.id == id})?.automatic == true { throw MockFailure.requested }
        if !ignoreTargets, let i = fans.firstIndex(where: {$0.id==id}) { fans[i].target = rpm }
    }
    func setManual(id: Int) throws {
        beforeWrite?(id)
        calls.append("manual:\(id)")
        if id == failManualID { throw MockFailure.requested }
        if let i = fans.firstIndex(where: {$0.id==id}) { fans[i].automatic = false }
    }
    func setAutomatic(id: Int) throws {
        beforeWrite?(id)
        calls.append("auto:\(id)")
        if failAutoIDs.contains(id) { throw MockFailure.requested }
        if let i = fans.firstIndex(where: {$0.id==id}) { fans[i].automatic = true }
    }
}
private final class Ownership {
    var ids: [Int] = [], failWrite = false, failClear = false
    var transitions: [[Int]] = []
    func save(_ ids: [Int]) throws {
        if failWrite || (failClear && ids.isEmpty) { throw MockFailure.requested }
        self.ids = ids; transitions.append(ids)
    }
}
private final class Fixture {
    let hw = MockHardware(), ownership = Ownership()
    var events: [FanControlEvent] = []
    lazy var engine = FanControlEngine(hardware:hw,eventSink:{ [weak self] in self?.events.append($0) },ownershipSink:{ [ownership] in try ownership.save($0) })
    func handle(_ request:FanControlRequest,client:String="client-a",now:Double?=nil)->FanControlReply {
        if let now { hw.now = now }
        return engine.handle(request,clientID:client,now:hw.now)
    }
    func fixed(_ targets:[Int:Double]=[0:3000])->FanControlReply { handle(FanControlRequest(action:.fixed,targets:targets)) }
}

@main struct FanControlChecks {
    static func main() throws {
        var passed = 0
        func test(_ name:String,_ body:()->Void) { body(); passed += 1; print("PASS: \(name)") }
        func check(_ value:Bool,_ message:String="") { precondition(value,message) }
        test("fixed takeover persists first, confirms readback and isolates other fan") {
            let f = Fixture(); f.hw.beforeWrite = { id in check(f.ownership.ids.contains(id),"marker must precede hardware write") }; let result = f.fixed()
            check(result.ok && result.status.phase == .controlling)
            check(result.status.ownedFanIDs == [0] && f.ownership.ids == [0])
            check(!f.hw.fans[0].automatic && f.hw.fans[1].automatic)
            check(result.status.leaseExpiresAt == 110)
            check(f.hw.calls == ["manual:0","target:0"])
            check(f.events.contains {$0.event == "control_confirmed"})
        }
        test("invalid targets and missing limits never write") {
            for rpm in [Double.nan,Double.infinity,0,1799,5601,3000.5] {
                let f=Fixture(); let result=f.fixed([0:rpm]);check(!result.ok && f.hw.calls.isEmpty && f.ownership.ids.isEmpty)
            }
            let f=Fixture();f.hw.fans[0].low=0;check(!f.fixed().ok && f.hw.calls.isEmpty)
        }
        test("automatic target rejection is avoided by manual-first sequence") {
            let f=Fixture();f.hw.rejectTargetWhileAutomatic=true
            check(f.fixed([0:4000,1:4000]).ok)
            check(f.hw.calls == ["manual:0","target:0","manual:1","target:1"])
            check(f.hw.fans.allSatisfy { !$0.automatic && $0.target == 4000 })
        }
        test("target failure after mode takeover restores all owned fans") {
            let f=Fixture();f.hw.failTargetID=1
            check(!f.fixed([0:4000,1:4000]).ok)
            check(f.hw.fans.allSatisfy(\.automatic) && f.ownership.ids.isEmpty)
        }
        test("zero actual RPM is valid") {
            let f=Fixture();f.hw.fans[0].actual=0;check(f.fixed().ok)
        }
        test("missing or invalid temperatures still report unavailable") {
            let a=Fixture();a.hw.cpu=nil;check(!a.fixed().ok && a.hw.calls.isEmpty)
            let b=Fixture();b.hw.gpu=nil;check(!b.fixed().ok && b.hw.calls.isEmpty)
            let c=Fixture();c.hw.cpu=Double.nan;check(!c.fixed().ok && c.hw.calls.isEmpty)
            let d=Fixture();d.hw.gpu=126;check(!d.fixed().ok && d.hw.calls.isEmpty)
        }
        test("high CPU or GPU temperature allows fixed control with advisory") {
            for (cpu,gpu) in [(95.0,55.0),(60.0,95.0),(100.0,100.0),(125.0,55.0)] {
                let f=Fixture();f.hw.cpu=cpu;f.hw.gpu=gpu
                let reply=f.fixed();check(reply.ok && reply.status.phase == .controlling && reply.status.temperatureWarning != nil)
                check(!f.hw.fans[0].automatic && f.hw.fans[0].target == 3000)
            }
        }
        test("high temperature also allows boost and fixed preset changes") {
            let f=Fixture();f.hw.cpu=100
            let first=f.fixed();check(first.ok)
            let changed=f.handle(FanControlRequest(action:.fixed,targets:[0:3200],leaseID:first.status.leaseID));check(changed.ok && changed.status.targets[0] == 3200)
            let boost=f.handle(FanControlRequest(action:.boost,leaseID:first.status.leaseID));check(boost.ok && boost.status.phase == .controlling)
        }
        test("temperature warnings are transition logged without repeated spam") {
            let f=Fixture();f.hw.cpu=98;let first=f.fixed();check(first.ok)
            f.hw.now=101;_=f.engine.tick(now:101)
            check(f.events.filter { $0.event == "temperature_warning" }.count == 1)
            f.hw.cpu=90;f.hw.now=102;let cool=f.engine.tick(now:102)
            check(cool.temperatureWarning == nil && cool.phase == .controlling)
            check(f.events.filter { $0.event == "temperature_warning_cleared" }.count == 1)
        }
        test("another controller's fan is not taken over") {
            let f=Fixture();f.hw.fans[0].automatic=false
            check(f.fixed().code == "fan_already_controlled" && f.hw.calls.isEmpty)
            let auto=f.handle(FanControlRequest(action:.automatic));check(!auto.ok && auto.code == "fan_not_owned" && f.hw.calls.isEmpty)
        }
        test("heartbeat renews only an owned live lease") {
            let f=Fixture();let start=f.fixed()
            let wrong=f.handle(FanControlRequest(action:.heartbeat,leaseID:start.status.leaseID),client:"other",now:105)
            check(!wrong.ok && wrong.status.leaseExpiresAt == 110)
            let live=f.handle(FanControlRequest(action:.heartbeat,leaseID:start.status.leaseID),now:109)
            check(live.ok && live.status.leaseExpiresAt == 119)
        }
        test("expired heartbeat restores auto and cannot revive lease") {
            let f=Fixture();let start=f.fixed()
            let expired=f.handle(FanControlRequest(action:.heartbeat,leaseID:start.status.leaseID),now:110)
            check(!expired.ok && expired.status.phase == .automatic && expired.status.ownedFanIDs.isEmpty)
            check(f.ownership.ids.isEmpty && f.hw.fans[0].automatic)
            check(!f.handle(FanControlRequest(action:.fixed,targets:[0:3000],leaseID:start.status.leaseID),now:111).ok)
        }
        test("boost uses per-fan maxima and expires independently of heartbeat") {
            let f=Fixture();let boost=f.handle(FanControlRequest(action:.boost));check(boost.ok)
            check(boost.status.targets == [0:5600,1:5200] && boost.status.boostExpiresAt == 400)
            for time in stride(from:102.0,through:398.0,by:2.0) {
                check(f.handle(FanControlRequest(action:.heartbeat,leaseID:boost.status.leaseID),now:time).ok)
            }
            f.hw.now=400;let status=f.engine.tick(now:400)
            check(status.phase == .automatic && status.error == "boost_expired" && f.hw.fans.allSatisfy(\.automatic))
        }
        test("duplicate boost cannot reset deadline or repeat writes") {
            let f=Fixture();let request=FanControlRequest(action:.boost)
            let first=f.handle(request);let calls=f.hw.calls
            _=f.handle(FanControlRequest(action:.heartbeat,leaseID:first.status.leaseID),now:105)
            let duplicate=f.handle(request,now:106)
            check(duplicate.ok && duplicate.status.boostExpiresAt == 400 && duplicate.status.leaseExpiresAt == 115)
            check(f.hw.calls == calls)
            let changed=FanControlRequest(action:.fixed,targets:[0:3000],requestID:request.requestID)
            check(f.handle(changed).code == "request_id_reused")
        }
        test("duplicate command after expiry returns current auto state") {
            let f=Fixture();let request=FanControlRequest(action:.fixed,targets:[0:3000]);_=f.handle(request)
            let duplicate=f.handle(request,now:111)
            check(duplicate.status.phase == .automatic && f.hw.calls.filter {$0=="manual:0"}.count == 1)
        }
        test("partial write failure restores every persisted fan") {
            let f=Fixture();f.hw.failTargetID=1
            let result=f.fixed([0:3000,1:3000])
            check(!result.ok && result.status.phase == .automatic && f.ownership.ids.isEmpty)
            check(f.hw.calls.contains("auto:0") && f.hw.calls.contains("auto:1"))
        }
        test("write readback mismatch triggers recovery") {
            let f=Fixture();f.hw.ignoreTargets=true
            let result=f.fixed();check(!result.ok && result.code == "write_readback_failed" && f.hw.fans[0].automatic)
        }
        test("initial recovery marker persistence failure blocks all writes") {
            let f=Fixture();f.ownership.failWrite=true
            let result=f.fixed();check(result.code == "ownership_persistence_failed" && f.hw.calls.isEmpty)
        }
        test("failed recovery blocks takeover, preserves marker and bounds retries") {
            let f=Fixture();let lease=f.fixed().status.leaseID;f.hw.failAutoIDs=[0]
            let result=f.handle(FanControlRequest(action:.automatic,leaseID:lease),now:101)
            check(!result.ok && result.status.phase == .recoveryFailed && f.ownership.ids == [0])
            check(f.handle(FanControlRequest(action:.fixed,targets:[1:3000]),now:101).code == "recovery_required")
            f.hw.now=102;_=f.engine.tick(now:102)
            f.hw.now=104;_=f.engine.tick(now:104)
            let attempts=f.hw.calls.filter {$0=="auto:0"}.count
            f.hw.now=200;_=f.engine.tick(now:200)
            check(attempts == 3 && f.hw.calls.filter {$0=="auto:0"}.count == 3)
            f.hw.failAutoIDs=[]
            let restored=f.handle(FanControlRequest(action:.automatic,leaseID:lease),now:201)
            check(restored.ok && f.ownership.ids.isEmpty)
        }
        test("marker clear failure remains visible until explicit recovery succeeds") {
            let f=Fixture();let lease=f.fixed().status.leaseID;f.ownership.failClear=true
            let result=f.handle(FanControlRequest(action:.automatic,leaseID:lease))
            check(!result.ok && result.status.phase == .recoveryFailed && result.status.error == "ownership_persistence_failed")
            check(f.hw.fans[0].automatic && f.ownership.ids == [0])
            f.ownership.failClear=false
            check(f.handle(FanControlRequest(action:.automatic,leaseID:lease)).ok)
        }
        test("recovery revokes control credentials so a client can retry without its old lease") {
            let f=Fixture();let lease=f.fixed().status.leaseID;f.hw.failAutoIDs=[0]
            let failed=f.handle(FanControlRequest(action:.automatic,leaseID:lease),now:101)
            check(!failed.ok && failed.status.phase == .recoveryFailed && failed.status.leaseID == nil)
            f.hw.failAutoIDs=[]
            let recovered=f.handle(FanControlRequest(action:.automatic),now:101)
            check(recovered.ok && recovered.status.ownedFanIDs.isEmpty && f.ownership.ids.isEmpty,"explicit recovery without obsolete lease was rejected: \(recovered.code)")
        }
        test("disconnected owner does not lock out a new client's explicit recovery after bounded retries") {
            let f=Fixture();_=f.fixed();f.hw.failAutoIDs=[0];f.hw.now=101
            let failed=f.engine.clientDisconnected(clientID:"client-a",now:101)
            check(failed.phase == .recoveryFailed && failed.ownedFanIDs == [0])
            f.hw.now=102;_=f.engine.tick(now:102)
            f.hw.now=104;_=f.engine.tick(now:104)
            check(f.hw.calls.filter {$0=="auto:0"}.count == 3)
            f.hw.failAutoIDs=[]
            let recovered=f.handle(FanControlRequest(action:.automatic),client:"new-client",now:105)
            check(recovered.ok && recovered.status.phase == .automatic && f.ownership.ids.isEmpty)
            check(!f.hw.calls.contains("auto:1"))
        }
        test("active control still rejects another client's release or automatic command") {
            let f=Fixture();let lease=f.fixed().status.leaseID;let calls=f.hw.calls
            for action in [FanControlAction.automatic,.release,.sleep] {
                let rejected=f.handle(FanControlRequest(action:action,leaseID:lease),client:"other",now:101)
                check(!rejected.ok && rejected.code == "lease_not_owned" && rejected.status.phase == .controlling)
            }
            check(f.handle(FanControlRequest(action:.automatic),now:101).code == "lease_not_owned")
            check(f.hw.calls == calls && f.engine.currentStatus().leaseID == lease)
        }
        test("client disconnect and sleep restore only own fans") {
            let f=Fixture();let start=f.fixed()
            let unaffected=f.engine.clientDisconnected(clientID:"other",now:101)
            check(unaffected.phase == .controlling)
            f.hw.now=102;let restored=f.engine.clientDisconnected(clientID:"client-a",now:102)
            check(restored.phase == .automatic && !f.hw.calls.contains("auto:1"))
            let g=Fixture();let active=g.fixed()
            check(g.handle(FanControlRequest(action:.sleep,leaseID:active.status.leaseID)).status.phase == .automatic)
            check(start.status.leaseID != nil)
        }
        test("startup recovery is limited to marker IDs") {
            let f=Fixture();f.hw.fans[0].automatic=false;f.hw.fans[1].automatic=false
            f.ownership.ids=[0]
            let recovered=f.engine.recover(fanIDs:[0],now:100)
            check(recovered.phase == .automatic && f.hw.fans[0].automatic && !f.hw.fans[1].automatic)
            check(f.hw.calls == ["auto:0"])
        }
        test("corrupt recovery IDs block control instead of ignoring marker") {
            let f=Fixture();let status=f.engine.recover(fanIDs:[-1,0],now:100)
            check(status.phase == .recoveryFailed && status.error == "invalid_recovery_marker")
            check(!f.fixed().ok && f.hw.calls.isEmpty)
        }
        test("overtemperature preserves fixed RPM across status and heartbeat") {
            let f=Fixture();let start=f.fixed();f.hw.cpu=100;f.hw.gpu=99;f.hw.now=101
            let hot=f.engine.tick(now:101)
            check(hot.phase == .controlling && hot.temperatureWarning != nil && !f.hw.fans[0].automatic)
            let heartbeat=f.handle(FanControlRequest(action:.heartbeat,leaseID:start.status.leaseID),now:102)
            check(heartbeat.ok && heartbeat.status.targets[0] == 3000 && heartbeat.status.phase == .controlling)
            check(!f.hw.calls.contains("auto:0"))
            check(f.handle(FanControlRequest(action:.automatic,leaseID:start.status.leaseID),now:103).ok)
        }
        test("missing sensor during control still recovers to automatic") {
            let g=Fixture();_=g.fixed();g.hw.gpu=nil;g.hw.now=101
            check(g.engine.tick(now:101).phase == .automatic)
        }
        test("external target drift ends control rather than fighting it") {
            let f=Fixture();_=f.fixed();f.hw.fans[0].target=3500;f.hw.now=101
            let status=f.engine.tick(now:101)
            check(status.phase == .automatic && status.error == "external_control_or_readback_changed")
            check(f.hw.calls.filter {$0=="manual:0"}.count == 1)
        }
        test("clock regression releases control and cannot extend lease") {
            let f=Fixture();_=f.fixed();f.hw.now=99
            let result=f.handle(FanControlRequest(action:.heartbeat,leaseID:f.engine.currentStatus().leaseID),now:99)
            check(!result.ok && result.code == "invalid_clock" && result.status.phase == .automatic)
        }
        test("idle hardware failure is reported and transient recovery clears it") {
            let f=Fixture();f.hw.failSnapshot=true
            let unavailable=f.handle(FanControlRequest(action:.status))
            check(!unavailable.ok && unavailable.status.error == "hardware_unavailable")
            f.hw.failSnapshot=false
            let recovered=f.handle(FanControlRequest(action:.status))
            check(recovered.ok && recovered.status.error == nil)
        }
        test("stale snapshots refuse manual control") {
            let f=Fixture();f.hw.age=4
            check(!f.fixed().ok && f.hw.calls.isEmpty)
        }
        test("protocol and response request ID") {
            let f=Fixture();let bad=FanControlRequest(action:.fixed,targets:[0:3000],protocolVersion:2)
            let reply=f.handle(bad);check(!reply.ok && reply.code == "invalid_request" && reply.requestID == bad.requestID)
            let valid=FanControlRequest(action:.status)
            let encoded=try! JSONEncoder().encode(valid)
            let decoded=try! JSONDecoder().decode(FanControlRequest.self,from:encoded)
            check(valid == decoded && f.handle(decoded).requestID == valid.requestID)
        }
        test("capacity exhaustion cannot block automatic, release, or sleep") {
            for action in [FanControlAction.automatic, .release, .sleep] {
                let f=Fixture()
                for _ in 0..<1023 { check(f.handle(FanControlRequest(action:.automatic)).ok) }
                let start=f.fixed();check(start.ok)
                check(f.handle(FanControlRequest(action:.automatic,leaseID:start.status.leaseID),client:"other").code == "lease_not_owned")
                let restored=f.handle(FanControlRequest(action:action,leaseID:start.status.leaseID))
                check(restored.ok && f.hw.fans[0].automatic && restored.status.ownedFanIDs.isEmpty)
                check(f.fixed().code == "request_capacity_reached")
                check(f.handle(FanControlRequest(action:.automatic)).ok)
            }
        }
        test("hardware diagnostics retain request, fan and stage without raw error text") {
            let f=Fixture();f.hw.failManualID=0
            let request=FanControlRequest(action:.fixed,targets:[0:3000])
            let result=f.handle(request);check(!result.ok)
            let event=f.events.first { $0.event == "hardware_operation_failed" }
            check(event?.requestID == request.requestID && event?.fanID == 0 && event?.stage == "setManual" && event?.hardwareError == "hardware_error")
            check(f.hw.fans[0].automatic)
            check(result.status.hardwareDiagnostic?.contains("setManual fan 0") == true)
            let decoded = try! JSONDecoder().decode(FanControlReply.self,from:JSONEncoder().encode(result))
            check(decoded.status.hardwareDiagnostic == result.status.hardwareDiagnostic)
        }
        print("\(passed) fan control checks passed (simulated hardware; no hardware writes)")
    }
}
