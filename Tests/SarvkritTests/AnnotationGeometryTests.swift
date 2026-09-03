import XCTest
@testable import Sarvkrit

final class AnnotationGeometryTests: XCTestCase {

    private func document(_ kinds: [AnnotationElement.Kind]) -> AnnotationDocument {
        var document = AnnotationDocument(imageSize: CGSize(width: 1000, height: 800))
        kinds.forEach { document.add($0) }
        return document
    }

    func testAnUnfilledRectangleIgnoresItsInterior() {
        // The rule that matters most: a rectangle drawn *around* a region must not make
        // everything inside that region unselectable.
        let shape = ShapeElement(rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        let element = AnnotationElement(kind: .rectangle(shape))
        XCTAssertFalse(AnnotationGeometry.contains(element, point: CGPoint(x: 300, y: 250),
                                                   tolerance: 6))
        XCTAssertTrue(AnnotationGeometry.contains(element, point: CGPoint(x: 100, y: 250),
                                                  tolerance: 6), "the edge is hittable")
    }

    func testAFilledRectangleHitsItsInterior() {
        var shape = ShapeElement(rect: CGRect(x: 100, y: 100, width: 400, height: 300))
        shape.fill = .blue
        XCTAssertTrue(AnnotationGeometry.contains(AnnotationElement(kind: .rectangle(shape)),
                                                  point: CGPoint(x: 300, y: 250), tolerance: 6))
    }

    func testAnArrowHeadIsHittableEvenSlightlyOffTheShaft() {
        // The head is what people aim at, and it is wider than the line.
        let arrow = ArrowElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 0))
        let element = AnnotationElement(kind: .arrow(arrow))
        XCTAssertTrue(AnnotationGeometry.contains(element, point: CGPoint(x: 200, y: 14),
                                                  tolerance: 4))
    }

    func testACurvedArrowHitsAlongTheCurveNotTheChord() {
        let arrow = ArrowElement(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 0),
                                 curvature: 80)
        let element = AnnotationElement(kind: .arrow(arrow))
        // The bow sits well off the straight line between the endpoints.
        XCTAssertTrue(AnnotationGeometry.contains(element, point: CGPoint(x: 100, y: 40),
                                                  tolerance: 8))
        XCTAssertFalse(AnnotationGeometry.contains(element, point: CGPoint(x: 100, y: -30),
                                                   tolerance: 4))
    }

    func testAPencilStrokeToleranceGrowsWithItsWidth() {
        var thin = PencilElement(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        thin.stroke.width = 2
        var thick = thin
        thick.stroke.width = 40

        let probe = CGPoint(x: 50, y: 15)
        XCTAssertFalse(AnnotationGeometry.contains(AnnotationElement(kind: .pencil(thin)),
                                                   point: probe, tolerance: 4))
        XCTAssertTrue(AnnotationGeometry.contains(AnnotationElement(kind: .pencil(thick)),
                                                  point: probe, tolerance: 4))
    }

    func testTheTopmostElementWinsWhereTwoOverlap() {
        let doc = document([
            .rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 200, height: 200),
                                    stroke: StrokeStyle(), fill: .blue)),
            .rectangle(ShapeElement(rect: CGRect(x: 50, y: 50, width: 200, height: 200),
                                    stroke: StrokeStyle(), fill: .red)),
        ])
        let hit = AnnotationGeometry.hitTest(doc, at: CGPoint(x: 100, y: 100), tolerance: 4)
        XCTAssertEqual(hit, doc.elements[1].id, "the one drawn last is on top")
    }

    func testAPointOverNothingHitsNothing() {
        let doc = document([.line(LineElement(start: .zero, end: CGPoint(x: 10, y: 10)))])
        XCTAssertNil(AnnotationGeometry.hitTest(doc, at: CGPoint(x: 900, y: 700), tolerance: 4))
    }

    func testBoundsIncludeTheStrokeWidth() {
        // Handles drawn on the bare geometry would sit inside a thick mark.
        var line = LineElement(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 200, y: 100))
        line.stroke.width = 20
        let bounds = AnnotationGeometry.bounds(of: AnnotationElement(kind: .line(line)))
        XCTAssertEqual(bounds.minY, 90, accuracy: 0.001)
        XCTAssertEqual(bounds.maxY, 110, accuracy: 0.001)
    }

    func testAMarqueeFindsWhatItOverlaps() {
        let doc = document([
            .rectangle(ShapeElement(rect: CGRect(x: 0, y: 0, width: 50, height: 50))),
            .rectangle(ShapeElement(rect: CGRect(x: 500, y: 500, width: 50, height: 50))),
        ])
        let found = AnnotationGeometry.elements(doc,
                                                intersecting: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(found, [doc.elements[0].id])
    }

    func testAnEllipseHitsItsRingNotItsCorners() {
        let shape = ShapeElement(rect: CGRect(x: 0, y: 0, width: 200, height: 200))
        let element = AnnotationElement(kind: .ellipse(shape))
        XCTAssertTrue(AnnotationGeometry.contains(element, point: CGPoint(x: 100, y: 0),
                                                  tolerance: 6), "top of the ring")
        XCTAssertFalse(AnnotationGeometry.contains(element, point: CGPoint(x: 2, y: 2),
                                                   tolerance: 4), "the corner is outside an ellipse")
    }

    func testACounterHitsItsDisc() {
        let counter = CounterElement(centre: CGPoint(x: 100, y: 100), radius: 20)
        let element = AnnotationElement(kind: .counter(counter))
        XCTAssertTrue(AnnotationGeometry.contains(element, point: CGPoint(x: 110, y: 105),
                                                  tolerance: 0))
        XCTAssertFalse(AnnotationGeometry.contains(element, point: CGPoint(x: 140, y: 140),
                                                   tolerance: 0))
    }
}

final class SelectionHandleTests: XCTestCase {
    private let bounds = CGRect(x: 100, y: 100, width: 200, height: 100)

    func testEveryBoxHandleIsPresent() {
        XCTAssertEqual(SelectionHandles.rects(for: bounds).count, 8)
    }

    func testAHandleGrabAreaIsTheSameOnScreenAtEveryZoom() {
        // Handles are in view space precisely so this holds: the physical target doesn't change
        // when the canvas is zoomed.
        let size: CGFloat = 9
        for zoom in [CGFloat(0.25), 1, 4] {
            let transform = CanvasTransform(imageSize: CGSize(width: 1000, height: 1000),
                                            zoom: zoom)
            let viewBounds = transform.toView(bounds)
            let rects = SelectionHandles.rects(for: viewBounds, size: size)
            XCTAssertEqual(rects[.topLeft]?.width, size, "zoom \(zoom)")
        }
    }

    func testACornerBeatsAnEdgeWhereTheyOverlap() {
        // On a small selection the two overlap, and the corner is the one being reached for.
        let tiny = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(SelectionHandles.handle(at: CGPoint(x: 0, y: 0), bounds: tiny, size: 12),
                       .topLeft)
    }

    func testResizeKeepsTheOppositeCornerFixed() {
        let resized = SelectionHandles.resize(bounds, handle: .bottomRight,
                                              to: CGPoint(x: 400, y: 300),
                                              constrainAspect: false)
        XCTAssertEqual(resized.minX, bounds.minX)
        XCTAssertEqual(resized.minY, bounds.minY)
        XCTAssertEqual(resized.maxX, 400)
        XCTAssertEqual(resized.maxY, 300)
    }

    func testResizingThroughTheOppositeEdgeFlipsRatherThanCollapsing() {
        // What every drawing tool does, and what the hand expects.
        let resized = SelectionHandles.resize(bounds, handle: .bottomRight,
                                              to: CGPoint(x: 50, y: 50),
                                              constrainAspect: false)
        XCTAssertGreaterThan(resized.width, 0)
        XCTAssertEqual(resized.maxX, bounds.minX)
    }

    func testTheMinimumSideIsEnforced() {
        // A zero-size element cannot be grabbed again — only undo gets it back.
        let resized = SelectionHandles.resize(bounds, handle: .bottomRight,
                                              to: CGPoint(x: 100, y: 100),
                                              constrainAspect: false)
        XCTAssertGreaterThanOrEqual(resized.width, SelectionHandles.minimumSide)
        XCTAssertGreaterThanOrEqual(resized.height, SelectionHandles.minimumSide)
    }

    func testAspectIsHeldWhenConstrained() {
        let resized = SelectionHandles.resize(bounds, handle: .bottomRight,
                                              to: CGPoint(x: 500, y: 120),
                                              constrainAspect: true)
        XCTAssertEqual(resized.width / resized.height, bounds.width / bounds.height,
                       accuracy: 0.001)
    }

    func testEndpointHandlesDoNotResizeTheBox() {
        XCTAssertEqual(SelectionHandles.resize(bounds, handle: .start,
                                               to: CGPoint(x: 0, y: 0), constrainAspect: false),
                       bounds)
    }
}

final class CropSnappingTests: XCTestCase {
    private let imageSize = CGSize(width: 1000, height: 800)

    func testItSnapsWithinTheThresholdAndNotOutsideIt() {
        let guides = CropSnapping.defaultGuides(imageSize: imageSize)
        let near = CGRect(x: 3, y: 4, width: 500, height: 400)
        XCTAssertEqual(CropSnapping.snap(near, xGuides: guides.x, yGuides: guides.y,
                                         threshold: 10).minX, 0)

        let far = CGRect(x: 60, y: 60, width: 500, height: 400)
        XCTAssertEqual(CropSnapping.snap(far, xGuides: guides.x, yGuides: guides.y,
                                         threshold: 10).minX, 60)
    }

    func testItPrefersTheNearerGuideWhenTwoAreInRange() {
        let snapped = CropSnapping.snap(CGRect(x: 96, y: 0, width: 100, height: 100),
                                        xGuides: [90, 100], yGuides: [0], threshold: 20)
        XCTAssertEqual(snapped.minX, 100)
    }

    func testSnappingNeverCollapsesTheRect() {
        // Both edges pulled to the same guide would produce a zero-width crop.
        let snapped = CropSnapping.snap(CGRect(x: 98, y: 0, width: 4, height: 100),
                                        xGuides: [100], yGuides: [0, 100], threshold: 20)
        XCTAssertGreaterThan(snapped.width, 0)
    }

    func testAspectConstrainStaysInsideTheImageWithoutChangingRatio() {
        let constrained = CropSnapping.constrain(
            CGRect(x: 0, y: 0, width: 5000, height: 100), to: .sixteenNine,
            anchor: .zero, originalSize: imageSize, imageSize: imageSize)
        XCTAssertEqual(constrained.width / constrained.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(constrained.maxX, imageSize.width + 0.001)
        XCTAssertLessThanOrEqual(constrained.maxY, imageSize.height + 0.001)
    }

    func testFreeMeansNoConstraint() {
        let rect = CGRect(x: 10, y: 10, width: 123, height: 45)
        XCTAssertEqual(CropSnapping.constrain(rect, to: .free, anchor: .zero,
                                              originalSize: imageSize, imageSize: imageSize),
                       rect)
    }
}
