import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Moving and resizing a blur.
///
/// The report: *"When I do secure blur, how do I resize it? move it? it just enters in middle of
/// the screen and that is it."* It did — `addMaskAtPlayhead` dropped a box at a fixed fraction of
/// the canvas and nothing could touch it afterwards.
///
/// **The geometry is asserted against the renderer's own, not against a second copy of the same
/// arithmetic.** A hit test that disagrees with what is drawn by even a few points is a mask you
/// cannot grab, which is indistinguishable from the bug being unfixed.
final class StudioMaskGeometryTests: XCTestCase {

    private let canvas = CGSize(width: 800, height: 500)

    private func project(masks: [StudioMask] = []) -> StudioProject {
        var project = StudioProject(canvasSize: canvas,
                                    timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 10)]))
        project.masks = masks
        return project
    }

    private func mask(_ rect: CGRect) -> StudioMask {
        StudioMask(rects: [rect], start: 0, end: 10)
    }

    // MARK: - Where the boxes are

    func testAVisibleMaskHasABox() {
        let project = project(masks: [mask(CGRect(x: 100, y: 200, width: 300, height: 100))])
        let (_, imageRect) = StudioRenderer.layout(for: project)
        let boxes = StudioRenderer.maskBoxes(project: project, sourceTime: 3, events: EventLog(),
                                             imageRect: imageRect)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes.first?.id, project.masks.first?.id)
        XCTAssertEqual(boxes.first?.index, 0)
    }

    /// Outside its time range it is not on screen, so it must not be grabbable either — clicking
    /// where a mask *used to be* would select something invisible.
    func testAMaskOutsideItsRangeHasNoBox() {
        var mask = mask(CGRect(x: 100, y: 200, width: 300, height: 100))
        mask.start = 5
        mask.end = 7
        let project = project(masks: [mask])
        let (_, imageRect) = StudioRenderer.layout(for: project)
        XCTAssertTrue(StudioRenderer.maskBoxes(project: project, sourceTime: 1,
                                               events: EventLog(), imageRect: imageRect).isEmpty)
    }

    /// One object, several rectangles — "hide every price in this table" is one mask with nine
    /// boxes, and each has to be grabbable on its own.
    func testEveryRectangleOfAMaskIsAddressable() {
        var many = mask(CGRect(x: 10, y: 10, width: 50, height: 20))
        many.rects.append(RectBox(CGRect(x: 200, y: 300, width: 50, height: 20)))
        let project = project(masks: [many])
        let (_, imageRect) = StudioRenderer.layout(for: project)
        let boxes = StudioRenderer.maskBoxes(project: project, sourceTime: 1, events: EventLog(),
                                             imageRect: imageRect)
        XCTAssertEqual(boxes.count, 2)
        XCTAssertEqual(boxes.map { $0.index }, [0, 1])
    }

    // MARK: - Editing the box

    func testAMaskRectangleCanBeMoved() {
        var project = project(masks: [mask(CGRect(x: 100, y: 100, width: 200, height: 80))])
        StudioProject.setMaskRect(&project, id: project.masks[0].id, index: 0,
                                  to: CGRect(x: 400, y: 250, width: 200, height: 80))
        XCTAssertEqual(project.masks[0].rects[0].rect,
                       CGRect(x: 400, y: 250, width: 200, height: 80))
    }

    /// **A hand-moved mask stops following its window.**
    ///
    /// A pinned mask is redrawn at wherever its window is now, so a manual drag and the pin would
    /// fight each other: you would let go and watch the box jump back. Moving it by hand is the
    /// clearer intent, so the pin goes.
    func testMovingAPinnedMaskUnpinsIt() {
        var pinned = mask(CGRect(x: 100, y: 100, width: 200, height: 80))
        pinned.followsWindowID = 42
        pinned.windowOriginAtCreation = CGPoint(x: 10, y: 10)
        var project = project(masks: [pinned])

        StudioProject.setMaskRect(&project, id: project.masks[0].id, index: 0,
                                  to: CGRect(x: 400, y: 250, width: 200, height: 80))

        XCTAssertNil(project.masks[0].followsWindowID)
        XCTAssertNil(project.masks[0].windowOriginAtCreation)
    }

    /// A rectangle that is not there must not silently write into a neighbour, or dragging the
    /// second box of a mask whose first was deleted would move the wrong region — uncovering
    /// something. The one outcome a redaction tool must never have.
    func testAnUnknownRectangleIsIgnored() {
        var project = project(masks: [mask(CGRect(x: 100, y: 100, width: 200, height: 80))])
        let before = project
        StudioProject.setMaskRect(&project, id: project.masks[0].id, index: 7,
                                  to: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(project, before)
    }

    func testAnUnknownMaskIsIgnored() {
        var project = project(masks: [mask(CGRect(x: 100, y: 100, width: 200, height: 80))])
        let before = project
        StudioProject.setMaskRect(&project, id: UUID(), index: 0,
                                  to: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertEqual(project, before)
    }

    // MARK: - A resize has to remember where it started

    /// **`resize` is a function of the rect the handle was grabbed on, not of the rect as it is
    /// now.** Feed it its own output and it is still correct while the drag stays on one side of
    /// the anchor; the moment the pointer crosses the opposite corner the rect flips, and every
    /// event after that measures from the flipped edge — so the width becomes the distance the
    /// mouse moved since the last event instead of the distance from the anchor, and the box
    /// collapses to nothing under a hand that is still dragging outwards.
    func testResizingFromTheMovingRectCollapsesPastTheOppositeCorner() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        // Three events dragging the top-left corner rightwards, through maxX at 300 and beyond.
        var moving = start
        for x in [350.0, 360.0, 370.0] {
            moving = SelectionHandles.resize(moving, handle: .topLeft,
                                             to: CGPoint(x: x, y: 100),
                                             constrainAspect: false, minimumSide: 1)
        }
        XCTAssertLessThan(moving.width, 30, "the premise of this test has gone")
    }

    /// From the anchor, the same three events grow the box as the hand expects.
    func testResizingFromTheGrabbedRectSurvivesTheFlip() {
        let start = CGRect(x: 100, y: 100, width: 200, height: 100)
        var resized = start
        for x in [350.0, 360.0, 370.0] {
            resized = SelectionHandles.resize(start, handle: .topLeft,
                                              to: CGPoint(x: x, y: 100),
                                              constrainAspect: false, minimumSide: 1)
        }
        XCTAssertEqual(resized.minX, 300, accuracy: 0.01)
        XCTAssertEqual(resized.maxX, 370, accuracy: 0.01)
    }

    // MARK: - Canvas and source are inverses

    /// **The property the drag depends on.** A resize reads a canvas rect out of `maskBoxes`,
    /// applies the pointer to it, and writes it back through `sourceRect`. If the round trip is
    /// not the identity the mask creeps every time it is touched.
    func testCanvasAndSourceRoundTrip() throws {
        let project = project()
        let (_, imageRect) = StudioRenderer.layout(for: project)
        let geometry = StudioRenderer.screenGeometry(project: project, sourceTime: 1,
                                                     events: EventLog(), imageRect: imageRect)
        let source = CGRect(x: 123, y: 217, width: 254, height: 96)

        let onCanvas = try XCTUnwrap(StudioRenderer.canvasRect(
            source, project: project, transform: geometry.transform,
            imageRect: geometry.screenRect))
        let back = try XCTUnwrap(StudioRenderer.sourceRect(
            onCanvas, project: project, transform: geometry.transform,
            imageRect: geometry.screenRect))

        XCTAssertEqual(back.minX, source.minX, accuracy: 0.01)
        XCTAssertEqual(back.minY, source.minY, accuracy: 0.01)
        XCTAssertEqual(back.width, source.width, accuracy: 0.01)
        XCTAssertEqual(back.height, source.height, accuracy: 0.01)
    }

    /// And under a zoom, which is where a single forgotten scale factor hides.
    func testCanvasAndSourceRoundTripUnderAZoom() throws {
        var zoomed = project()
        zoomed.zooms = [ZoomSegment(start: 0, end: 10, level: 2,
                                    anchor: .fixed(CGPoint(x: 0.5, y: 0.5)))]
        let (_, imageRect) = StudioRenderer.layout(for: zoomed)
        let geometry = StudioRenderer.screenGeometry(project: zoomed, sourceTime: 5,
                                                     events: EventLog(), imageRect: imageRect)
        XCTAssertGreaterThan(geometry.transform.scale, 1, "the zoom did not take")

        let source = CGRect(x: 340, y: 210, width: 120, height: 80)
        let onCanvas = try XCTUnwrap(StudioRenderer.canvasRect(
            source, project: zoomed, transform: geometry.transform,
            imageRect: geometry.screenRect))
        let back = try XCTUnwrap(StudioRenderer.sourceRect(
            onCanvas, project: zoomed, transform: geometry.transform,
            imageRect: geometry.screenRect))

        XCTAssertEqual(back.minX, source.minX, accuracy: 0.01)
        XCTAssertEqual(back.minY, source.minY, accuracy: 0.01)
        XCTAssertEqual(back.width, source.width, accuracy: 0.01)
        XCTAssertEqual(back.height, source.height, accuracy: 0.01)
    }
}
