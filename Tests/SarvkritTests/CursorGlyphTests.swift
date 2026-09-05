import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The vector pointers drawn back into the video.
///
/// **Drawn, not scaled from a bitmap.** A 16×16 system cursor blown up to 3× is the blurry mess
/// this whole feature exists to avoid, so each recognised pointer is a path — sharp at any size and
/// any zoom, for the same reason `CaptureBackground`'s doc comment gives about gradients being data
/// rather than image assets.
///
/// The macOS arrow is a specific shape and getting it wrong is uncanny in a way nobody can name but
/// everybody notices, which is exactly the kind of thing that regresses invisibly.
final class CursorGlyphTests: XCTestCase {

    func testEveryKindHasAGlyph() {
        for kind in CursorKind.allCases {
            XCTAssertFalse(CursorGlyph.path(for: kind).isEmpty, "\(kind.rawValue) has no path")
        }
    }

    /// The unit box is what makes size a single multiplier everywhere else.
    func testEveryGlyphFitsInsideItsUnitBox() {
        for kind in CursorKind.allCases {
            let bounds = CursorGlyph.path(for: kind).boundingBoxOfPath
            XCTAssertGreaterThanOrEqual(bounds.minX, -0.01, "\(kind.rawValue)")
            XCTAssertGreaterThanOrEqual(bounds.minY, -0.01, "\(kind.rawValue)")
            XCTAssertLessThanOrEqual(bounds.maxX, CursorGlyph.unitSize + 0.01, "\(kind.rawValue)")
            XCTAssertLessThanOrEqual(bounds.maxY, CursorGlyph.unitSize + 0.01, "\(kind.rawValue)")
        }
    }

    /// The hotspot is where the click actually happened. An arrow's is its tip; an I-beam's is its
    /// middle. Getting this wrong offsets every click effect from the thing it clicked.
    func testEveryHotspotIsInsideItsGlyph() {
        for kind in CursorKind.allCases {
            let hotspot = CursorGlyph.hotspot(for: kind)
            XCTAssertTrue((0...1).contains(hotspot.x), "\(kind.rawValue) x")
            XCTAssertTrue((0...1).contains(hotspot.y), "\(kind.rawValue) y")
        }
    }

    func testTheArrowPointsFromItsTopLeftCorner() {
        let hotspot = CursorGlyph.hotspot(for: .arrow)
        XCTAssertEqual(hotspot.x, 0, accuracy: 0.05)
        XCTAssertEqual(hotspot.y, 0, accuracy: 0.05)
    }

    func testACentredCursorIsGrabbedByItsMiddle() {
        for kind in [CursorKind.iBeam, .crosshair, .resizeLeftRight, .resizeUpDown] {
            let hotspot = CursorGlyph.hotspot(for: kind)
            XCTAssertEqual(hotspot.x, 0.5, accuracy: 0.05, "\(kind.rawValue)")
            XCTAssertEqual(hotspot.y, 0.5, accuracy: 0.05, "\(kind.rawValue)")
        }
    }

    /// An unrecognised pointer keeps its own bitmap, so there is nothing to draw for `.custom` —
    /// but a path is still returned rather than nothing, because a missing glyph must degrade to an
    /// arrow instead of to an invisible cursor.
    func testAnUnknownKindFallsBackToTheArrow() {
        XCTAssertEqual(CursorGlyph.path(for: .unknown).boundingBoxOfPath,
                       CursorGlyph.path(for: .arrow).boundingBoxOfPath)
    }

    // MARK: - Sizing

    /// Cursor size is applied in canvas space, not screen-layer space. If it scaled with the zoom,
    /// a 2.5× close-up would come with a comically large pointer.
    func testTheCursorGrowsFarSlowerThanTheZoom() {
        let atRest = CursorGlyph.drawnSize(base: 1.6, zoom: 1)
        let zoomed = CursorGlyph.drawnSize(base: 1.6, zoom: 2.5)
        XCTAssertGreaterThan(zoomed, atRest)
        XCTAssertLessThan(zoomed / atRest, 1.5, "the cursor is tracking the zoom too closely")
    }

    /// The size is exactly what was asked for at rest. The user's own Accessibility pointer size
    /// is not an input: the recording has no cursor in it, so theirs never reaches the video and
    /// there is nothing for ours to compound with.
    func testAtRestTheCursorIsExactlyTheRequestedSize() {
        XCTAssertEqual(CursorGlyph.drawnSize(base: 2, zoom: 1),
                       2 * Double(CursorGlyph.unitSize), accuracy: 0.0001)
    }

    // MARK: - Rendering

    func testAGlyphRendersAtTheHeightItWasAskedFor() throws {
        let rendered = try XCTUnwrap(CursorGlyph.rendered(for: .arrow, glyphHeight: 64))
        XCTAssertEqual(rendered.glyphHeight, 64, accuracy: 0.0001)
    }

    /// The bitmap is deliberately bigger than the glyph — a shadow needs room. Treating the whole
    /// bitmap as the pointer would shrink it and put its hotspot in the wrong place.
    func testTheBitmapLeavesRoomForTheShadow() throws {
        let rendered = try XCTUnwrap(CursorGlyph.rendered(for: .arrow, glyphHeight: 64))
        XCTAssertGreaterThan(rendered.image.height, Int(rendered.glyphHeight))
        XCTAssertGreaterThan(rendered.inset, 0)
    }

    /// Two different pointers must not render identically — the cheapest possible guard against a
    /// switch that silently falls through to the arrow.
    func testDifferentKindsRenderDifferently() throws {
        let arrow = try XCTUnwrap(CursorGlyph.rendered(for: .arrow, glyphHeight: 64))
        let hand = try XCTUnwrap(CursorGlyph.rendered(for: .pointingHand, glyphHeight: 64))
        XCTAssertNotEqual(CaptureWriter.pngData(from: arrow.image),
                          CaptureWriter.pngData(from: hand.image))
    }
}
