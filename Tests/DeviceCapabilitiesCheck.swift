import Foundation
import Darwin
import SystemMonitoring

@main struct DeviceCapabilitiesCheck {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            precondition(condition, label)
            count += 1
            print("PASS: \(label)")
        }
        let m1TouchBar = GoodTouchBarDeviceCapabilities(
            modelIdentifier: "MacBookPro17,1", processArchitecture: "arm64",
            hostSupportsArm64: true, processTranslated: false
        )
        let m2TouchBarRosetta = GoodTouchBarDeviceCapabilities(
            modelIdentifier: "Mac14,7", processArchitecture: "x86_64",
            hostSupportsArm64: true, processTranslated: true
        )
        let intelTouchBar = GoodTouchBarDeviceCapabilities(
            modelIdentifier: "MacBookPro16,2", processArchitecture: "x86_64",
            hostSupportsArm64: false, processTranslated: false
        )
        let intel15InchTouchBar = GoodTouchBarDeviceCapabilities(
            modelIdentifier: "MacBookPro15,1", processArchitecture: "x86_64",
            hostSupportsArm64: false, processTranslated: false
        )
        let noTouchBar = GoodTouchBarDeviceCapabilities(
            modelIdentifier: "MacBookPro18,1", processArchitecture: "arm64",
            hostSupportsArm64: true, processTranslated: false
        )
        let unknown = GoodTouchBarDeviceCapabilities(
            modelIdentifier: nil, processArchitecture: "x86_64",
            hostSupportsArm64: nil, processTranslated: nil
        )

        check(m1TouchBar.touchBarSupported && m1TouchBar.resolveTouchBarMode(.auto).enabled,
              "M1 MacBookPro17,1 Auto keeps physical Touch Bar enabled")
        check(m2TouchBarRosetta.touchBarSupported && m2TouchBarRosetta.resolveTouchBarMode(.on).enabled,
              "Touch Bar capability follows physical Mac14,7 model under Rosetta")
        check(intelTouchBar.touchBarSupported && intelTouchBar.resolveTouchBarMode(.auto).enabled,
              "Intel Touch Bar models remain enabled in Auto")
        check(intel15InchTouchBar.touchBarSupported && intel15InchTouchBar.resolveTouchBarMode(.auto).enabled,
              "2018-2019 MacBookPro15,1 remains an Intel Touch Bar model")
        check(noTouchBar.resolveTouchBarMode(.auto).enabled == false,
              "known M1 Pro no-Touch-Bar model stays menu-only in Auto")
        check(noTouchBar.resolveTouchBarMode(.on).enabled == false,
              "manual On cannot invent hardware on an unsupported model")
        check(unknown.resolveTouchBarMode(.auto).enabled == false && !unknown.touchBarSupported,
              "unknown model conservatively stays menu-only")
        check(intelTouchBar.canUseIntelFanHelper,
              "only positively identified native Intel is eligible for fan helper")
        check(!m1TouchBar.canUseIntelFanHelper && !m2TouchBarRosetta.canUseIntelFanHelper,
              "ARM native and x86_64 Rosetta both disable Intel fan writes")
        check(!unknown.canUseIntelFanHelper,
              "failed runtime host reads fail closed for Intel fan control")
        let nativeIntelENOENT = GoodTouchBarDeviceCapabilities.resolvedTranslationFlag(
            processArchitecture: "x86_64", hostSupportsArm64: false, sysctlValue: nil, errno: ENOENT
        )
        check(nativeIntelENOENT == false && GoodTouchBarDeviceCapabilities(
            modelIdentifier: "MacBookPro16,2", processArchitecture: "x86_64",
            hostSupportsArm64: false, processTranslated: nativeIntelENOENT
        ).canUseIntelFanHelper, "expected missing translation sysctl confirms native Intel only with positive host evidence")
        check(GoodTouchBarDeviceCapabilities.resolvedTranslationFlag(
            processArchitecture: "x86_64", hostSupportsArm64: false, sysctlValue: nil, errno: EPERM
        ) == nil, "translation permission failures remain unknown and fail closed")
        check(GoodTouchBarDeviceCapabilities.resolvedTranslationFlag(
            processArchitecture: "x86_64", hostSupportsArm64: nil, sysctlValue: nil, errno: ENOENT
        ) == nil, "missing host architecture evidence never infers native Intel")
        check(GoodTouchBarDeviceCapabilities.resolvedTranslationFlag(
            processArchitecture: "arm64", hostSupportsArm64: true, sysctlValue: nil, errno: ENOENT
        ) == nil, "missing translation sysctl on ARM remains unknown")
        check(CoreTemperature.cpuKeys(capabilities: m1TouchBar, chipName: "Apple M1 Pro") == CoreTemperature.m1ThermalZoneKeys,
              "M1 CPU temperature maps only known thermal zones")
        check(CoreTemperature.gpuKeys(capabilities: m1TouchBar, chipName: "Apple M1 Pro") == CoreTemperature.m1GPUThermalZoneKeys,
              "M1 GPU temperature maps only known thermal zones")
        check(CoreTemperature.cpuKeys(capabilities: m2TouchBarRosetta, chipName: "Apple M2") == [],
              "unknown M2 CPU keys remain unsupported rather than using Intel sensors")
        check(CoreTemperature.cpuKeys(capabilities: m2TouchBarRosetta, chipName: "Apple M2") != CoreTemperature.intelKeys,
              "Rosetta never requests Intel temperature key family on Apple Silicon")
        check(CoreTemperature.cpuKeys(capabilities: intelTouchBar, chipName: "Intel Core i7") == CoreTemperature.intelKeys,
              "confirmed native Intel retains per-core temperature mapping")

        let current = GoodTouchBarDeviceCapabilities.current
        #if arch(arm64)
        check(current.processArchitecture == "arm64", "native ARM build reports its process architecture")
        check(current.hostSupportsArm64 == true && !current.canUseIntelFanHelper,
              "current Apple Silicon host is identified without enabling Intel fan control")
        #elseif arch(x86_64)
        if current.hostSupportsArm64 == true {
            check(current.processTranslated == true && !current.canUseIntelFanHelper,
                  "x86_64 executable on Apple Silicon is detected as translated and read-only")
        }
        #endif
        print("\(count) injected machine capability checks passed")
    }
}
