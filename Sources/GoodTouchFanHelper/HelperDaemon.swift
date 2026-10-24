import Foundation
import Darwin
import FanControlCore
import FanHardware

private final class ControlWatchdog {
    private let lock = NSLock()
    private var began: Double?
    func begin() { lock.lock(); began = ProcessInfo.processInfo.systemUptime; lock.unlock() }
    func end() { lock.lock(); began = nil; lock.unlock() }
    var stalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return began.map { ProcessInfo.processInfo.systemUptime - $0 > 6 } ?? false
    }
}

private final class ConnectionEndpoint: NSObject, GoodTouchFanHelperProtocol {
    private weak var daemon: HelperDaemon?
    let id = UUID().uuidString
    private let lock = NSLock()
    private var busy = false
    init(daemon: HelperDaemon) { self.daemon = daemon }
    func handle(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        lock.lock()
        guard !busy else { lock.unlock(); reply(Self.errorData(code:"request_in_flight")); return }
        busy = true; lock.unlock()
        guard let daemon else { complete(reply,Self.errorData(code:"service_stopping")); return }
        daemon.submit(request,clientID:id) { [weak self] data in
            guard let self else { reply(data); return }; self.complete(reply,data)
        }
    }
    private func complete(_ reply: (Data) -> Void, _ data: Data) {
        lock.lock(); busy = false; lock.unlock(); reply(data)
    }
    static func errorData(code:String,requestID:String = "") -> Data {
        (try? JSONEncoder().encode(FanControlReply(ok:false,code:code,status:FanControlStatus(),requestID:requestID))) ?? Data()
    }
}

final class HelperDaemon: NSObject, NSXPCListenerDelegate {
    private var policy: ClientPolicy?
    private let listener = NSXPCListener(machServiceName:FanHelperIdentity.machService)
    private let controlQueue = DispatchQueue(label:"io.github.yihuirui.goodtouchbar.fan-helper.control",qos:.userInitiated)
    private let watchdogQueue = DispatchQueue(label:"io.github.yihuirui.goodtouchbar.fan-helper.watchdog",qos:.userInitiated)
    private let stateLock = NSLock()
    private var stopping = false
    private var accepted = Set<String>()
    private var tickPending = false
    private var engineReady = false
    private let watchdog = ControlWatchdog()
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private let log = FanEventLog()
    private var engine: FanControlEngine!
    override init() {
        super.init(); listener.delegate = self
    }
    func run() throws {
        startWatchdog()
        let startup = DispatchSemaphore(value:0)
        var startupError: Error?
        controlQueue.async { [self] in
            watchdog.begin(); defer { watchdog.end(); startup.signal() }
            do {
                let pending = try RootFiles.pendingFanIDs()
                let hardware = try IntelFanHardware()
                engine = FanControlEngine(hardware:hardware,eventSink:{ [log] event in log.record(event) },ownershipSink:RootFiles.persistMarker)
                if !pending.isEmpty { _ = engine.recover(fanIDs:pending,now:ProcessInfo.processInfo.systemUptime) }
                stateLock.lock(); engineReady = true; stateLock.unlock()
            } catch { startupError = error }
        }
        startup.wait()
        if let startupError { throw startupError }
        // Recovery is independent of whether an old/corrupt client policy still validates.
        // Only accepting NEW control requests depends on loading that policy.
        policy = try ClientPolicy.load()
        registerSignals(); listener.resume()
        RunLoop.current.run()
    }
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection) -> Bool {
        stateLock.lock(); let canAccept = !stopping && accepted.count < 8; stateLock.unlock()
        guard canAccept, policy?.validates(connection) == true else { return false }
        let endpoint = ConnectionEndpoint(daemon:self)
        stateLock.lock()
        guard !stopping, accepted.count < 8 else { stateLock.unlock(); return false }
        accepted.insert(endpoint.id); stateLock.unlock()
        connection.exportedInterface = NSXPCInterface(with:GoodTouchFanHelperProtocol.self)
        connection.exportedObject = endpoint
        let id = endpoint.id
        connection.invalidationHandler = { [weak self] in self?.disconnected(id) }
        connection.interruptionHandler = { [weak self] in self?.disconnected(id) }
        connection.resume(); return true
    }
    fileprivate func submit(_ bytes:Data,clientID:String,reply:@escaping (Data)->Void) {
        guard bytes.count <= 16_384, let request = try? JSONDecoder().decode(FanControlRequest.self,from:bytes) else {
            reply(ConnectionEndpoint.errorData(code:"invalid_request")); return
        }
        stateLock.lock(); let canRun = !stopping && accepted.contains(clientID); stateLock.unlock()
        guard canRun else { reply(ConnectionEndpoint.errorData(code:"service_stopping",requestID:request.requestID)); return }
        controlQueue.async { [self] in
            stateLock.lock(); let stillConnected = !stopping && accepted.contains(clientID); stateLock.unlock()
            guard stillConnected else { reply(ConnectionEndpoint.errorData(code:"connection_closed",requestID:request.requestID)); return }
            watchdog.begin(); defer { watchdog.end() }
            let response = engine.handle(request,clientID:clientID,now:ProcessInfo.processInfo.systemUptime)
            reply((try? JSONEncoder().encode(response)) ?? ConnectionEndpoint.errorData(code:"encoding_failed",requestID:request.requestID))
        }
    }
    private func disconnected(_ id:String) {
        stateLock.lock(); let existed = accepted.remove(id) != nil; stateLock.unlock()
        guard existed else { return }
        controlQueue.async { [self] in
            watchdog.begin(); defer { watchdog.end() }
            _ = engine.clientDisconnected(clientID:id,now:ProcessInfo.processInfo.systemUptime)
        }
    }
    private func startWatchdog() {
        let source = DispatchSource.makeTimerSource(queue:watchdogQueue)
        source.schedule(deadline:.now() + 1,repeating:1)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watchdog.stalled {
                // A synchronous driver call cannot be cancelled safely. Keep the persisted
                // marker and let launchd restart the process into startup recovery.
                _exit(70)
            }
            self.stateLock.lock()
            guard !self.stopping, !self.tickPending, self.engineReady else { self.stateLock.unlock(); return }
            self.tickPending = true; self.stateLock.unlock()
            self.controlQueue.async { [self] in
                defer { self.stateLock.lock(); self.tickPending = false; self.stateLock.unlock() }
                guard !self.engine.currentStatus().ownedFanIDs.isEmpty else { return }
                self.watchdog.begin(); defer { self.watchdog.end() }
                _ = self.engine.tick(now:ProcessInfo.processInfo.systemUptime)
            }
        }
        timer = source; source.resume()
    }
    private func registerSignals() {
        for number in [SIGTERM,SIGINT] {
            signal(number,SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:number,queue:watchdogQueue)
            source.setEventHandler { [weak self] in self?.shutdown() }
            signals.append(source); source.resume()
        }
    }
    private func shutdown() {
        stateLock.lock(); guard !stopping else { stateLock.unlock(); return }; stopping = true; stateLock.unlock()
        listener.invalidate()
        controlQueue.async { [self] in
            watchdog.begin(); defer { watchdog.end() }
            do {
                let inMemory = engine.currentStatus().ownedFanIDs
                let onDisk: [Int]
                do { onDisk = try RootFiles.pendingFanIDs() }
                catch {
                    // Never skip releasing known hardware merely because its disk marker
                    // was lost or corrupted after this process took control.
                    onDisk = []
                    log.record(FanControlEvent(event:"marker_read_failed_on_shutdown",code:"marker_unavailable",fanIDs:inMemory))
                }
                let pending = Set(inMemory).union(onDisk).sorted()
                let result = engine.recover(fanIDs:pending,now:ProcessInfo.processInfo.systemUptime)
                guard result.ownedFanIDs.isEmpty, try RootFiles.pendingFanIDs().isEmpty else { _exit(74) }
                log.flush(); _exit(0)
            } catch { _exit(74) }
        }
    }
}
