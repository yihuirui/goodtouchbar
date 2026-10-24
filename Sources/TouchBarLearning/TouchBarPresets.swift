import Foundation
import SystemMonitoring

/// Portable layout-only format. It deliberately has no command, script, retry,
/// helper-install, or fan-control fields.
struct GoodTouchBarLayoutPreset: Codable, Equatable {
    static let schema = "goodtouchbar-layout"
    static let schemaVersion = 2
    static let maximumBytes = 64 * 1024

    let schema: String
    let schemaVersion: Int
    let name: String
    let layout: [String]
    let menuLayout: [String]
    let thresholds: [String: [Double]]

    init(name: String, layout: [String], menuLayout: [String]? = nil, thresholds: [String: [Double]]) {
        self.schema = Self.schema
        self.schemaVersion = Self.schemaVersion
        self.name = name
        self.layout = layout
        self.menuLayout = menuLayout ?? layout
        self.thresholds = thresholds
    }

    static let allowedLayoutKeys: Set<String> = Set(
        TouchBarPluginKey.allBuiltIns + MetricID.allCases.map(\.rawValue)
    )

    static func decode(_ data: Data) throws -> GoodTouchBarLayoutPreset {
        guard data.count <= maximumBytes else { throw PresetError.tooLarge }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PresetError.invalidDocument
        }
        guard object["schema"] as? String == Self.schema,
              let version = object["schemaVersion"] as? Int else { throw PresetError.invalidDocument }
        let requiredFields: Set<String>
        switch version {
        case 1: requiredFields = ["schema", "schemaVersion", "name", "layout", "thresholds"]
        case 2: requiredFields = ["schema", "schemaVersion", "name", "layout", "menuLayout", "thresholds"]
        default: throw PresetError.unsupportedVersion
        }
        guard Set(object.keys) == requiredFields else { throw PresetError.unknownField }

        var normalized = object
        normalized["schemaVersion"] = Self.schemaVersion
        if version == 1 { normalized["menuLayout"] = object["layout"] }
        let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
        let preset = try JSONDecoder().decode(Self.self, from: normalizedData)
        try preset.validate()
        return preset
    }

    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw PresetError.tooLarge }
        return data
    }

    func validate() throws {
        guard schema == Self.schema, schemaVersion == Self.schemaVersion else {
            throw PresetError.unsupportedVersion
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 48 else { throw PresetError.invalidName }
        guard !layout.isEmpty, layout.count <= 20,
              !menuLayout.isEmpty, menuLayout.count <= 20 else { throw PresetError.invalidLayout }
        guard Set(layout).count == layout.count else { throw PresetError.duplicateItem }
        guard Set(menuLayout).count == menuLayout.count else { throw PresetError.duplicateItem }
        guard layout.allSatisfy(Self.allowedLayoutKeys.contains) else { throw PresetError.unknownMetric }
        guard menuLayout.allSatisfy(Self.allowedLayoutKeys.contains) else { throw PresetError.unknownMetric }
        guard MetricThresholds.valid(thresholds) else { throw PresetError.invalidThresholds }
    }
}

enum PresetError: LocalizedError {
    case tooLarge, invalidDocument, unknownField, unsupportedVersion, invalidName
    case invalidLayout, duplicateItem, unknownMetric, invalidThresholds

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "预设文件超过 64 KiB"
        case .invalidDocument: return "预设必须是 JSON 对象"
        case .unknownField: return "预设字段不符合 goodtouchbar-layout v1/v2"
        case .unsupportedVersion: return "不支持此预设格式版本"
        case .invalidName: return "预设名称不能为空且最多 48 个字符"
        case .invalidLayout: return "布局必须包含 1–20 个项目"
        case .duplicateItem: return "布局中不能有重复项目"
        case .unknownMetric: return "布局包含未知项目"
        case .invalidThresholds: return "阈值包含未知指标或数值不在允许范围内"
        }
    }
}

enum GoodTouchBarPresetCatalog {
    static func loadBundled() -> [(String, GoodTouchBarLayoutPreset)] {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Presets", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let preset = try? GoodTouchBarLayoutPreset.decode(data) else { return nil }
                return (url.lastPathComponent, preset)
            }
    }
}
