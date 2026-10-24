import Foundation
import Darwin
import IOKit.pwr_mgt

/// Confined to the monitor's worker queue. No subprocesses and no UI work.
public final class MachMetricsReader: @unchecked Sendable {
    private let lock = NSLock()
    private var previous: CPUCounters?
    public init() {}
    public func reset() { lock.lock(); defer { lock.unlock() }; previous = nil }
    public func read() -> [String: MetricReading] {
        lock.lock(); defer { lock.unlock() }
        var readings: [String: MetricReading] = [:]
        let now = Date()
        var cpu = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if cpuResult == KERN_SUCCESS {
            let counters = CPUCounters(user: cpu.cpu_ticks.0, system: cpu.cpu_ticks.1, nice: cpu.cpu_ticks.3, idle: cpu.cpu_ticks.2)
            readings[MetricID.cpu.rawValue] = MetricReading(counters.utilization(since: previous), unit: "%", source: "Mach CPU ticks", sampledAt: now)
            previous = counters
        } else { previous = nil; readings[MetricID.cpu.rawValue] = MetricReading(nil, unit: "%", source: "Mach", sampledAt: now, error: "cpu_read_failed") }
        var vm = vm_statistics64_data_t()
        count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        readings["memory.total"] = MetricReading(total, unit: "bytes", source: "physicalMemory", sampledAt: now)
        let used = vmResult == KERN_SUCCESS ? MemoryMath.used(total: total, active: UInt64(vm.active_count), inactive: UInt64(vm.inactive_count), speculative: UInt64(vm.speculative_count), wired: UInt64(vm.wire_count), compressed: UInt64(vm.compressor_page_count), purgeable: UInt64(vm.purgeable_count), external: UInt64(vm.external_page_count), pageSize: Double(vm_page_size)) : nil
        readings[MetricID.memory.rawValue] = MetricReading(used, unit: "bytes", source: "Mach VM (excluding cache)", sampledAt: now, error: used == nil ? "memory_read_failed" : nil)
        readings["memory.compressed"] = MetricReading(vmResult == KERN_SUCCESS ? Double(vm.compressor_page_count) * Double(vm_page_size) : nil, unit: "bytes", source: "Mach VM", sampledAt: now)
        var pressure: Int32 = 0; var size = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0)
        readings[MetricID.pressure.rawValue] = MetricReading(pressureResult == 0 && [1,2,4].contains(pressure) ? Double(pressure) : nil, unit: "level", source: "memorystatus_vm_pressure_level", sampledAt: now)
        var swap = xsw_usage(); size = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        readings[MetricID.swap.rawValue] = MetricReading(swapResult == 0 ? Double(swap.xsu_used) : nil, unit: "bytes", source: "vm.swapusage", sampledAt: now)
        var power: Unmanaged<CFDictionary>?
        let powerResult = IOPMCopyCPUPowerStatus(&power)
        let dictionary = power?.takeRetainedValue() as? [String:Any] ?? [:]
        for (key,raw) in [(CPUPowerStatus.speedKey,"CPU_Speed_Limit"),(CPUPowerStatus.schedulerKey,"CPU_Scheduler_Limit"),(CPUPowerStatus.countKey,"CPU_Available_CPUs")] {
            let value = (dictionary[raw] as? NSNumber)?.doubleValue
            let limit = key == CPUPowerStatus.countKey ? Double(ProcessInfo.processInfo.processorCount) : 100
            let valid = powerResult == kIOReturnSuccess ? value.flatMap { $0.isFinite && $0 >= 0 && $0 <= limit ? $0 : nil } : nil
            readings[key] = MetricReading(valid,unit:key == CPUPowerStatus.countKey ? "cores" : "%",source:"IOPM " + raw,sampledAt:now)
        }
        return readings
    }
}
