import Foundation

/// 构建号的唯一来源。
///
/// 以前 `MonitorEventLog`、`event-log.mjs`、`background-monitor.mjs`、`FanEventLog`
/// 各自硬编码一个数字（分别是 38/38/38/41），实际交付到 Build43 时没有一处是对的，
/// 出问题无法从日志判断用户装的是哪一版。现在统一从这里取：
///
/// - App 主程序：读 `Info.plist` 的 `CFBundleVersion`
/// - 辅助服务（裸可执行文件，没有 Info.plist）：退回 `fallback`
///
/// `scripts/validate-build.sh` 会校验 `fallback` 与打包进 App 的 `CFBundleVersion` 一致，
/// 避免改了 plist 忘了改这里。
public enum AppBuild {
    /// 与 `Source/Info.plist` 的 `CFBundleVersion` 保持一致。
    public static let fallback = 3

    public static let current: Int = {
        if let text = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           let value = Int(text), value > 0 {
            return value
        }
        return fallback
    }()
}
