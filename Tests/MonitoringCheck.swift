import Foundation
import SystemMonitoring

@main struct MonitoringChecks {
    static func main() throws {
        var count = 0
        func check(_ result: Bool, _ name: String) { precondition(result,name); count += 1; print("PASS: \(name)") }
        let zero = CPUCounters(user:0,system:0,nice:0,idle:0)
        let sample = CPUCounters(user:20,system:20,nice:0,idle:60)
        check(sample.utilization(since:nil) == nil,"CPU baseline")
        check(sample.utilization(since:sample) == nil,"CPU zero delta")
        check(sample.utilization(since:zero) == 40,"CPU interval delta")
        let rolled = CPUCounters(user:1,system:0,nice:0,idle:3)
        let old = CPUCounters(user:UInt32.max,system:0,nice:0,idle:0)
        check(rolled.utilization(since:old) == 40,"CPU rollover")
        let used = MemoryMath.used(total:4096,active:100,inactive:50,speculative:10,wired:20,compressed:5,purgeable:3,external:12,pageSize:4)
        check(used == 680,"memory excludes cache")
        let bad = MemoryMath.used(total:10,active:100,inactive:0,speculative:0,wired:0,compressed:0,purgeable:0,external:0,pageSize:4096)
        check(bad == nil,"memory rejects impossible counters")
        check(MemoryMath.pressureName(nil) == "未知","unknown pressure")
        check(SMCDecode.number(type:"fpe2",bytes:[0,0]) == 0,"fan zero is valid")
        check(SMCDecode.number(type:"fpe2",bytes:[0x2e,0xe0]) == 3000,"RPM decoding")
        check(SMCDecode.number(type:"sp78",bytes:[0xff,0x80]) == -0.5,"signed temperature")
        check(SMCDecode.number(type:"sp78",bytes:[0x4b,0x80]) == 75.5,"temperature decoding")
        check(SMCDecode.number(type:"flt ",bytes:[0,0,0x96,0x43]) == 300,"float decoding")
        check(SMCDecode.number(type:"flt ",bytes:[0,0]) == nil,"bad SMC length")
        check(SMCDecode.number(type:"flt ",bytes:[0,0,0x80,0x7f]) == nil,"nonfinite SMC data")
        let now = Date(timeIntervalSince1970:100)
        let fresh = MetricReading(0,unit:"RPM",source:"test",sampledAt:now)
        check(fresh.isFresh(at:now),"fresh zero")
        check(!fresh.isFresh(at:now.addingTimeInterval(13)),"stale sample")
        check(!fresh.isFresh(at:now.addingTimeInterval(-10)),"future sample")
        let fit = DisplayLayout.fit(["cpu","memory","temp","fans"],budget:300,moreWidth:60) {_ in 100}
        check(fit.visible == ["cpu","memory"] && fit.overflow == ["temp","fans"],"overflow and more reserve")
        let empty = DisplayLayout.fit([String](),budget:10) {_ in 100}
        check(empty.visible.isEmpty,"empty layout")
        let dedup = DisplayLayout.fit(["cpu","cpu"],budget:110) {_ in 100}
        check(dedup.visible == ["cpu"],"deduplicate layout")
        var snapshot = MetricsSnapshot()
        snapshot.fans = [FanReading(id:0,actual:0,minimum:1000,maximum:5000,target:1000,mode:"自动")]
        snapshot.readings[MetricID.fans.rawValue] = fresh
        check(snapshot.text(for:MetricID.fans.rawValue,now:now) == "风扇 0","zero fan display")
        check(snapshot.text(for:MetricID.fans.rawValue,now:now.addingTimeInterval(20)) == "风扇 --","stale fan display")
        let reader = MachMetricsReader(); let first = reader.read()
        check(first[MetricID.cpu.rawValue]?.value == nil,"native CPU first sample")
        check(first["memory.total"]?.value != nil && first[MetricID.memory.rawValue]?.value != nil,"native memory read")
        reader.reset(); check(reader.read()[MetricID.cpu.rawValue]?.value == nil,"CPU reset on resume")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let exe = dir.appendingPathComponent("sensor")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to:exe,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:exe.path)
        let client = SensorProcessClient(executable:exe), start = Date()
        var failed = false
        do { _ = try client.sample(SensorRequest(temperatureKeys:[],includeFans:false),timeout:0.15) } catch { failed = true }
        check(failed && Date().timeIntervalSince(start) < 3,"stalled sensor child terminated")
        try "#!/bin/sh\nread request\nprintf 'invalid-json\\n'\n".write(to:exe,atomically:true,encoding:.utf8)
        failed = false
        do { _ = try client.sample(SensorRequest(temperatureKeys:[],includeFans:false),timeout:1) } catch { failed = true }
        check(failed,"malformed sensor response rejected"); client.stop()
        try "#!/bin/sh\nexit 0\n".write(to:exe,atomically:true,encoding:.utf8)
        failed = false
        do { _ = try client.sample(SensorRequest(temperatureKeys:[],includeFans:false),timeout:1) } catch { failed = true }
        check(failed,"sensor child exit does not crash parent")
        print("\(count) monitoring checks passed")
    }
}
