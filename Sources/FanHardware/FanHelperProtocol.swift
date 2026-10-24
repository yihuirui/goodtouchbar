import Foundation

/// The privileged service accepts structured, versioned requests only.
@objc public protocol GoodTouchFanHelperProtocol {
    func handle(_ request: Data, withReply reply: @escaping (Data) -> Void)
}

public enum FanHelperIdentity {
    public static let machService = "io.github.yihuirui.goodtouchbar.fan-helper"
    public static let policyPath = "/Library/Application Support/GoodTouchBar/FanControl/client-policy.json"
    public static let markerPath = "/Library/Application Support/GoodTouchBar/FanControl/pending-fans.json"
}
