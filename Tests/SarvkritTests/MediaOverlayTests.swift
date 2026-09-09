import XCTest
@testable import Sarvkrit

/// Pictures composited over the recording.
///
/// **Copied into the bundle, not referenced.** A project pointing at a file on somebody's Desktop
/// stops working the moment that file moves and cannot be opened on another Mac at all — the same
/// reason the recording itself lives in the package.
final class MediaOverlayTests: XCTestCase {

    func testItCoversOnlyItsOwnRange() {
        let overlay = MediaOverlay(start: 2, end: 5, asset: "logo.png")
        XCTAssertFalse(overlay.covers(1.9))
        XCTAssertTrue(overlay.covers(2))
        XCTAssertFalse(overlay.covers(5), "the range is half-open, like every other track's")
    }

    func testItFadesAndRespectsItsOwnOpacity() {
        var overlay = MediaOverlay(start: 0, end: 4, asset: "logo.png")
        overlay.fadeSeconds = 0.5
        overlay.opacity = 0.5

        XCTAssertEqual(overlay.opacity(at: 2), 0.5, accuracy: 0.001,
                       "the fade must scale the chosen opacity, not replace it")
        XCTAssertLessThan(overlay.opacity(at: 0.1), 0.5)
        XCTAssertEqual(overlay.opacity(at: 9), 0)
    }

    /// The trap that has bitten this feature three times now.
    func testAnOlderOverlayWithMissingFieldsStillDecodes() throws {
        let json = #"{"start":1,"end":4,"asset":"logo.png"}"#
        let overlay = try JSONDecoder().decode(MediaOverlay.self, from: Data(json.utf8))

        XCTAssertEqual(overlay.asset, "logo.png")
        XCTAssertEqual(overlay.opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(overlay.rect.width, 0.32, accuracy: 1e-9)
    }

    func testItSurvivesARoundTrip() throws {
        var overlay = MediaOverlay(start: 1, end: 3, asset: "shot.png")
        overlay.rect = CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.4)
        overlay.cornerRadiusFraction = 0.25

        let decoded = try JSONDecoder().decode(
            MediaOverlay.self, from: try JSONEncoder().encode(overlay))

        XCTAssertEqual(decoded.rect, overlay.rect)
        XCTAssertEqual(decoded.cornerRadiusFraction, 0.25, accuracy: 1e-9)
        XCTAssertEqual(decoded.asset, "shot.png")
    }

    /// Only still pictures for now, and the list says so rather than the loader failing later.
    func testOnlyStillPicturesAreAccepted() {
        XCTAssertTrue(MediaStore.allowedExtensions.contains("png"))
        XCTAssertFalse(MediaStore.allowedExtensions.contains("mov"),
                       "a movie overlay wants its own decoder; see the note on MediaStore")
    }
}
