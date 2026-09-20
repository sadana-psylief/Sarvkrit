import XCTest
@testable import Sarvkrit

/// The byte-level codec. Every fixture marked "measured" was captured from the SMC on a
/// MacBook Pro (Mac14,9, M2 Pro) during the spike that preceded this feature — so these are the
/// machine's own bytes, not bytes worked out on paper.
final class SMCValueCodecTests: XCTestCase {

    private let flt = SMCKey("flt ")!.code
    private let fpe2 = SMCKey("fpe2")!.code
    private let ui8 = SMCKey("ui8 ")!.code
    private let ui16 = SMCKey("ui16")!.code
    private let ui32 = SMCKey("ui32")!.code

    // MARK: - flt, which is what Apple Silicon reports

    func testAFloatDecodesLittleEndian() {
        // measured: F0Mn on Mac14,9
        XCTAssertEqual(SMCValueCodec.decode(type: flt, bytes: [0x00, 0xD0, 0x10, 0x45]), 2317)
        // measured: F0Mx on Mac14,9
        XCTAssertEqual(SMCValueCodec.decode(type: flt, bytes: [0x00, 0x80, 0xD4, 0x45]), 6800)
    }

    /// A stopped fan is the M2 Pro's normal idle state, so zero is data and must survive the
    /// codec as zero rather than being mistaken for an absent reading.
    func testAFloatOfZeroDecodesToZeroRatherThanNil() {
        XCTAssertEqual(SMCValueCodec.decode(type: flt, bytes: [0, 0, 0, 0]), 0)
    }

    func testAFloatRoundTripsThroughEncode() {
        let bytes = SMCValueCodec.encode(5439, type: flt, size: 4)
        XCTAssertEqual(bytes.flatMap { SMCValueCodec.decode(type: flt, bytes: $0) }, 5439)
    }

    // MARK: - fpe2, which is what Intel reports and this Mac cannot produce

    func testAFixedPointValueDecodesBigEndianWithTwoFractionalBits() {
        XCTAssertEqual(SMCValueCodec.decode(type: fpe2, bytes: [0x24, 0x34]), 2317)
        XCTAssertEqual(SMCValueCodec.decode(type: fpe2, bytes: [0x00, 0x04]), 1)
    }

    func testAFixedPointValueRoundTripsThroughEncode() {
        let bytes = SMCValueCodec.encode(2317, type: fpe2, size: 2)
        XCTAssertEqual(bytes, [0x24, 0x34])
    }

    /// fpe2 holds 14 bits. Wrapping is how you write 60 RPM when you meant 4156, so it clamps.
    func testAFixedPointValueTooLargeForTheTypeClampsRatherThanWraps() {
        let bytes = SMCValueCodec.encode(99_999, type: fpe2, size: 2)
        XCTAssertEqual(SMCValueCodec.decode(type: fpe2, bytes: bytes ?? []), 16383)
    }

    // MARK: - the unsigned integers

    func testUnsignedIntegersDecodeBigEndian() {
        XCTAssertEqual(SMCValueCodec.decode(type: ui8, bytes: [0x02]), 2)   // measured: FNum
        XCTAssertEqual(SMCValueCodec.decode(type: ui16, bytes: [0x01, 0x00]), 256)
        XCTAssertEqual(SMCValueCodec.decode(type: ui32, bytes: [0, 0, 0x01, 0x00]), 256)
    }

    func testAnUnsignedIntegerClampsAtItsCeilingRatherThanWrapping() {
        XCTAssertEqual(SMCValueCodec.encode(999, type: ui8, size: 1), [0xFF])
    }

    // MARK: - refusals

    func testAnUnknownTypeDecodesToNil() {
        XCTAssertNil(SMCValueCodec.decode(type: SMCKey("zzzz")!.code, bytes: [0, 0, 0, 0]))
    }

    /// A short buffer is a truncated read. Decoding it would invent a number.
    func testABufferShorterThanTheTypeNeedsDecodesToNil() {
        XCTAssertNil(SMCValueCodec.decode(type: flt, bytes: [0x00, 0xD0]))
        XCTAssertNil(SMCValueCodec.decode(type: ui16, bytes: []))
    }

    func testEncodingAnUnknownTypeFails() {
        XCTAssertNil(SMCValueCodec.encode(1, type: SMCKey("zzzz")!.code, size: 4))
    }
}
