import Foundation
import Security
import Darwin
import FanControlCore
import FanHardware

private final class FakeHardware: FanControlCore.FanHardware {
    var target: Double = 2200, automatic = true
    func snapshot() throws -> FanHardwareSnapshot {
        FanHardwareSnapshot(fans:[FanDeviceReading(id:0,actualRPM:2200,minimumRPM:1800,maximumRPM:5600,targetRPM:target,automatic:automatic)],cpuTemperature:60,gpuTemperature:55,sampledUptime:ProcessInfo.processInfo.systemUptime)
    }
    func setTarget(id:Int,rpm:Double) throws { target = rpm }
    func setManual(id:Int) throws { automatic = false }
    func setAutomatic(id:Int) throws { automatic = true }
}
private final class TestService: NSObject, GoodTouchFanHelperProtocol {
    let engine = FanControlEngine(hardware:FakeHardware())
    let queue = DispatchQueue(label:"fan-xpc-test")
    func handle(_ request:Data,withReply reply:@escaping(Data)->Void) {
        queue.async {
            guard let request = try? JSONDecoder().decode(FanControlRequest.self,from:request) else { reply(Data()); return }
            let result = self.engine.handle(request,clientID:"anonymous-test",now:ProcessInfo.processInfo.systemUptime)
            reply((try? JSONEncoder().encode(result)) ?? Data())
        }
    }
}
private final class TestListener: NSObject, NSXPCListenerDelegate {
    let policy: ClientPolicy
    let service = TestService()
    var validated = false
    init(policy:ClientPolicy) { self.policy = policy }
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection) -> Bool {
        guard policy.validates(connection) else { return false }
        validated = true
        connection.exportedInterface = NSXPCInterface(with:GoodTouchFanHelperProtocol.self)
        connection.exportedObject = service; connection.resume(); return true
    }
}
@main struct FanXPCCheck {
    static func main() async throws {
        // Explicitly non-root and fake hardware. No system Mach service is registered.
        precondition(geteuid() != 0)
        let watchdog = DispatchSource.makeTimerSource(queue:.global())
        watchdog.schedule(deadline:.now()+10); watchdog.setEventHandler { _exit(99) }; watchdog.resume()
        defer { watchdog.cancel() }
        var code: SecStaticCode?, information: CFDictionary?
        let executable = URL(fileURLWithPath:CommandLine.arguments[0])
        precondition(SecStaticCodeCreateWithPath(executable as CFURL,[],&code) == errSecSuccess)
        precondition(SecCodeCopySigningInformation(code!,SecCSFlags(rawValue:kSecCSSigningInformation),&information) == errSecSuccess)
        let hash = (information! as NSDictionary)[kSecCodeInfoUnique] as! Data
        let hex = hash.map { String(format:"%02x",$0) }.joined()
        let policyData = try JSONSerialization.data(withJSONObject:["version":1,"clientUID":getuid(),"clientRequirement":"identifier \"io.github.yihuirui.goodtouchbar\" and cdhash H\"\(hex)\""])
        let policy = try ClientPolicy.decode(policyData)
        let listener = NSXPCListener.anonymous(), delegate = TestListener(policy:policy)
        listener.delegate = delegate; listener.resume()
        let connection = NSXPCConnection(listenerEndpoint:listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with:GoodTouchFanHelperProtocol.self); connection.resume()
        defer { connection.invalidate(); listener.invalidate() }
        func send(_ request:FanControlRequest) async throws -> FanControlReply {
            let data = try JSONEncoder().encode(request)
            return try await withCheckedThrowingContinuation { continuation in
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in continuation.resume(throwing:error) } as! GoodTouchFanHelperProtocol
                proxy.handle(data) { data in
                    do { continuation.resume(returning:try JSONDecoder().decode(FanControlReply.self,from:data)) }
                    catch { continuation.resume(throwing:error) }
                }
            }
        }
        let status = try await send(FanControlRequest(action:.status)); precondition(status.ok)
        let fixed = try await send(FanControlRequest(action:.fixed,targets:[0:3000])); precondition(fixed.ok && fixed.status.phase == .controlling)
        let release = try await send(FanControlRequest(action:.automatic,leaseID:fixed.status.leaseID)); precondition(release.ok && release.status.phase == .automatic)
        precondition(delegate.validated)
        print("PASS: native anonymous XPC, audit-token UID and exact CDHash authentication, Data roundtrips and fake control/release; no root or hardware writes")
    }
}
