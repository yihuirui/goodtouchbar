import Foundation
import Darwin

public enum GoodTouchBarMode: String, CaseIterable, Sendable {
    case auto
    case on
    case off
}

public struct TouchBarModeResolution: Equatable, Sendable {
    public let requested: GoodTouchBarMode
    public let enabled: Bool
    public let reason: String

    public init(requested: GoodTouchBarMode, enabled: Bool, reason: String) {
        self.requested = requested
        self.enabled = enabled
        self.reason = reason
    }
}

/// Hardware and process facts used to choose UI and hardware-control capabilities.
/// All detection inputs are injectable so policy can be tested without hardware access.
public struct GoodTouchBarDeviceCapabilities: Equatable, Sendable {
    public let modelIdentifier: String?
    public let processArchitecture: String
    public let hostSupportsArm64: Bool?
    public let processTranslated: Bool?

    public init(
        modelIdentifier: String?,
        processArchitecture: String,
        hostSupportsArm64: Bool?,
        processTranslated: Bool?
    ) {
        self.modelIdentifier = modelIdentifier
        self.processArchitecture = processArchitecture
        self.hostSupportsArm64 = hostSupportsArm64
        self.processTranslated = processTranslated
    }

    public static let touchBarModels: Set<String> = [
        "MacBookPro13,2", "MacBookPro13,3",
        "MacBookPro14,2", "MacBookPro14,3",
        "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",
        "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4",
        "MacBookPro17,1", "Mac14,7"
    ]

    public var architectureDescription: String {
        let arch = processArchitecture.isEmpty ? "unknown" : processArchitecture
        if processTranslated == true { return "\(arch) · Rosetta" }
        return arch
    }

    public var touchBarSupported: Bool {
        guard let modelIdentifier else { return false }
        return Self.touchBarModels.contains(modelIdentifier)
    }

    public var touchBarCapabilityReason: String {
        guard let modelIdentifier, !modelIdentifier.isEmpty else {
            return "无法读取机型标识；为安全起见使用菜单栏模式"
        }
        guard touchBarSupported else {
            return "机型 \(modelIdentifier) 不在已知 Touch Bar 机型列表中；使用菜单栏模式"
        }
        return "机型 \(modelIdentifier) 属于已识别的 Touch Bar 机型"
    }

    public func resolveTouchBarMode(_ mode: GoodTouchBarMode) -> TouchBarModeResolution {
        switch mode {
        case .off:
            return TouchBarModeResolution(requested: mode, enabled: false, reason: "用户选择关闭 Touch Bar")
        case .auto:
            return TouchBarModeResolution(requested: mode, enabled: touchBarSupported, reason: touchBarCapabilityReason)
        case .on:
            if touchBarSupported {
                return TouchBarModeResolution(requested: mode, enabled: true, reason: "用户启用；机型已识别为支持 Touch Bar")
            }
            return TouchBarModeResolution(requested: mode, enabled: false, reason: "无法在此机型呈现 Touch Bar；仍使用菜单栏模式")
        }
    }

    /// Intel fan control is allowed only when both the executable and host are
    /// positively identified as native Intel. Unknown sysctl values fail closed.
    public var canUseIntelFanHelper: Bool {
        processArchitecture == "x86_64" && hostSupportsArm64 == false && processTranslated == false
    }

    public var fanCapabilityReason: String {
        canUseIntelFanHelper
            ? "已确认 Intel 原生运行环境"
            : "未确认 Intel 原生运行环境；风扇由系统管理，关闭 Intel 辅助服务与写入"
    }

    /// Resolve the translation flag without treating arbitrary sysctl errors
    /// as native Intel. On Intel hosts the key is absent (ENOENT); that one
    /// case can be interpreted as untranslated only after host capability and
    /// executable architecture have both been positively identified.
    public static func resolvedTranslationFlag(
        processArchitecture: String,
        hostSupportsArm64: Bool?,
        sysctlValue: Int32?,
        errno: Int32?
    ) -> Bool? {
        if let sysctlValue { return sysctlValue != 0 }
        if processArchitecture == "x86_64", hostSupportsArm64 == false, errno == ENOENT {
            return false
        }
        return nil
    }

    public static var current: GoodTouchBarDeviceCapabilities {
        var processArchitecture = "unknown"
        #if arch(arm64)
        processArchitecture = "arm64"
        #elseif arch(x86_64)
        processArchitecture = "x86_64"
        #endif

        let hostSupportsArm64 = sysctlIntegerResult("hw.optional.arm64").value.map { $0 != 0 }
        let translated = sysctlIntegerResult("sysctl.proc_translated")
        return GoodTouchBarDeviceCapabilities(
            modelIdentifier: sysctlString("hw.model"),
            processArchitecture: processArchitecture,
            hostSupportsArm64: hostSupportsArm64,
            processTranslated: resolvedTranslationFlag(
                processArchitecture: processArchitecture,
                hostSupportsArm64: hostSupportsArm64,
                sysctlValue: translated.value,
                errno: translated.error
            )
        )
    }

    private static func sysctlInteger(_ name: String) -> Int32? {
        sysctlIntegerResult(name).value
    }

    private static func sysctlIntegerResult(_ name: String) -> (value: Int32?, error: Int32?) {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        errno = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return (nil, errno) }
        return (value, nil)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: bytes)
        return value.isEmpty ? nil : value
    }
}
