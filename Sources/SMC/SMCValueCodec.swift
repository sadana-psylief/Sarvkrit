import Foundation

/// Turns SMC bytes into numbers and back.
///
/// **This is the only place in the feature where endianness or a type code appears.** The SMC is
/// not self-describing in any useful way — it hands back four bytes and a type code, and reading
/// those bytes with the wrong rule produces a plausible number rather than an error. Apple Silicon
/// reports fan speeds as `flt ` (little-endian IEEE754) and Intel as `fpe2` (big-endian fixed
/// point), so both rules ship and exactly one of them is reachable on any given Mac.
///
/// Pure, because that is what makes the unreachable one testable at all.
enum SMCValueCodec {
    private static let float = SMCKey("flt ")!.code
    private static let fixedPoint = SMCKey("fpe2")!.code
    private static let unsigned8 = SMCKey("ui8 ")!.code
    private static let unsigned16 = SMCKey("ui16")!.code
    private static let unsigned32 = SMCKey("ui32")!.code

    /// `nil` for a type we do not understand, and for a buffer too short for the type we do —
    /// a truncated read must not be decoded into an invented number.
    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        switch type {
        case float:
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case fixedPoint:
            guard bytes.count >= 2 else { return nil }
            return Double(((Int(bytes[0]) << 8) | Int(bytes[1])) >> 2)
        case unsigned8:
            guard bytes.count >= 1 else { return nil }
            return Double(bytes[0])
        case unsigned16:
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 8) | Int(bytes[1]))
        case unsigned32:
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        default:
            return nil
        }
    }

    /// **Clamps into the type's range rather than wrapping.** `fpe2` holds fourteen bits; a
    /// wrapped `fpe2` is how you write 60 RPM when you meant 4156, and this encoder feeds a
    /// process running as root.
    static func encode(_ value: Double, type: UInt32, size: Int) -> [UInt8]? {
        switch type {
        case float:
            guard size >= 4 else { return nil }
            let bits = Float(value).bitPattern
            return (0..<4).map { UInt8((bits >> (8 * UInt32($0))) & 0xFF) }
        case fixedPoint:
            guard size >= 2 else { return nil }
            let raw = Int(clamp(value, 0, 16383).rounded()) << 2
            return [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        case unsigned8:
            guard size >= 1 else { return nil }
            return [UInt8(clamp(value, 0, 255).rounded())]
        case unsigned16:
            guard size >= 2 else { return nil }
            let raw = Int(clamp(value, 0, 65535).rounded())
            return [UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        case unsigned32:
            guard size >= 4 else { return nil }
            let raw = UInt32(clamp(value, 0, Double(UInt32.max)).rounded())
            return (0..<4).reversed().map { UInt8((raw >> (8 * UInt32($0))) & 0xFF) }
        default:
            return nil
        }
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        value.isNaN ? low : min(max(value, low), high)
    }
}
