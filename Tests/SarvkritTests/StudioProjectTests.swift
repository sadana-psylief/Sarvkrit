import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The project document.
///
/// **A project written by a newer build must open, not error.** That contract is already in force
/// for `AnnotationDocument` and `CaptureBackground.Fill`, and it matters more here: a recording is
/// hundreds of megabytes of somebody's work, and refusing to open it because a later version added
/// a field would be the worst possible way to fail.
final class StudioProjectTests: XCTestCase {

    private func project() -> StudioProject {
        var project = StudioProject(
            canvasSize: CGSize(width: 2560, height: 1440),
            timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: 12)]))
        project.zooms = [ZoomSegment(start: 2, end: 5, level: 2.2, anchor: .followCursor)]
        project.cursor.size = 2.1
        project.cursor.smoothing = .heavy
        project.speakerNotes = "remember to mention the shortcut"
        return project
    }

    private func roundTrip(_ project: StudioProject) throws -> StudioProject {
        let data = try JSONEncoder().encode(project)
        return try JSONDecoder().decode(StudioProject.self, from: data)
    }

    /// One instance, compared with itself after a trip through JSON. Comparing two calls to
    /// `project()` would compare two different objects: every clip and segment mints a fresh UUID,
    /// so that assertion could only ever fail.
    func testAProjectSurvivesARoundTrip() throws {
        let original = project()
        XCTAssertEqual(try roundTrip(original), original)
    }

    func testTheZoomAnchorSurvivesARoundTrip() throws {
        var original = project()
        original.zooms = [ZoomSegment(start: 1, end: 2, level: 2,
                                      anchor: .fixed(CGPoint(x: 0.25, y: 0.75)))]
        guard case .fixed(let point) = try roundTrip(original).zooms.first?.anchor else {
            return XCTFail("the anchor changed kind")
        }
        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
    }

    /// A settings file written before a field existed must load cleanly rather than resetting
    /// everything — the rule `ClipboardSettings` already follows.
    func testAProjectMissingMostKeysDecodesToDefaults() throws {
        let json = """
        {"canvasSize":{"width":1920,"height":1080},"timeline":{"clips":[]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StudioProject.self, from: json)
        XCTAssertEqual(decoded.canvasSize.width, 1920)
        XCTAssertEqual(decoded.cursor.smoothing, CursorSettings().smoothing)
        XCTAssertEqual(decoded.aspect, AspectRatio.original)
        XCTAssertTrue(decoded.zooms.isEmpty)
    }

    /// **The forward-compatibility contract.** A field this build has never heard of is held
    /// verbatim and written back untouched, so opening a project in an older build and saving it
    /// does not quietly delete work done in a newer one.
    func testAnUnknownFieldIsCarriedThroughUnchanged() throws {
        let json = """
        {"canvasSize":{"width":1920,"height":1080},"timeline":{"clips":[]},\
        "somethingFromTheFuture":{"enabled":true,"count":3}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StudioProject.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let asDictionary = try JSONSerialization.jsonObject(with: reEncoded) as? [String: Any]
        XCTAssertNotNil(asDictionary?["somethingFromTheFuture"],
                        "a field from a newer build was dropped on save")
    }

    func testAnUnknownFieldSurvivesTwoRoundTrips() throws {
        let json = """
        {"canvasSize":{"width":100,"height":100},"timeline":{"clips":[]},"future":[1,2,3]}
        """.data(using: .utf8)!
        let once = try JSONDecoder().decode(StudioProject.self, from: json)
        let twice = try roundTrip(once)
        XCTAssertEqual(once.unrecognised, twice.unrecognised)
        XCTAssertFalse(twice.unrecognised.isEmpty)
    }

    func testANewerFormatVersionStillOpens() throws {
        let json = """
        {"formatVersion":99,"canvasSize":{"width":100,"height":100},"timeline":{"clips":[]}}
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(StudioProject.self, from: json).formatVersion, 99)
    }

    /// Nothing this app writes should ever fail to reopen.
    func testAFreshProjectIsAlwaysReadable() throws {
        let fresh = StudioProject(canvasSize: CGSize(width: 800, height: 600),
                                  timeline: Timeline(clips: []))
        XCTAssertNoThrow(try roundTrip(fresh))
    }

    // MARK: - Derived

    func testTheProjectReportsItsOwnDuration() {
        XCTAssertEqual(project().duration, 12, accuracy: 0.0001)
    }

    /// A zoom whose moment was cut out has nowhere to be drawn, and asking the renderer to work
    /// that out per frame would be the same question asked sixty times a second.
    func testZoomsWhoseMomentWasCutAreDroppedFromTheEdit() {
        var edited = project()
        edited.timeline = Timeline(clips: [Clip(sourceStart: 8, sourceEnd: 12)])
        XCTAssertTrue(edited.visibleZooms.isEmpty)
    }

    func testZoomsInsideTheEditAreKept() {
        XCTAssertEqual(project().visibleZooms.count, 1)
    }

    func testADisabledZoomIsNotVisible() {
        var edited = project()
        edited.zooms[0].isDisabled = true
        XCTAssertTrue(edited.visibleZooms.isEmpty)
    }
}
