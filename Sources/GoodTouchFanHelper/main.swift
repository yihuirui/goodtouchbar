import Foundation
import Darwin
import FanControlCore
import FanHardware
import SystemMonitoring

let args = Array(CommandLine.arguments.dropFirst())
guard args.isEmpty || args == ["--validate-policy"] || args == ["--restore-and-exit"] else {
    fputs("Usage: GoodTouchFanHelper [--validate-policy|--restore-and-exit]\n",stderr); exit(64)
}
if args != ["--validate-policy"] && !GoodTouchBarDeviceCapabilities.current.canUseIntelFanHelper {
    fputs("intel_fan_helper_blocked_for_host\n", stderr)
    exit(78)
}
guard geteuid() == 0 else { fputs("fan_helper_requires_root\n",stderr); exit(77) }
do {
    if args == ["--validate-policy"] {
        _ = try ClientPolicy.load(); print("client_policy_valid"); exit(0)
    }
    if args == ["--restore-and-exit"] {
        let timeout = DispatchSource.makeTimerSource(queue:DispatchQueue.global(qos:.userInitiated))
        timeout.schedule(deadline:.now() + 8)
        timeout.setEventHandler { _exit(70) }
        timeout.resume()
        defer { timeout.cancel() }
        let pending = try RootFiles.pendingFanIDs()
        if pending.isEmpty { print("no_pending_fan_control"); exit(0) }
        let log = FanEventLog()
        let hardware = try IntelFanHardware()
        let engine = FanControlEngine(hardware:hardware,eventSink:log.record,ownershipSink:RootFiles.persistMarker)
        let status = engine.recover(fanIDs:pending,now:ProcessInfo.processInfo.systemUptime)
        guard status.ownedFanIDs.isEmpty, try RootFiles.pendingFanIDs().isEmpty else { throw HelperStorageError(code:"restore_failed") }
        log.flush(); print("fan_control_restored"); exit(0)
    }
    let daemon = HelperDaemon()
    try daemon.run()
} catch {
    // Codes only; no policy contents, user paths, or request data in stderr.
    fputs("fan_helper_startup_or_restore_failed\n",stderr); exit(78)
}
