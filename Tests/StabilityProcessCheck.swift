import Foundation
import Darwin
import SystemMonitoring

@main struct StabilityProcessChecks {
    static func main() throws {
        var count=0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: " + label) }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("btt-process-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        func fixture(_ name:String,_ contents:String) throws -> URL {
            let url=directory.appendingPathComponent(name)
            try contents.write(to:url,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url
        }
        let healthy=try fixture("sensor","""
        #!/usr/bin/python3
        import sys,json,time,os
        for line in sys.stdin:
            r=json.loads(line)
            now=time.time()-978307200
            d={'version':1,'requestID':r['requestID'],'sampledAt':now,'temperatures':{'pid':{'value':os.getpid(),'unit':'pid','source':'fixture','sampledAt':now}},'fans':[]}
            data=(json.dumps(d)+'\\n').encode()
            os.write(1,data[:12]);time.sleep(0.005);os.write(1,data[12:])
        """)
        let client=SensorProcessClient(executable:healthy)
        var pids=Set<Double>(), durations:[Double]=[]
        for _ in 0..<5 {
            let began=ProcessInfo.processInfo.systemUptime
            let response=try client.sample(SensorRequest(temperatureKeys:[],includeFans:false))
            pids.insert(response.temperatures["pid"]!.value!);durations.append(ProcessInfo.processInfo.systemUptime-began)
        }
        check(pids.count == 1,"five short/fragmented sensor replies reuse one PID")
        check(durations.dropFirst().allSatisfy {$0<0.3},"short sensor frames return before watchdog")
        print("sensor_sample_ms",durations.map {Int($0*1000)})
        client.stop()
        let stalled=try fixture("stall","#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 30\n")
        let blocked=SensorProcessClient(executable:stalled)
        let start=ProcessInfo.processInfo.systemUptime
        do { _=try blocked.sample(SensorRequest(temperatureKeys:[],includeFans:false),timeout:0.15);check(false,"timeout must fail") }
        catch SensorClientError.timedOut { check(ProcessInfo.processInfo.systemUptime-start<0.8,"sensor timeout cannot report success") }
        let malformed=try fixture("malformed","#!/bin/sh\nread request\nprintf 'bad-json\\n'\nsleep 20\n")
        do { _=try SensorProcessClient(executable:malformed).sample(SensorRequest(temperatureKeys:[],includeFans:false));check(false,"malformed rejected") }
        catch { check(true,"malformed frame rejected without waiting for EOF") }
        let stderr=try fixture("stderr","#!/usr/bin/python3\nimport sys\nsys.stderr.write('x'*262144)\nsys.stderr.flush()\nprint('ok')\n")
        let result=BoundedProcess().run(executable:stderr.path,arguments:[],timeout:3,stderrLimit:64)
        check(result.succeeded && String(decoding:result.stdout,as:UTF8.self).contains("ok"),"stderr flood is drained concurrently")
        check(result.stderr.count == 64,"stderr capture bounded")
        let timeoutStart=ProcessInfo.processInfo.systemUptime
        let timeout=BoundedProcess().run(executable:"/bin/sh",arguments:["-c","trap '' TERM; while :; do sleep 1; done"],timeout:0.2)
        check(timeout.failure == "timeout" && ProcessInfo.processInfo.systemUptime-timeoutStart<2,"TERM-resistant group is killed at deadline")
        let marker=directory.appendingPathComponent("escaped-marker")
        let orphan=try fixture("orphan","#!/bin/sh\n(sleep 2; touch '\(marker.path)') &\nexit 0\n")
        let orphanResult=BoundedProcess().run(executable:orphan.path,arguments:[],timeout:4)
        check(orphanResult.failure == "pipe_drain_timeout","exited parent with inherited open pipe has drain deadline")
        Thread.sleep(forTimeInterval:2.1)
        check(!FileManager.default.fileExists(atPath:marker.path),"descendant process group reclaimed")
        let inherited = open("/dev/null",O_RDONLY)
        let descriptorCheck = try fixture("descriptor", "#!/usr/bin/python3\nimport os,sys\ntry: os.fstat(\(inherited))\nexcept OSError: sys.exit(0)\nsys.exit(1)\n")
        let isolation = BoundedProcess().run(executable:descriptorCheck.path,arguments:[],timeout:3)
        close(inherited)
        check(isolation.succeeded,"child does not inherit unrelated parent descriptors")
        let cancellation=BoundedProcess()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { cancellation.cancel() }
        check(cancellation.run(executable:"/bin/sleep",arguments:["20"],timeout:10).failure == "cancelled","explicit cancellation ends process")
        let flood=BoundedProcess().run(executable:"/usr/bin/printf",arguments:[String(repeating:"a",count:2048)],timeout:2,stdoutLimit:128)
        check(flood.stdoutTruncated && flood.stdout.count == 128,"stdout capture bounded")
        var recovery=PresentationRecovery()
        var delays:[Double]=[]
        for _ in 0..<6 { if let delay=recovery.failed(now:100) {delays.append(delay)} }
        check(delays == [1,2,4,8,16] && recovery.exhausted,"presentation recovery backs off and stops")
        recovery.reset();check(!recovery.exhausted && recovery.failures == 0,"explicit recovery reset")
        let file=directory.appendingPathComponent("stderr.log")
        try Data(repeating:65,count:2048).write(to:file)
        let fd=open(file.path,O_WRONLY | O_APPEND);defer { close(fd) }
        StandardStreamLogLimiter.limit(descriptor:fd,path:file.path,maximum:1024)
        let empty = try Data(contentsOf:file).isEmpty
        let backupSize = try Data(contentsOf:URL(fileURLWithPath:file.path+".previous")).count
        check(empty && backupSize == 1024,"legacy stream logs bounded without replacing live inode")
        _=Darwin.write(fd,"new",3)
        check((try Data(contentsOf:file)).count == 3,"stream continues after rotation")
        print("\(count) process and resource stability checks passed")
    }
}
