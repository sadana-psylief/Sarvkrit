import XCTest
@testable import Sarvkrit

/// The line protocol between the app and the root helper.
///
/// Parsed from both ends by the same code, and tested hard in both directions, because one end of
/// this conversation runs as root. Everything a root process reads off a socket is untrusted — the
/// app being the only thing that *should* be on the other end is not the same as it being the only
/// thing that *can* be.
final class FanWireTests: XCTestCase {

    func testEachCommandRoundTrips() {
        for command: FanWire.Command in [.set(percent: 0), .set(percent: 70), .set(percent: 100),
                                         .auto, .ping, .quit] {
            XCTAssertEqual(FanWire.parse(FanWire.encode(command)), command, "\(command)")
        }
    }

    func testTheBoundsOfASpeedAreAccepted() {
        XCTAssertEqual(FanWire.parse("SET 0"), .set(percent: 0))
        XCTAssertEqual(FanWire.parse("SET 100"), .set(percent: 100))
    }

    /// The helper clamps as well, but a value it should never have been sent is a sign something
    /// is wrong at the other end — so it is refused rather than quietly corrected.
    func testASpeedOutsideItsRangeIsRefused() {
        XCTAssertNil(FanWire.parse("SET -1"))
        XCTAssertNil(FanWire.parse("SET 101"))
        XCTAssertNil(FanWire.parse("SET 99999999999999999999"))
    }

    func testAMalformedSpeedIsRefused() {
        XCTAssertNil(FanWire.parse("SET"))
        XCTAssertNil(FanWire.parse("SET "))
        XCTAssertNil(FanWire.parse("SET seventy"))
        XCTAssertNil(FanWire.parse("SET 70.5"))
    }

    /// No tolerance for anything after the command. A parser that shrugs at trailing bytes is a
    /// parser that can be talked into ignoring the part that mattered.
    func testTrailingJunkIsRefused() {
        XCTAssertNil(FanWire.parse("SET 70 AUTO"))
        XCTAssertNil(FanWire.parse("AUTO now"))
        XCTAssertNil(FanWire.parse("PING;QUIT"))
    }

    func testAnUnknownCommandIsRefused() {
        XCTAssertNil(FanWire.parse("REBOOT"))
        XCTAssertNil(FanWire.parse(""))
    }

    /// Case matters. Accepting "set" as well would double the surface for no benefit.
    func testTheProtocolIsCaseSensitive() {
        XCTAssertNil(FanWire.parse("set 70"))
        XCTAssertNil(FanWire.parse("Auto"))
    }

    /// An unbounded line is an unbounded allocation in a root process.
    func testAnOverlongLineIsRefusedBeforeItIsParsed() {
        XCTAssertNil(FanWire.parse("SET " + String(repeating: "0", count: 200)))
        XCTAssertGreaterThan(FanWire.maximumLineLength, 8)
        XCTAssertLessThanOrEqual(FanWire.maximumLineLength, 128)
    }

    func testNonASCIIIsRefused() {
        XCTAssertNil(FanWire.parse("SET 7\u{00B0}"))
        XCTAssertNil(FanWire.parse("AUT\u{00D8}"))
    }

    /// Embedded control characters are how you smuggle a second command past a naive reader.
    func testEmbeddedControlCharactersAreRefused() {
        XCTAssertNil(FanWire.parse("SET 70\nAUTO"))
        XCTAssertNil(FanWire.parse("SET 70\u{0000}"))
    }

    func testEncodedCommandsAreNewlineTerminatedAndFitTheLineLimit() {
        let line = FanWire.encode(.set(percent: 100))
        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertLessThanOrEqual(line.utf8.count, FanWire.maximumLineLength)
    }
}
