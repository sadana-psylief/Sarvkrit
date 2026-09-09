import XCTest
@testable import Sarvkrit

/// Text put on the video by hand.
///
/// **Its own type, because captions cannot express this.** `Caption` has no text field and no time
/// range of its own — both derive from `words: [TranscriptWord]`, each needing a speech-recognition
/// timestamp — and `CaptionStyle` is stored once per project with a position that is one of three
/// canned values rather than a point. Faking a caption would mean inventing word timings to carry a
/// string, then fighting the karaoke highlighting the type exists for.
final class TextOverlayTests: XCTestCase {

    func testItCoversOnlyItsOwnRange() {
        let overlay = TextOverlay(start: 2, end: 5)
        XCTAssertFalse(overlay.covers(1.9))
        XCTAssertTrue(overlay.covers(2))
        XCTAssertTrue(overlay.covers(4.9))
        XCTAssertFalse(overlay.covers(5), "the range is half-open, like every other track's")
    }

    /// It fades rather than snapping: text appearing between two frames reads as a flash.
    func testItFadesInAndOut() {
        var overlay = TextOverlay(start: 0, end: 4)
        overlay.fadeSeconds = 0.5

        XCTAssertEqual(overlay.opacity(at: 2), 1, accuracy: 0.001)
        XCTAssertLessThan(overlay.opacity(at: 0.1), 1)
        XCTAssertLessThan(overlay.opacity(at: 3.9), 1)
        XCTAssertEqual(overlay.opacity(at: 9), 0)
    }

    /// A line shorter than twice its fade still reaches full opacity rather than never arriving.
    func testAShortLineStillBecomesVisible() {
        var overlay = TextOverlay(start: 0, end: 0.5)
        overlay.fadeSeconds = 2
        XCTAssertGreaterThan(overlay.opacity(at: 0.25), 0.9)
    }

    /// Measurements are fractions of the canvas, so a title keeps its framing at any export size.
    func testTheFontScalesWithTheCanvas() {
        var overlay = TextOverlay(start: 0, end: 1)
        overlay.sizeFraction = 0.05
        XCTAssertEqual(overlay.font(forCanvasHeight: 1000).pointSize, 50, accuracy: 0.001)
        XCTAssertEqual(overlay.font(forCanvasHeight: 2000).pointSize, 100, accuracy: 0.001)
    }

    /// The trap that has now bitten this feature twice: a hand-written decoder so a field added
    /// later cannot make an older project unreadable — which the model treats as *no* project, and
    /// therefore silently discards edits.
    func testAnOlderOverlayWithMissingFieldsStillDecodes() throws {
        let json = #"{"start":1,"end":4,"text":"Hello"}"#
        let overlay = try JSONDecoder().decode(TextOverlay.self, from: Data(json.utf8))

        XCTAssertEqual(overlay.text, "Hello")
        XCTAssertEqual(overlay.end, 4, accuracy: 1e-9)
        XCTAssertEqual(overlay.sizeFraction, 0.055, accuracy: 1e-9)
        XCTAssertNotNil(overlay.background)
    }

    func testItSurvivesARoundTrip() throws {
        var overlay = TextOverlay(start: 1, end: 3, text: "Look here")
        overlay.origin = CGPoint(x: 0.2, y: 0.8)
        overlay.haloColour = RGBAColour(r: 0, g: 0, b: 0, a: 1)
        overlay.background = nil

        let decoded = try JSONDecoder().decode(
            TextOverlay.self, from: try JSONEncoder().encode(overlay))

        XCTAssertEqual(decoded.text, "Look here")
        XCTAssertEqual(decoded.origin, CGPoint(x: 0.2, y: 0.8))
        XCTAssertNotNil(decoded.haloColour)
        XCTAssertNil(decoded.background, "a nil background must stay nil, not revert to a default")
    }
}
