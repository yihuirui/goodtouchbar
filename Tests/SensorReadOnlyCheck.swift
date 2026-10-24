import Foundation
import SystemMonitoring
@main struct SensorReadOnlyCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the read-only GoodTouchSensors executable") }
        var launches=0, timings:[Double]=[]
        let client=SensorProcessClient(executable:URL(fileURLWithPath:CommandLine.arguments[1]),event:{ event,_ in if event == "sensor_process_started" {launches += 1} })
        defer {client.stop()}
        let temperatureKeys = CoreTemperature.keys
        let machReader = MachMetricsReader()
        _ = machReader.read() // The first CPU sample intentionally has no prior counter baseline.
        Thread.sleep(forTimeInterval:0.1)
        let mach = machReader.read()
        guard let cpu = mach[MetricID.cpu.rawValue]?.value,
              let memory = mach[MetricID.memory.rawValue]?.value else {
            print("Mach read diagnostic CPU=\(String(describing:mach[MetricID.cpu.rawValue])) memory=\(String(describing:mach[MetricID.memory.rawValue]))")
            fatalError("read-only Mach CPU and memory metrics unavailable after baseline sample")
        }
        _ = (cpu, memory)
        precondition(!temperatureKeys.isEmpty, "this host has no supported read-only CPU thermal mapping")
        var rpmCount = 0
        for _ in 0..<12 {
            let began=ProcessInfo.processInfo.systemUptime
            let sample=try client.sample(SensorRequest(temperatureKeys:temperatureKeys,includeFans:true))
            precondition(sample.temperatures.values.contains { $0.value != nil } && !sample.fans.isEmpty,"read-only native temperature/RPM data unavailable")
            rpmCount = sample.fans.filter { $0.actual != nil }.count
            timings.append((ProcessInfo.processInfo.systemUptime-began)*1000)
            Thread.sleep(forTimeInterval:0.1)
        }
        precondition(launches == 1,"native sensor must retain its process")
        print("12 native read-only samples; Mach CPU/memory present; thermal keys", temperatureKeys.count, "RPM readings", rpmCount, "sensor launches",launches,"warm latency min/max ms",timings.dropFirst().min()!,timings.dropFirst().max()!)
    }
}
