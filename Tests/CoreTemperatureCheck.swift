import Foundation
import SystemMonitoring

@main struct CoreTemperatureCheck {
    static func main() {
        var count = 0
        func check(_ value:Bool,_ message:String) { precondition(value,message); count += 1; print("PASS: \(message)") }
        let now = Date()
        func reading(_ value:Double?,_ age:Double = 0,_ error:String? = nil) -> MetricReading {
            MetricReading(value,unit:"°C",source:"fixture",sampledAt:now.addingTimeInterval(-age),error:error)
        }
        func summarizeIntel(_ readings:[String:MetricReading]) -> CoreTemperature.Summary {
            CoreTemperature.summarize(readings,keys:CoreTemperature.intelKeys,now:now)
        }
        var values = ["TC1C":reading(100),"TC2C":reading(80),"TC0E":reading(120),"TC0P":reading(65)]
        let first = summarizeIntel(values)
        check(first.maximum.value == 100 && first.average.value == 90 && first.count == 2,"maximum and mean use valid cores only")
        values["TC1c"] = reading(110)
        check(summarizeIntel(values).count == 2,"core aliases are not counted twice")
        check(summarizeIntel(values).maximum.value == 100,"uppercase core wins when both aliases available")
        values["TC1C"] = reading(100,20)
        check(summarizeIntel(values).maximum.value == 110,"lowercase fallback when uppercase stale")
        values["TC1c"] = reading(110,20)
        check(summarizeIntel(values).maximum.value == 80,"stale high core is excluded")
        values["TC2C"] = reading(80,0,"unavailable")
        check(summarizeIntel(values).count == 0,"error marked core rejected")
        let missing = summarizeIntel(["TC0E":reading(99),"TC0P":reading(70)])
        check(missing.maximum.value == nil && missing.maximum.error != nil && missing.average.value == nil,"no diode or proximity substitution on missing cores")
        check(summarizeIntel(["TC1C":reading(126),"TC2C":reading(9),"TC3C":reading(.nan)]).count == 0,"out of range and nonfinite rejected")
        check(summarizeIntel(["TC1C":reading(99,-10)]).count == 0,"future reading rejected")
        let timestamp = summarizeIntel(["TC1C":reading(90,3),"TC2C":reading(88,5)]).maximum.sampledAt
        check(timestamp == now.addingTimeInterval(-5),"aggregate retains oldest contributing timestamp")
        var snapshot = MetricsSnapshot(); snapshot.readings[MetricID.cpuTemperature.rawValue] = first.maximum
        check(snapshot.text(for:MetricID.cpuTemperature.rawValue,now:now) == "CPU 100°C","short display retains core maximum")
        check(MetricThresholds.level(MetricID.cpuTemperature.rawValue,snapshot:snapshot,now:now) == .critical,"100C core is red")
        check(MetricThresholds.level(MetricID.cpuTemperature.rawValue,snapshot:snapshot,now:now.addingTimeInterval(13)) == .unavailable,"expired aggregate clears color")
        let original:[String:Any] = ["order":["x"],"scripts":[],"cpuTemperatureKey":"TC0P","metricThresholds":["system.cpuTemperature":[75,85],"system.cpu":[70,90]],"future":42]
        let migrated = CoreTemperature.migratedConfiguration(original)
        check(migrated["cpuTemperatureKey"] as? String == CoreTemperature.selection,"upgrade selects cores")
        let thresholds = migrated["metricThresholds"] as? [String:Any]
        check(thresholds?["system.cpuTemperature"] as? [Int] == [85,95] && thresholds?["system.cpu"] as? [Int] == [70,90],"upgrade changes only temperature thresholds")
        check(migrated["future"] as? Int == 42 && migrated["order"] as? [String] == ["x"],"upgrade preserves other configuration")
        var manual = migrated; manual["cpuTemperatureKey"] = "TC0P"
        check(CoreTemperature.migratedConfiguration(manual)["cpuTemperatureKey"] as? String == "TC0P","subsequent manual sensor choice is retained")
        let limits = [CPUPowerStatus.speedKey:reading(48),CPUPowerStatus.schedulerKey:reading(100)]
        check(CPUPowerStatus.text(limits,now:now).contains("已报告限制") && CPUPowerStatus.text(limits,now:now).contains("48%"),"system speed restriction visible")
        check(CPUPowerStatus.text([CPUPowerStatus.speedKey:reading(100),CPUPowerStatus.schedulerKey:reading(80)],now:now).contains("已报告限制"),"scheduler restriction visible")
        check(CPUPowerStatus.text([CPUPowerStatus.speedKey:reading(100),CPUPowerStatus.schedulerKey:reading(100)],now:now).contains("未报告速度"),"no current speed or scheduler limit")
        check(CPUPowerStatus.text([:],now:now).contains("未知") && CPUPowerStatus.text(limits,now:now.addingTimeInterval(20)).contains("未知"),"missing and stale limits remain unknown")
        check(CPUPowerStatus.text([CPUPowerStatus.speedKey:reading(101)],now:now).contains("未知"),"impossible limit rejected")
        print("\(count) core temperature and performance checks passed")
    }
}
