import Foundation

public enum FanEncodingError: Error { case invalidFan, invalidSpeed, unsupportedType, invalidLength }

public enum FanEncoding {
    public static func target(rpm: Double, type: String, size: Int) throws -> [UInt8] {
        guard rpm.isFinite, rpm >= 0, rpm.rounded() == rpm else { throw FanEncodingError.invalidSpeed }
        switch type {
        case "fpe2":
            guard size == 2, rpm <= 16_383 else { throw FanEncodingError.invalidLength }
            let value = UInt16(rpm) << 2
            return [UInt8(value >> 8), UInt8(value & 0xff)]
        case "flt ":
            guard size == 4, rpm <= 20_000 else { throw FanEncodingError.invalidLength }
            let value = Float(rpm).bitPattern
            return [0,8,16,24].map { UInt8(truncatingIfNeeded: value >> $0) }
        default: throw FanEncodingError.unsupportedType
        }
    }
    public static func modeMask(_ mask: UInt16, fanID: Int, manual: Bool) throws -> UInt16 {
        guard (0...9).contains(fanID) else { throw FanEncodingError.invalidFan }
        let bit = UInt16(1) << fanID
        return manual ? mask | bit : mask & ~bit
    }
}
