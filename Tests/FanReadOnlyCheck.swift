import Foundation
import FanControlCore
import FanHardware

@main struct FanReadOnlyCheck {
    static func main() throws {
        let hardware = try IntelFanHardware()
        let snapshot = try hardware.snapshot()
        precondition(snapshot.fans.count == 2)
        precondition(snapshot.fans.allSatisfy { $0.actualRPM != nil && $0.minimumRPM != nil && $0.maximumRPM != nil && $0.automatic != nil })
        precondition(snapshot.cpuTemperature != nil && snapshot.gpuTemperature != nil)
        print("PASS: native write-adapter read-only snapshot, 2 fans with mode/bounds and valid CPU/GPU-chip temperatures; no write method invoked")
    }
}
