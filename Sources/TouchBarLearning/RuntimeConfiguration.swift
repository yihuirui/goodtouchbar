import Foundation
import SystemMonitoring

enum GoodTouchBarRuntimeConfiguration {
    static let touchBarModeDefaultsKey = "touchBarMode"
    static let touchBarEnabledDefaultsKey = "touchBarEnabled"
    static let touchBarDefaultInfoKey = "GoodTouchBarTouchBarDefault"

    static func selectedMode(
        defaults: UserDefaults = .standard,
        infoValue: Any? = Bundle.main.object(forInfoDictionaryKey: touchBarDefaultInfoKey)
    ) -> GoodTouchBarMode {
        if defaults.object(forKey: touchBarModeDefaultsKey) != nil {
            if let raw = defaults.string(forKey: touchBarModeDefaultsKey),
               let mode = GoodTouchBarMode(rawValue: raw.lowercased()) {
                return mode
            }
            return .auto
        }

        // The 0.1 Bool was an explicit override. Keep honoring it when the new
        // mode setting is absent; the 0.2 bundle default is the string "auto".
        if let stored = defaults.object(forKey: touchBarEnabledDefaultsKey) as? Bool {
            return stored ? .on : .off
        }

        if let raw = infoValue as? String, let mode = GoodTouchBarMode(rawValue: raw.lowercased()) {
            return mode
        }
        if let oldBundleBool = infoValue as? NSNumber {
            return oldBundleBool.boolValue ? .on : .off
        }
        return .auto
    }

    static func resolution(
        capabilities: GoodTouchBarDeviceCapabilities = .current,
        defaults: UserDefaults = .standard,
        infoValue: Any? = Bundle.main.object(forInfoDictionaryKey: touchBarDefaultInfoKey)
    ) -> TouchBarModeResolution {
        capabilities.resolveTouchBarMode(selectedMode(defaults: defaults, infoValue: infoValue))
    }

    static var touchBarEnabled: Bool { resolution().enabled }
    static var deviceSummary: String {
        let device = GoodTouchBarDeviceCapabilities.current
        let mode = resolution(capabilities: device)
        return "机型：\(device.modelIdentifier ?? "unknown") · 架构：\(device.architectureDescription) · 模式：\(mode.requested.rawValue) → \(mode.enabled ? "Touch Bar" : "菜单栏") · \(mode.reason)"
    }
}
