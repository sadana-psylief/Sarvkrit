import XCTest
@testable import Sarvkrit

/// The `sarvkrit://` scheme.
///
/// The rule worth pinning: an unrecognised command does *nothing*. Defaulting a typo to some
/// capture mode would mean a script with a spelling mistake quietly takes screenshots.
final class CaptureURLCommandTests: XCTestCase {

    private func parse(_ string: String) -> CaptureURLCommand? {
        guard let url = URL(string: string) else { return nil }
        return CaptureURLCommand.parse(url)
    }

    func testEveryCaptureModeHasACommand() {
        // The counterpart of `testEveryCaptureModeIsReachableByShortcut`: a mode reachable by key
        // but not by script is a mode Raycast and Shortcuts cannot see.
        for action in ScreenshotAction.allCases {
            let command = CaptureURLCommand.action(action)
            XCTAssertEqual(parse("sarvkrit://\(command.name)"), command, "\(action.rawValue)")
        }
    }

    func testTheCommandNamesFollowTheOnesScriptsAlreadyUse() {
        XCTAssertEqual(parse("sarvkrit://capture-area"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-window"), .action(.window))
        XCTAssertEqual(parse("sarvkrit://capture-fullscreen"), .action(.fullscreen))
        XCTAssertEqual(parse("sarvkrit://all-in-one"), .action(.allInOne))
        XCTAssertEqual(parse("sarvkrit://scrolling-capture"), .action(.scrolling))
        XCTAssertEqual(parse("sarvkrit://capture-text"), .action(.textRecognition))
        XCTAssertEqual(parse("sarvkrit://open-history"), .action(.history))
        XCTAssertEqual(parse("sarvkrit://restore-recently-closed"), .action(.restoreOverlay))
    }

    func testCancelIsReachable() {
        // The scriptable escape hatch. It has to work even when everything else is wedged, which
        // is the one case where its own name being wrong would be unrecoverable.
        XCTAssertEqual(parse("sarvkrit://cancel"), .cancel)
    }

    func testTheNumberOfSlashesIsNotLoadBearing() {
        XCTAssertEqual(parse("sarvkrit:///capture-area"), .action(.area))
        XCTAssertEqual(parse("sarvkrit:capture-area"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-area/"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://CAPTURE-AREA"), .action(.area))
        XCTAssertEqual(parse("SARVKRIT://capture-area"), .action(.area))
    }

    func testAQueryStringIsIgnoredRatherThanRejected() {
        // Room for parameters later without breaking links written today.
        XCTAssertEqual(parse("sarvkrit://capture-area?display=1"), .action(.area))
    }

    func testATypoDoesNothing() {
        XCTAssertNil(parse("sarvkrit://capture-are"))
        XCTAssertNil(parse("sarvkrit://"))
        XCTAssertNil(parse("sarvkrit://../../etc/passwd"))
        XCTAssertNil(parse("cleanshot://capture-area"), "another app's scheme is not ours")
        XCTAssertNil(parse("https://capture-area"))
    }

    func testEveryCommandNameIsDistinct() {
        let names = CaptureURLCommand.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "two commands share a name: \(names)")
    }
}

/// `capture-area` with coordinates: take this rect now, no overlay.
final class CaptureURLRectTests: XCTestCase {

    private func parse(_ string: String) -> CaptureURLCommand? {
        URL(string: string).flatMap(CaptureURLCommand.parse)
    }

    func testAllFourCoordinatesMeanCaptureItNow() {
        let command = parse("sarvkrit://capture-area?x=100&y=200&width=300&height=400")
        XCTAssertEqual(command, .captureRect(CGRect(x: 100, y: 200, width: 300, height: 400),
                                             displayID: nil))
    }

    func testAPartialRectOpensTheOverlayInstead() {
        // Three of four is a script with a bug in it. Guessing the fourth would silently capture
        // the wrong thing; falling back to the overlay lets the person see what is happening.
        XCTAssertEqual(parse("sarvkrit://capture-area?x=100&y=200&width=300"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-area?width=300&height=400"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-area"), .action(.area))
    }

    func testAnEmptyRectIsRefused() {
        XCTAssertEqual(parse("sarvkrit://capture-area?x=0&y=0&width=0&height=400"), .action(.area))
        XCTAssertEqual(parse("sarvkrit://capture-area?x=0&y=0&width=-5&height=400"), .action(.area))
    }

    func testADisplayCanBeNamed() {
        XCTAssertEqual(parse("sarvkrit://capture-area?x=1&y=2&width=3&height=4&display=7"),
                       .captureRect(CGRect(x: 1, y: 2, width: 3, height: 4), displayID: 7))
    }

    func testCoordinatesOnlyApplyToCaptureArea() {
        // A window capture with an x and a y is meaningless, and honouring it would turn one mode
        // into another without saying so.
        XCTAssertEqual(parse("sarvkrit://capture-window?x=1&y=2&width=3&height=4"),
                       .action(.window))
    }

    func testTheRectFormStillNamesItselfCaptureArea() {
        XCTAssertEqual(CaptureURLCommand.captureRect(.zero, displayID: nil).name, "capture-area")
    }
}

/// The crop a script's rect produces is the crop a drag produces.
final class CaptureRectSessionTests: XCTestCase {

    private func display(scale: CGFloat, origin: CGPoint = .zero) -> DisplaySnapshotGeometry {
        DisplaySnapshotGeometry(
            displayID: 1,
            frame: CGRect(origin: origin, size: CGSize(width: 400, height: 300)),
            scale: scale,
            pixelSize: CGSize(width: 400 * scale, height: 300 * scale))
    }

    private func capturer(_ geometry: DisplaySnapshotGeometry) -> StubScreenCaptureService {
        StubScreenCaptureService(displays: [geometry])
    }

    func testARectComesBackAtTheDisplaysOwnScale() async throws {
        let geometry = display(scale: 2)
        let result = try await CaptureSession.captureRect(
            CGRect(x: 50, y: 40, width: 120, height: 90),
            using: capturer(geometry), options: CaptureOptions())
        let image = try XCTUnwrap(result?.image)
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 180)
    }

    func testARectIsClampedToTheDisplayRatherThanFailing() async throws {
        let geometry = display(scale: 2)
        let result = try await CaptureSession.captureRect(
            CGRect(x: 350, y: 250, width: 200, height: 200),
            using: capturer(geometry), options: CaptureOptions())
        let image = try XCTUnwrap(result?.image)
        XCTAssertEqual(image.width, 100, "clamped to the 50pt that is actually there")
        XCTAssertEqual(image.height, 100)
    }

    func testARectEntirelyOffTheDisplayCapturesNothing() async throws {
        let geometry = display(scale: 2)
        let result = try await CaptureSession.captureRect(
            CGRect(x: 900, y: 900, width: 100, height: 100),
            using: capturer(geometry), options: CaptureOptions())
        XCTAssertNil(result, "better nothing than a screenshot of somewhere else")
    }

    func testItAgreesWithWhatADragOfTheSameRectWouldProduce() async throws {
        // The point of sharing `CaptureGeometry.pixelRect`: two aiming methods, one crop.
        let geometry = display(scale: 2, origin: CGPoint(x: -400, y: 0))
        let rect = CGRect(x: -300, y: 60, width: 160, height: 120)
        let result = try await CaptureSession.captureRect(
            rect, using: capturer(geometry), options: CaptureOptions())
        let image = try XCTUnwrap(result?.image)

        let expected = CaptureGeometry.pixelRect(forGlobalRect: rect, in: geometry).integral
        XCTAssertEqual(CGFloat(image.width), expected.width)
        XCTAssertEqual(CGFloat(image.height), expected.height)
        XCTAssertEqual(result?.sourceRect, rect)
    }
}
