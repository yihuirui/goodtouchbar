import AppKit
import SystemMonitoring

@MainActor
final class SystemMetricsMonitor: NSObject {
    private let machQueue = DispatchQueue(label: "io.github.yihuirui.goodtouchbar.metrics.mach", qos: .utility)
    private let sensorQueue = DispatchQueue(label: "io.github.yihuirui.goodtouchbar.metrics.sensors", qos: .utility)
    private let reader = MachMetricsReader()
    private let client: SensorProcessClient
    private let cpuTemperatureKeys: [String]
    private let log = MonitorEventLog(url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GoodTouchBar/system-monitor-events.jsonl"))
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var machBusy = false, sensorBusy = false, sleeping = false
    private var nextMach: TimeInterval = 0, nextSensors: TimeInterval = 0
    private var machError: String?
    private var failures = 0, generation = 0
    private var enabled: Set<String> = []
    var detailed = false
    var performancePage = false
    private(set) var history = MetricHistory()
    var cpuTemperatureKey = CoreTemperature.selection
    private(set) var snapshot = MetricsSnapshot()
    private(set) var temperatureReadings: [String: MetricReading] = [:]
    var onChange: (() -> Void)?
    init(sensorExecutable: URL? = nil, cpuTemperatureKeys: [String]? = nil) {
        let eventLog = log
        self.cpuTemperatureKeys = cpuTemperatureKeys ?? CoreTemperature.keys
        client = SensorProcessClient(executable: sensorExecutable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/GoodTouchSensors"), event: { event, fields in eventLog.record(event, fields: fields) })
        super.init()
    }
    func configure(keys: [String], cpuTemperatureKey: String) {
        let changed = enabled != Set(keys) || self.cpuTemperatureKey != cpuTemperatureKey
        enabled = Set(keys); self.cpuTemperatureKey = cpuTemperatureKey
        if changed { machQueue.async { [reader] in reader.reset() }; generation += 1; nextMach = 0; nextSensors = 0; failures = 0; snapshot = MetricsSnapshot(); temperatureReadings = [:]; history = MetricHistory() }
        tick()
    }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setSleeping(false) }
        })
        log.record("monitor_started"); tick()
    }
    func stop() {
        let wasRunning = timer != nil
        timer?.invalidate(); timer = nil; generation += 1
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        client.stop(); if wasRunning { log.record("monitor_stopped") }
    }
    private func setSleeping(_ value: Bool) {
        sleeping = value; generation += 1; snapshot = MetricsSnapshot(); temperatureReadings = [:]; client.stop()
        machQueue.async { [reader] in reader.reset() }
        nextMach = 0; nextSensors = 0; failures = 0
        log.record(value ? "sleep" : "wake"); onChange?(); if !value { tick() }
    }
    private func tick() {
        guard !sleeping else { return }
        let now = ProcessInfo.processInfo.systemUptime, gen = generation
        let activeKeys = performancePage ? enabled.union(MetricID.performancePreset) : enabled
        let ids = activeKeys.compactMap(MetricID.init(rawValue:))
        if (detailed || ids.contains { !$0.needsSensors }) && !machBusy && now >= nextMach {
            machBusy = true; nextMach = now + (detailed ? 1 : 2)
            machQueue.async { [weak self, reader] in
                let readings = reader.read()
                DispatchQueue.main.async {
                    guard let self else { return }; self.machBusy = false
                    guard self.generation == gen else { return }
                    let error = readings.values.compactMap(\.error).first
                    if error != self.machError {
                        self.log.record(error == nil ? "mach_recovered" : "mach_failed", code: error)
                        self.machError = error
                    }
                    self.snapshot.readings.merge(readings) { _, new in new }; self.history.append(self.snapshot); self.onChange?()
                }
            }
        }
        let wantsSensors = detailed || ids.contains { $0.needsSensors }
        if !wantsSensors { client.stop() }
        guard wantsSensors, !sensorBusy, now >= nextSensors else { return }
        var keys: [String] = []
        if detailed { keys = SMCReader.temperatureKeys }
        else {
            if activeKeys.contains(MetricID.cpuTemperature.rawValue) { keys += cpuTemperatureKey == CoreTemperature.selection ? cpuTemperatureKeys : [cpuTemperatureKey] }
            if activeKeys.contains(MetricID.gpuTemperature.rawValue) { keys.append("TG0P") }
            if activeKeys.contains(MetricID.batteryTemperature.rawValue) { keys.append("TB0T") }
        }
        let request = SensorRequest(temperatureKeys: keys, includeFans: detailed || ids.contains { [.fans,.fan0,.fan1].contains($0) })
        let selectedKey = cpuTemperatureKey
        sensorBusy = true; nextSensors = now + (detailed ? 1 : 3)
        sensorQueue.async { [weak self, client] in
            let result = Result { try client.sample(request) }
            DispatchQueue.main.async {
                guard let self else { return }; self.sensorBusy = false
                guard self.generation == gen else { return }
                switch result {
                case .success(let response):
                    self.temperatureReadings = response.temperatures; self.snapshot.fans = response.fans
                    let core = CoreTemperature.summarize(response.temperatures, keys: self.cpuTemperatureKeys)
                    self.snapshot.readings["cpu.coreMax"] = core.maximum
                    self.snapshot.readings["cpu.coreAverage"] = core.average
                    self.snapshot.readings["cpu.coreCount"] = MetricReading(core.count > 0 ? Double(core.count) : nil, unit:"cores", source:"AppleSMC CPU cores", sampledAt:core.maximum.sampledAt)
                    for (id,key) in [(MetricID.cpuTemperature,selectedKey),(.gpuTemperature,"TG0P"),(.batteryTemperature,"TB0T")] {
                        self.snapshot.readings[id.rawValue] = (key == CoreTemperature.selection ? core.maximum : response.temperatures[key]) ?? MetricReading(nil, unit: "°C", source: "AppleSMC \(key)", error: "sensor_unavailable")
                    }
                    for fan in response.fans {
                        self.snapshot.readings["system.fan\(fan.id)"] = MetricReading(fan.actual, unit: "RPM", source: "AppleSMC F\(fan.id)Ac", sampledAt: response.sampledAt)
                    }
                    self.snapshot.readings[MetricID.fans.rawValue] = MetricReading(response.fans.isEmpty || response.fans.contains { $0.actual == nil } ? nil : 1, unit: "fans", source: "AppleSMC", sampledAt: response.sampledAt)
                    self.setSensorFailure(response.error)
                case .failure:
                    self.temperatureReadings = [:]; self.snapshot.fans = []
                    for key in ["cpu.coreMax","cpu.coreAverage","cpu.coreCount"] { self.snapshot.readings.removeValue(forKey:key) }
                    for id in MetricID.allCases where id.needsSensors {
                        self.snapshot.readings[id.rawValue] = MetricReading(nil, unit: "", source: "AppleSMC", error: "sensor_service_failed")
                    }
                    self.setSensorFailure("sensor_service_failed")
                }
                self.history.append(self.snapshot); self.onChange?()
            }
        }
    }
    private func setSensorFailure(_ code: String?) {
        if let code {
            if snapshot.sensorError != code { log.record("sensor_failed", code: code) }
            failures += 1; nextSensors = ProcessInfo.processInfo.systemUptime + min(60, pow(2, Double(min(failures, 5))))
        } else {
            if snapshot.sensorError != nil { log.record("sensor_recovered") }
            failures = 0
        }
        snapshot.sensorError = code
    }
}
