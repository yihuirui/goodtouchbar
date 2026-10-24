// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GoodTouchBar", platforms: [.macOS(.v13)], products: [
    .executable(name: "GoodTouchBar", targets: ["GoodTouchBar"]),
    .executable(name: "GoodTouchSensors", targets: ["GoodTouchSensors"]),
    .executable(name: "GoodTouchFanHelper", targets: ["GoodTouchFanHelper"])
], targets: [
    .target(name: "SystemMonitoring"),
    .target(name: "FanControlCore"),
    .target(name: "FanHardware", dependencies: ["FanControlCore", "SystemMonitoring"]),
    .executableTarget(name: "GoodTouchBar", dependencies: ["SystemMonitoring", "FanControlCore", "FanHardware"], path: "Sources/TouchBarLearning"),
    .executableTarget(name: "GoodTouchSensors", dependencies: ["SystemMonitoring"], path: "Sources/GoodTouchSensors"),
    .executableTarget(name: "GoodTouchFanHelper", dependencies: ["FanControlCore", "FanHardware", "SystemMonitoring"], path: "Sources/GoodTouchFanHelper")
])
