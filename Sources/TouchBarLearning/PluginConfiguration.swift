import AppKit
import Darwin
import Foundation
import SystemMonitoring
import os.log

private let pluginLogger = Logger(
    subsystem: "io.github.yihuirui.goodtouchbar",
    category: "Plugins"
)

enum TouchBarPluginKey {
    static let gptStatus = "gpt.status"
    static let gptUsage = "gpt.usage"
    static let workbuddy = "workbuddy.status"
    static let agentSpeed = "agent.speed"
    /// Build42 用过这个键，Build43 起统一为 `agent.speed`，迁移时就地改名。
    static let legacyAgentSpeed = "workbuddy.speed"
    static let todayTokens = "tokens.today"
    static let pomodoro = "pomodoro"
    static let pomodoroReset = "pomodoro.reset"
    static let systemControls = "system.controls"

    static let defaultOrder = [
        gptStatus,
        gptUsage,
        workbuddy,
        agentSpeed,
        todayTokens,
        pomodoro,
    ]

    static let allBuiltIns = defaultOrder + [pomodoroReset, systemControls] + MetricID.allCases.map(\.rawValue)
}

struct TouchBarScriptPluginDefinition: Codable {
    let id: String
    let name: String
    let script: String
    let refreshSeconds: TimeInterval?
    let actionScript: String?
    let icon: String?

    var enabled: Bool? = nil
    var isEnabled: Bool { enabled ?? true }

    var key: String {
        "script.\(id)"
    }
}

struct TouchBarPluginConfiguration: Codable {
    let order: [String]
    let scripts: [TouchBarScriptPluginDefinition]
    var version: Int? = nil
    var menuOrder: [String]? = nil
    var catalogOrder: [String]? = nil
    var cpuTemperatureKey: String? = nil
    var metricThresholds: [String:[Double]]? = nil

    static let defaultConfiguration = TouchBarPluginConfiguration(
        order: TouchBarPluginKey.defaultOrder,
        scripts: []
    )
}

private enum PluginConfigurationError: LocalizedError {
    case invalidIdentifier(String)
    case duplicateIdentifier(String)
    case missingName(String)
    case missingScript(String)

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let id):
            return "脚本插件 id“\(id)”只能包含字母、数字、下划线和短横线"
        case .duplicateIdentifier(let id):
            return "脚本插件 id“\(id)”重复"
        case .missingName(let id):
            return "脚本插件“\(id)”缺少 name"
        case .missingScript(let id):
            return "脚本插件“\(id)”缺少 script"
        }
    }
}

@MainActor
final class ScriptPluginRuntime: NSObject {
    let definition: TouchBarScriptPluginDefinition

    private(set) var displayText: String
    private(set) var image: NSImage?
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var runningProcess: BoundedProcess?

    init(definition: TouchBarScriptPluginDefinition) {
        self.definition = definition
        displayText = definition.isEnabled ? "\(definition.name) …" : "\(definition.name) · 已停用"
        image = Self.loadImage(at: definition.icon)
        super.init()
    }

    func start() {
        guard definition.isEnabled else { return }
        refresh()

        timer?.invalidate()
        let interval = min(max(definition.refreshSeconds ?? 30, 5), 3600)
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(handleTimer),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        runningProcess?.cancel()
        runningProcess = nil
    }

    func refresh() {
        guard definition.isEnabled else { return }
        execute(
            scriptPath: definition.script,
            updatesDisplay: true,
            refreshAfterSuccess: false
        )
    }

    @objc func handleTouchBarAction() {
        guard definition.isEnabled else { return }
        guard let actionScript = definition.actionScript,
              !actionScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            refresh()
            return
        }

        execute(
            scriptPath: actionScript,
            updatesDisplay: false,
            refreshAfterSuccess: true
        )
    }

    @objc private func handleTimer() {
        refresh()
    }

    private func execute(
        scriptPath: String,
        updatesDisplay: Bool,
        refreshAfterSuccess: Bool
    ) {
        guard runningProcess == nil else { return }

        let expandedPath = Self.expandedPath(scriptPath)
        if let validationError = Self.scriptValidationError(at: expandedPath) {
            displayText = "⚠ \(definition.name)"
            onChange?()
            pluginLogger.error(
                "Plugin script rejected: \(validationError, privacy: .public)"
            )
            return
        }

        let process = BoundedProcess()
        runningProcess = process
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = process.run(executable: "/bin/zsh", arguments: ["-f", expandedPath], timeout: 5, stdoutLimit: 16*1024, stderrLimit: 4096)
            DispatchQueue.main.async {
                guard let self, self.runningProcess === process else { return }
                self.runningProcess = nil
                guard result.succeeded else {
                    self.displayText = "⚠ \(self.definition.name)"; self.onChange?()
                    let code = result.failure ?? "exit_\(result.exitCode)"
                    pluginLogger.error("Plugin failed: \(code, privacy: .public)")
                    return
                }
                if updatesDisplay {
                    self.displayText = Self.normalizedOutput(String(decoding: result.stdout, as: UTF8.self), fallback: self.definition.name)
                    self.onChange?()
                } else if refreshAfterSuccess { self.refresh() }
            }
        }
    }

    private static func normalizedOutput(_ output: String, fallback: String) -> String {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let line, !line.isEmpty else { return fallback }
        if line.count <= 32 { return line }
        return String(line.prefix(31)) + "…"
    }

    private static func expandedPath(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path
            + String(path.dropFirst())
    }

    private static func scriptValidationError(at path: String) -> String? {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return "脚本不存在或不是普通文件：\(path)"
        }

        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            return "无法读取脚本权限：\(path)"
        }
        guard permissions & 0o022 == 0 else {
            return "脚本不可由组或其他用户写入：\(path)"
        }
        return nil
    }


    private static func loadImage(at path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let image = NSImage(contentsOfFile: expandedPath(path))
        image?.isTemplate = false
        return image
    }
}

@MainActor
final class TouchBarPluginManager {
    private static let scriptIdentifierPrefix =
        "io.github.yihuirui.goodtouchbar.script."

    let configurationURL: URL
    private(set) var configuration = TouchBarPluginConfiguration.defaultConfiguration
    private(set) var lastError: String?

    var onChange: (() -> Void)?

    private var runtimesByKey: [String: ScriptPluginRuntime] = [:]
    private var started = false
    private var loadedData: Data?

    init(configurationURL: URL? = nil) {
        if let configurationURL {
            self.configurationURL = configurationURL
        } else {
            self.configurationURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
                .appendingPathComponent("GoodTouchBar", isDirectory: true)
                .appendingPathComponent("plugins.json")
        }

        _ = reload()
    }

    var visibleKeys: [String] {
        normalizedKeys(configuration.order).filter { key in !configuration.scripts.contains { $0.key == key && !$0.isEnabled } }
    }

    var allKeys: [String] {
        normalizedKeys(
            TouchBarPluginKey.allBuiltIns + configuration.scripts.map(\.key)
        )
    }

    var scriptRuntimes: [ScriptPluginRuntime] {
        configuration.scripts.compactMap { runtimesByKey[$0.key] }
    }

    func start() {
        started = true
        scriptRuntimes.forEach { $0.start() }
    }

    func stop() {
        started = false
        runtimesByKey.values.forEach { $0.stop() }
    }

    @discardableResult
    func reload() -> String? {
        do {
            try ensureConfigurationFile()
            var data = try Data(contentsOf: configurationURL)
            let beforeMigration = try JSONDecoder().decode(TouchBarPluginConfiguration.self,from:data)
            try validate(beforeMigration)
            if let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], (object["coreTemperatureDisplayVersion"] as? Int ?? 0) < 1 {
                let migrated = CoreTemperature.migratedConfiguration(object)
                let updated = try JSONSerialization.data(withJSONObject:migrated,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
                try validate(JSONDecoder().decode(TouchBarPluginConfiguration.self,from:updated))
                let backup = configurationURL.appendingPathExtension("before-build40")
                if !FileManager.default.fileExists(atPath:backup.path) { try data.write(to:backup,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path) }
                try updated.write(to:configurationURL,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configurationURL.path)
                data = updated
            }
            if let object = try JSONSerialization.jsonObject(with:data) as? [String:Any], (object["agentSpeedVersion"] as? Int ?? 0) < 1 {
                // 已有配置里补上「AI 速度」项：Build42 的 workbuddy.speed 就地改名，
                // 否则紧跟 WB 状态插入，其余顺序不变。
                var migrated = object
                func migrating(_ list: [String]) -> [String] {
                    var copy = list.map { $0 == TouchBarPluginKey.legacyAgentSpeed ? TouchBarPluginKey.agentSpeed : $0 }
                    guard !copy.contains(TouchBarPluginKey.agentSpeed) else { return copy }
                    if let index = copy.firstIndex(of: TouchBarPluginKey.workbuddy) { copy.insert(TouchBarPluginKey.agentSpeed, at: index + 1) }
                    else { copy.append(TouchBarPluginKey.agentSpeed) }
                    return copy
                }
                migrated["order"] = migrating(migrated["order"] as? [String] ?? TouchBarPluginKey.defaultOrder)
                migrated["catalogOrder"] = migrating(migrated["catalogOrder"] as? [String] ?? (migrated["order"] as? [String] ?? TouchBarPluginKey.defaultOrder))
                migrated["agentSpeedVersion"] = 1
                let updated = try JSONSerialization.data(withJSONObject:migrated,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
                try validate(JSONDecoder().decode(TouchBarPluginConfiguration.self,from:updated))
                let backup = configurationURL.appendingPathExtension("before-build43")
                if !FileManager.default.fileExists(atPath:backup.path) { try data.write(to:backup,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path) }
                try updated.write(to:configurationURL,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configurationURL.path)
                data = updated
            }
            if loadedData == data { lastError = nil; return nil }
            let decoded = try JSONDecoder().decode(
                TouchBarPluginConfiguration.self,
                from: data
            )
            try validate(decoded)

            runtimesByKey.values.forEach { $0.stop() }
            configuration = decoded; loadedData = data
            runtimesByKey = Dictionary(
                uniqueKeysWithValues: decoded.scripts.map { definition in
                    let runtime = ScriptPluginRuntime(definition: definition)
                    runtime.onChange = { [weak self] in
                        self?.onChange?()
                    }
                    return (definition.key, runtime)
                }
            )
            lastError = nil

            if started {
                scriptRuntimes.forEach { $0.start() }
            }
            pluginLogger.notice(
                "Loaded \(decoded.scripts.count) script plugins"
            )
            return nil
        } catch {
            lastError = "插件配置读取失败：\(error.localizedDescription)"
            pluginLogger.error("\(self.lastError ?? "unknown plugin error", privacy: .public)")
            return lastError
        }
    }

    func openConfiguration() {
        do {
            try ensureConfigurationFile()
            NSWorkspace.shared.open(configurationURL)
        } catch {
            lastError = "无法创建插件配置：\(error.localizedDescription)"
            pluginLogger.error("\(self.lastError ?? "unknown plugin error", privacy: .public)")
        }
    }

    func runtime(for identifier: NSTouchBarItem.Identifier) -> ScriptPluginRuntime? {
        let rawValue = identifier.rawValue
        guard rawValue.hasPrefix(Self.scriptIdentifierPrefix) else { return nil }
        let id = String(rawValue.dropFirst(Self.scriptIdentifierPrefix.count))
        return runtimesByKey["script.\(id)"]
    }

    func identifier(for key: String) -> NSTouchBarItem.Identifier? {
        guard key.hasPrefix("script."),
              let runtime = runtimesByKey[key]
        else {
            return nil
        }
        return NSTouchBarItem.Identifier(
            Self.scriptIdentifierPrefix + runtime.definition.id
        )
    }

    var menuKeys: [String] {
        normalizedKeys(configuration.menuOrder ?? [TouchBarPluginKey.gptUsage, TouchBarPluginKey.todayTokens, TouchBarPluginKey.pomodoro]).filter { key in !configuration.scripts.contains { $0.key == key && !$0.isEnabled } }
    }

    var catalogKeys: [String] {
        normalizedKeys((configuration.catalogOrder ?? configuration.order) + allKeys)
    }

    var selectedCPUTemperatureKey: String { configuration.cpuTemperatureKey ?? CoreTemperature.selection }

    func saveDisplay(order: [String], menuOrder: [String], catalogOrder: [String], cpuTemperatureKey: String) throws {
        guard [CoreTemperature.selection, "TC0E", "TC0F", "TC0P"].contains(cpuTemperatureKey) else {
            throw NSError(domain: "DisplayConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: "CPU 传感器无效"])
        }
        // Merge into the existing JSON object to retain unknown fields and future/plugin definitions.
        let original = try Data(contentsOf: configurationURL)
        var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] ?? [:]
        let known = Set(allKeys)
        let unknown = configuration.order.filter { !known.contains($0) }
        object["version"] = 2
        object["order"] = DisplayLayout.unique(order + unknown)
        object["menuOrder"] = DisplayLayout.unique(menuOrder)
        object["catalogOrder"] = DisplayLayout.unique(catalogOrder + (configuration.catalogOrder ?? []).filter { !known.contains($0) })
        object["cpuTemperatureKey"] = cpuTemperatureKey
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let decoded = try JSONDecoder().decode(TouchBarPluginConfiguration.self, from: data)
        try validate(decoded)
        let backup = configurationURL.appendingPathExtension("before-build33")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try original.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        configuration = decoded; loadedData = data; lastError = nil; onChange?()
    }

    func configurationData() throws -> Data { try Data(contentsOf: configurationURL) }

    /// 迁移留下的备份文件，最新在前。
    ///
    /// 每次结构性迁移都会写一份 `plugins.json.before-buildXX`，但此前没有任何代码能把它们读回来，
    /// 备份等于摆设。这里给出可枚举、可恢复的入口。
    var availableBackups: [URL] {
        let directory = configurationURL.deletingLastPathComponent()
        let prefix = configurationURL.lastPathComponent + ".before-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) }
            .compactMap { name -> (URL, Date)? in
                let url = directory.appendingPathComponent(name)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// 用最新的可用备份覆盖当前配置。
    ///
    /// 恢复前先把当前文件另存一份 `before-restore-<时间戳>`，让"恢复"本身也可回退。
    /// 恢复后走一次 `reload()`，旧格式会按现有迁移链重新补齐，不需要单独写降级逻辑。
    @discardableResult
    func restoreLatestBackup() throws -> URL {
        guard let backup = availableBackups.first else {
            throw NSError(domain: "Configuration", code: 4, userInfo: [NSLocalizedDescriptionKey: "没有可用的配置备份"])
        }
        let data = try Data(contentsOf: backup)
        // 先验证再落盘：坏备份不能把可用配置顶掉。
        try validate(try JSONDecoder().decode(TouchBarPluginConfiguration.self, from: data))

        let current = try configurationData()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safety = configurationURL.appendingPathExtension("before-restore-\(formatter.string(from: Date()))")
        if !FileManager.default.fileExists(atPath: safety.path) {
            try current.write(to: safety, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: safety.path)
        }

        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        if let error = reload() { throw NSError(domain: "Configuration", code: 5, userInfo: [NSLocalizedDescriptionKey: error]) }
        return backup
    }

    func saveThresholds(_ values: [String:[Double]]) throws {
        guard MetricThresholds.valid(values) else { throw NSError(domain:"Configuration",code:1,userInfo:[NSLocalizedDescriptionKey:"阈值须为有效数字，橙色值小于红色值，并在允许范围内。"] ) }
        let original = try configurationData()
        var object = try JSONSerialization.jsonObject(with:original) as? [String:Any] ?? [:]
        object["metricThresholds"] = values
        try commitObject(object, original:original)
    }

    func applyPreset(_ preset: GoodTouchBarLayoutPreset) throws {
        try preset.validate()
        let original = try configurationData()
        var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] ?? [:]
        // Script definitions remain installed and in their previous relative position;
        // portable presets never contain script bodies or install anything.
        let customKeys = configuration.order.filter { !GoodTouchBarLayoutPreset.allowedLayoutKeys.contains($0) }
        let currentMenuOrder = configuration.menuOrder ?? [TouchBarPluginKey.gptUsage, TouchBarPluginKey.todayTokens, TouchBarPluginKey.pomodoro]
        let customMenuKeys = currentMenuOrder.filter { !GoodTouchBarLayoutPreset.allowedLayoutKeys.contains($0) }
        object["order"] = DisplayLayout.unique(preset.layout + customKeys)
        object["menuOrder"] = DisplayLayout.unique(preset.menuLayout + customMenuKeys)
        object["metricThresholds"] = preset.thresholds

        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backup = configurationURL.appendingPathExtension("before-preset-\(date.string(from: Date()))")
        try original.write(to: backup, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try commitObject(object, original: original)
    }

    /// Expected bytes prevent a stale editor from overwriting concurrent edits.
    func saveScripts(_ scripts: [TouchBarScriptPluginDefinition], expected: Data, barKeys: Set<String>, menuKeys: Set<String>) throws {
        for plugin in scripts {
            if let interval = plugin.refreshSeconds, !interval.isFinite || !(5...3600).contains(interval) { throw NSError(domain:"Configuration",code:1,userInfo:[NSLocalizedDescriptionKey:"刷新间隔应为 5–3600 秒"]) }
        }
        let original = try configurationData()
        guard original == expected else { throw NSError(domain:"Configuration",code:2,userInfo:[NSLocalizedDescriptionKey:"配置已在其他窗口修改，请重新载入后再保存。"] ) }
        var object = try JSONSerialization.jsonObject(with:original) as? [String:Any] ?? [:]
        let previous = object["scripts"] as? [[String:Any]] ?? []
        object["scripts"] = try scripts.map { definition -> [String:Any] in
            var item = previous.first { $0["id"] as? String == definition.id } ?? [:]
            guard let encoded = try JSONSerialization.jsonObject(with:JSONEncoder().encode(definition)) as? [String:Any] else {
                // 不用 `as!`：序列化失败应该抛错给用户，而不是让 App 在保存时崩掉。
                throw NSError(domain:"Configuration",code:3,userInfo:[NSLocalizedDescriptionKey:"脚本插件“\(definition.id)”无法序列化，未保存"])
            }
            for key in ["id","name","script","actionScript","icon","refreshSeconds","enabled"] { item.removeValue(forKey:key) }
            item.merge(encoded) { _,new in new }; return item
        }
        let oldKeys = Set(previous.compactMap { ($0["id"] as? String).map { "script."+$0 } })
        let newKeys = scripts.map(\.key), allScriptKeys = oldKeys.union(newKeys)
        for (field,selected) in [("order",barKeys),("menuOrder",menuKeys)] {
            let defaults = field == "order" ? configuration.order : (configuration.menuOrder ?? [TouchBarPluginKey.gptUsage,TouchBarPluginKey.todayTokens,TouchBarPluginKey.pomodoro])
            let order = object[field] as? [String] ?? defaults
            object[field] = DisplayLayout.unique(order.filter { !allScriptKeys.contains($0) || selected.contains($0) && newKeys.contains($0) } + newKeys.filter { selected.contains($0) })
        }
        object["catalogOrder"] = DisplayLayout.unique((object["catalogOrder"] as? [String] ?? configuration.order).filter { !oldKeys.contains($0) || newKeys.contains($0) } + newKeys)
        try commitObject(object,original:original)
    }
    private func commitObject(_ object:[String:Any],original:Data) throws {
        let data = try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        let decoded = try JSONDecoder().decode(TouchBarPluginConfiguration.self,from:data)
        try validate(decoded)
        let backup = configurationURL.appendingPathExtension("before-build38")
        if !FileManager.default.fileExists(atPath:backup.path) { try original.write(to:backup,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path) }
        try data.write(to:configurationURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:configurationURL.path)
        if try JSONEncoder().encode(configuration.scripts) == JSONEncoder().encode(decoded.scripts) {
            configuration = decoded; loadedData = data; lastError = nil; onChange?(); return
        }
        // The same validated bytes are installed in memory, without a second disk read.
        runtimesByKey.values.forEach { $0.stop() }
        configuration = decoded; loadedData = data
        runtimesByKey = Dictionary(uniqueKeysWithValues:decoded.scripts.map { definition in
            let runtime = ScriptPluginRuntime(definition:definition)
            runtime.onChange = { [weak self] in self?.onChange?() }
            return (definition.key,runtime)
        })
        lastError = nil
        if started { scriptRuntimes.forEach { $0.start() } }
        onChange?()
    }

    func refreshScripts() {
        scriptRuntimes.forEach { $0.refresh() }
    }

    private func ensureConfigurationFile() throws {
        let directory = configurationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        guard !FileManager.default.fileExists(atPath: configurationURL.path) else {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configurationURL.path
            )
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(TouchBarPluginConfiguration.defaultConfiguration)
        try data.write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: configurationURL.path
        )
    }

    private func validate(_ configuration: TouchBarPluginConfiguration) throws {
        if let limits = configuration.metricThresholds, !MetricThresholds.valid(limits) { throw NSError(domain:"Configuration",code:1,userInfo:[NSLocalizedDescriptionKey:"指标阈值无效"]) }
        var ids = Set<String>()
        for plugin in configuration.scripts {

            guard plugin.id.range(
                of: "^[A-Za-z0-9_-]+$",
                options: .regularExpression
            ) != nil else {
                throw PluginConfigurationError.invalidIdentifier(plugin.id)
            }
            guard ids.insert(plugin.id).inserted else {
                throw PluginConfigurationError.duplicateIdentifier(plugin.id)
            }
            guard !plugin.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginConfigurationError.missingName(plugin.id)
            }
            guard !plugin.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginConfigurationError.missingScript(plugin.id)
            }
        }
    }

    private func normalizedKeys(_ keys: [String]) -> [String] {
        let validBuiltIns = Set(TouchBarPluginKey.allBuiltIns)
        let validScripts = Set(runtimesByKey.keys)
        var seen = Set<String>()

        return keys.filter { key in
            guard validBuiltIns.contains(key) || validScripts.contains(key) else {
                return false
            }
            return seen.insert(key).inserted
        }
    }
}
