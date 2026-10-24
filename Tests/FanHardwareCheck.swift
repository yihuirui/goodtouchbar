import Foundation
import FanHardware
import SystemMonitoring

@main struct FanHardwareChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition:Bool,_ name:String) { precondition(condition,name); checks += 1; print("PASS: \(name)") }
        func fails(_ action:() throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        for rpm in [0.0,1,1700,5616,16383] {
            let bytes = try FanEncoding.target(rpm:rpm,type:"fpe2",size:2)
            check(SMCDecode.number(type:"fpe2",bytes:bytes) == rpm,"fpe2 round trip \(rpm)")
        }
        let float = try FanEncoding.target(rpm:5616,type:"flt ",size:4)
        check(SMCDecode.number(type:"flt ",bytes:float) == 5616,"little endian float RPM")
        check(fails { _ = try FanEncoding.target(rpm:Double.nan,type:"fpe2",size:2) },"reject NaN RPM")
        check(fails { _ = try FanEncoding.target(rpm:Double.infinity,type:"flt ",size:4) },"reject infinite RPM")
        check(fails { _ = try FanEncoding.target(rpm:-1,type:"fpe2",size:2) },"reject negative RPM")
        check(fails { _ = try FanEncoding.target(rpm:1.5,type:"fpe2",size:2) },"reject fractional RPM")
        check(fails { _ = try FanEncoding.target(rpm:16384,type:"fpe2",size:2) },"reject encoding overflow")
        check(fails { _ = try FanEncoding.target(rpm:3000,type:"ui16",size:2) },"reject unknown target encoding")
        check(fails { _ = try FanEncoding.target(rpm:3000,type:"fpe2",size:4) },"reject wrong target size")
        check(try FanEncoding.modeMask(0b10,fanID:0,manual:true) == 0b11,"preserve other fan while taking control")
        check(try FanEncoding.modeMask(0b11,fanID:0,manual:false) == 0b10,"preserve other fan while restoring")
        check(try FanEncoding.modeMask(0,fanID:9,manual:true) == 512,"highest supported fan bit")
        check(fails { _ = try FanEncoding.modeMask(0,fanID:-1,manual:true) },"reject negative fan ID")
        check(fails { _ = try FanEncoding.modeMask(0,fanID:10,manual:false) },"reject invalid fan ID")
        print("\(checks) fan hardware encoding checks passed; no SMC connection opened")
    }
}
