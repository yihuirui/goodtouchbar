import Foundation

/// Finite automatic recovery. Foreground activation or explicit refresh starts a new round.
public struct PresentationRecovery {
    public private(set) var failures = 0
    public private(set) var nextAttempt: Double = 0
    public var exhausted: Bool { failures >= 6 }
    public init() {}
    public mutating func reset() { failures = 0; nextAttempt = 0 }
    public mutating func failed(now: Double) -> Double? {
        failures += 1
        guard !exhausted else { return nil }
        let delay = min(30, pow(2,Double(failures-1)))
        nextAttempt = now + delay; return delay
    }
}
