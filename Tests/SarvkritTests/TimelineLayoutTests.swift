import XCTest
@testable import Sarvkrit

/// What the timeline shows, and where.
///
/// **The view used to hardcode two tracks.** `clipTrack` and `zoomTrack` were hand-placed rects,
/// `preferredHeight` was a closed-form sum of exactly those two, and each had its own bespoke hit
/// test. Five of the project's own collections therefore had no representation at all — masks,
/// camera segments, captions, pointer highlights, and text once it existed. "There are no layers"
/// was a fair description of a timeline that could only show two.
///
/// None of that geometry was testable while it lived inside `draw(_:)`. This is why it moved.
final class TimelineLayoutTests: XCTestCase {

    private func project(seconds: Double = 10) -> StudioProject {
        StudioProject(canvasSize: CGSize(width: 100, height: 100),
                      timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: seconds)]))
    }

    private func rows(_ project: StudioProject,
                      selection: TimelineLayout.Selection = .init()) -> [TimelineLayout.Row] {
        TimelineLayout.rows(project: project, events: EventLog(), selection: selection)
    }

    // MARK: - Which rows appear

    /// A bare project shows the two rows that are always meaningful and nothing else, so the
    /// timeline is not a wall of empty tracks.
    func testABareProjectShowsOnlyVideoAndZoom() {
        XCTAssertEqual(rows(project()).map(\.kind), [.video, .zoom])
    }

    /// And a row appears when you add the first of something, which is how you learn it exists.
    func testARowAppearsWithItsFirstItem() {
        var edited = project()
        edited.textOverlays = [TextOverlay(start: 1, end: 3, text: "Hi")]
        edited.pointerHighlights = [PointerHighlight(start: 4, end: 5)]

        let kinds = rows(edited).map(\.kind)
        XCTAssertTrue(kinds.contains(.text))
        XCTAssertTrue(kinds.contains(.pointer))
        XCTAssertFalse(kinds.contains(.camera), "an empty row is noise")
    }

    /// The order never changes, so the timeline does not rearrange itself as you work.
    func testRowOrderIsStable() {
        var edited = project()
        edited.pointerHighlights = [PointerHighlight(start: 1, end: 2)]
        edited.textOverlays = [TextOverlay(start: 1, end: 2)]
        edited.cameraSegments = [CameraSegment(start: 1, end: 2, layout: .hidden)]

        XCTAssertEqual(rows(edited).map(\.kind), [.video, .text, .camera, .zoom, .pointer])
    }

    // MARK: - Where items land

    func testAClipSpansItsOutputRange() throws {
        let row = try XCTUnwrap(rows(project(seconds: 8)).first { $0.kind == .video })
        let item = try XCTUnwrap(row.items.first)
        XCTAssertEqual(item.start, 0, accuracy: 1e-9)
        XCTAssertEqual(item.end, 8, accuracy: 1e-9)
    }

    /// Source-time tracks are placed by where their material ended up, which is the whole point of
    /// storing them in source time — a trim moves the picture and the zoom together.
    func testASegmentIsPlacedWhereItsMaterialEndedUp() throws {
        var trimmed = project()
        trimmed.timeline = Timeline(clips: [Clip(sourceStart: 4, sourceEnd: 10)])
        trimmed.textOverlays = [TextOverlay(start: 6, end: 8, text: "Hi")]

        let row = try XCTUnwrap(rows(trimmed).first { $0.kind == .text })
        let item = try XCTUnwrap(row.items.first)
        XCTAssertEqual(item.start, 2, accuracy: 1e-9, "source 6 is output 2 after trimming to 4")
        XCTAssertEqual(item.end, 4, accuracy: 0.01)
    }

    /// Something the edit cut out entirely is not drawn at all, rather than piled at zero.
    func testAnItemWhoseMaterialWasCutIsDropped() throws {
        var trimmed = project()
        trimmed.timeline = Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 2)])
        trimmed.textOverlays = [TextOverlay(start: 7, end: 9, text: "Gone")]

        XCTAssertFalse(rows(trimmed).contains { $0.kind == .text })
    }

    func testSelectionMarksExactlyOneItem() throws {
        var edited = project()
        let first = TextOverlay(start: 1, end: 2, text: "A")
        let second = TextOverlay(start: 3, end: 4, text: "B")
        edited.textOverlays = [first, second]

        let row = try XCTUnwrap(
            rows(edited, selection: .init(text: second.id)).first { $0.kind == .text })
        XCTAssertEqual(row.items.filter(\.isSelected).map(\.id), [second.id])
    }

    /// A disabled zoom is shown dimmed rather than hidden: it is still part of the edit.
    func testADisabledZoomIsMutedNotMissing() throws {
        var edited = project()
        var zoom = ZoomSegment(start: 1, end: 4, level: 2, anchor: .fixed(.zero))
        zoom.isDisabled = true
        edited.zooms = [zoom]

        let row = try XCTUnwrap(rows(edited).first { $0.kind == .zoom })
        XCTAssertEqual(row.items.count, 1)
        XCTAssertTrue(try XCTUnwrap(row.items.first).isMuted)
    }

    // MARK: - Geometry

    func testTheViewGrowsWithItsRows() {
        let two = TimelineLayout.preferredHeight(rowCount: 2)
        let five = TimelineLayout.preferredHeight(rowCount: 5)
        XCTAssertGreaterThan(five, two)
    }

    func testRowsStackWithoutOverlapping() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let first = TimelineLayout.rect(ofRow: 0, in: bounds)
        let second = TimelineLayout.rect(ofRow: 1, in: bounds)

        XCTAssertLessThanOrEqual(first.maxY, second.minY)
        XCTAssertEqual(first.height, second.height, accuracy: 0.001)
    }

    /// Every row fits inside the height the view asked for, or the last one is clipped.
    func testEveryRowFitsInsideThePreferredHeight() {
        let count = 6
        let height = TimelineLayout.preferredHeight(rowCount: count)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: height)
        for index in 0..<count {
            XCTAssertLessThanOrEqual(TimelineLayout.rect(ofRow: index, in: bounds).maxY, height)
        }
    }
}
