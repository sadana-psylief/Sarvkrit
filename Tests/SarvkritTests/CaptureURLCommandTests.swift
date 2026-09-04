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
                                             displayIndex: nil))
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

    func testADisplayIsCountedFromOneTheWayAScriptWouldWriteIt() {
        // Not a CGDirectDisplayID: nobody writing a shell script can discover one of those, and
        // the reference documents "1 is the main display, 2 is the secondary".
        XCTAssertEqual(parse("sarvkrit://capture-area?x=1&y=2&width=3&height=4&display=2"),
                       .captureRect(CGRect(x: 1, y: 2, width: 3, height: 4), displayIndex: 2))
        XCTAssertEqual(parse("sarvkrit://capture-area?x=1&y=2&width=3&height=4&display=0"),
                       .captureRect(CGRect(x: 1, y: 2, width: 3, height: 4), displayIndex: nil),
                       "0 is not a display; fall back to the pointer's rather than guessing")
    }

    func testCoordinatesOnlyApplyToCaptureArea() {
        // A window capture with an x and a y is meaningless, and honouring it would turn one mode
        // into another without saying so.
        XCTAssertEqual(parse("sarvkrit://capture-window?x=1&y=2&width=3&height=4"),
                       .action(.window))
    }

    func testTheRectFormStillNamesItselfCaptureArea() {
        XCTAssertEqual(CaptureURLCommand.captureRect(.zero, displayIndex: nil).name, "capture-area")
    }
}

/// The crop a script's rect produces is the crop a drag produces.
final class CaptureRectSessionTests: XCTestCase {

    private func display(_ id: CGDirectDisplayID, scale: CGFloat,
                         origin: CGPoint = .zero) -> DisplaySnapshotGeometry {
        DisplaySnapshotGeometry(
            displayID: id,
            frame: CGRect(origin: origin, size: CGSize(width: 400, height: 300)),
            scale: scale,
            pixelSize: CGSize(width: 400 * scale, height: 300 * scale))
    }

    private func capturer(_ geometries: DisplaySnapshotGeometry...) -> StubScreenCaptureService {
        StubScreenCaptureService(displays: geometries)
    }

    func testARectComesBackAtTheDisplaysOwnScale() async throws {
        let result = try await CaptureSession.captureRect(
            CGRect(x: 50, y: 40, width: 120, height: 90),
            using: capturer(display(1, scale: 2)), options: CaptureOptions())
        let image = try XCTUnwrap(result?.image)
        XCTAssertEqual(image.width, 240)
        XCTAssertEqual(image.height, 180)
    }

    func testARectIsClampedToTheDisplayRatherThanFailing() async throws {
        let result = try await CaptureSession.captureRect(
            CGRect(x: 350, y: 250, width: 200, height: 200),
            using: capturer(display(1, scale: 2)), options: CaptureOptions())
        let image = try XCTUnwrap(result?.image)
        XCTAssertEqual(image.width, 100, "clamped to the 50pt that is actually there")
        XCTAssertEqual(image.height, 100)
    }

    func testARectEntirelyOffTheDisplayCapturesNothing() async throws {
        let result = try await CaptureSession.captureRect(
            CGRect(x: 900, y: 900, width: 100, height: 100),
            using: capturer(display(1, scale: 2)), options: CaptureOptions())
        XCTAssertNil(result, "better nothing than a screenshot of somewhere else")
    }

    /// Coordinates are relative to the chosen screen, not to the desktop.
    ///
    /// The two are the same on the main display and differ on every other, which is why a
    /// single-monitor Mac cannot tell this apart — the same blind spot `ScreenCoordinatesTests`
    /// records for the other flip.
    func testCoordinatesAreRelativeToTheChosenScreen() async throws {
        let main = display(1, scale: 2)
        let secondary = display(2, scale: 2, origin: CGPoint(x: -400, y: 0))
        let result = try await CaptureSession.captureRect(
            CGRect(x: 10, y: 20, width: 100, height: 80), displayIndex: 2,
            using: capturer(main, secondary), options: CaptureOptions())

        // 10pt from the secondary's own left edge, which is −390 on the desktop.
        XCTAssertEqual(result?.sourceRect, CGRect(x: -390, y: 20, width: 100, height: 80))
        XCTAssertEqual(result?.display?.displayID, 2)
    }

    @MainActor
    func testDisplayOneIsAlwaysTheMainOneWhateverOrderTheyArriveIn() async throws {
        // ScreenCaptureKit's enumeration order is not promised, and `display=2` meaning a
        // different monitor on different days would be worse than not supporting it.
        let main = display(CGMainDisplayID(), scale: 2)
        let left = display(99, scale: 2, origin: CGPoint(x: -400, y: 0))
        let ordered = CaptureSession.orderedForScripting([
            DisplayFrame(geometry: left, image: try Self.pixel()),
            DisplayFrame(geometry: main, image: try Self.pixel()),
        ])
        XCTAssertEqual(ordered.first?.geometry.displayID, CGMainDisplayID())
    }

    func testAskingForADisplayThatIsNotThereCapturesNothing() async throws {
        do {
            _ = try await CaptureSession.captureRect(
                CGRect(x: 0, y: 0, width: 10, height: 10), displayIndex: 5,
                using: capturer(display(1, scale: 2)), options: CaptureOptions())
            XCTFail("monitor 5 on a one-monitor Mac is a bug in the script, not a capture")
        } catch {
            // Expected.
        }
    }

    func testItAgreesWithWhatADragOfTheSameRectWouldProduce() async throws {
        // The point of sharing `CaptureGeometry.pixelRect`: two aiming methods, one crop.
        let geometry = display(1, scale: 2, origin: CGPoint(x: -400, y: 0))
        let relative = CGRect(x: 100, y: 60, width: 160, height: 120)
        let result = try await CaptureSession.captureRect(
            relative, using: capturer(geometry), options: CaptureOptions())
        let image = try XCTUnwrap(result?.image)

        let global = relative.offsetBy(dx: geometry.frame.minX, dy: geometry.frame.minY)
        let expected = CaptureGeometry.pixelRect(forGlobalRect: global, in: geometry).integral
        XCTAssertEqual(CGFloat(image.width), expected.width)
        XCTAssertEqual(CGFloat(image.height), expected.height)
        XCTAssertEqual(result?.sourceRect, global)
    }

    private static func pixel() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }
}

/// The thumbnail cache, which used to answer the wrong size.
@MainActor
final class CaptureThumbnailCacheTests: XCTestCase {

    private func store() throws -> (CaptureHistoryStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (CaptureHistoryStore(directory: directory), directory)
    }

    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testTwoSizesOfTheSameCaptureAreBothTheSizeThatWasAskedFor() throws {
        // The bug: keyed by id alone, so whichever caller ran first decided the size for the
        // other. The shelf asks for 430 and the drag proxy for 240, and the aspect ratio was
        // right either way — which is why it never looked obviously wrong.
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(800, 400), mode: .area,
                                           sourceRect: .zero, displayID: nil))

        let large = try XCTUnwrap(store.thumbnail(for: item, height: 430))
        let small = try XCTUnwrap(store.thumbnail(for: item, height: 240))
        XCTAssertEqual(large.size.height, 430, accuracy: 0.5)
        XCTAssertEqual(small.size.height, 240, accuracy: 0.5)
        XCTAssertEqual(large.size.width / large.size.height,
                       small.size.width / small.size.height, accuracy: 0.01)
    }

    func testAskingTwiceForOneSizeReusesTheSameImage() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(800, 400), mode: .area,
                                           sourceRect: .zero, displayID: nil))
        let first = try XCTUnwrap(store.thumbnail(for: item, height: 240))
        let second = try XCTUnwrap(store.thumbnail(for: item, height: 240))
        XCTAssertTrue(first === second, "the cache stopped caching")
    }

    func testRemovingACaptureDropsEverySizeOfIt() throws {
        // Invalidation is by id and the key is now a pair, so a naive `removeValue(forKey: id)`
        // would leave every other size behind — and a stale thumbnail outliving its file is the
        // shelf showing a picture that is no longer there.
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try XCTUnwrap(store.add(image: try image(800, 400), mode: .area,
                                           sourceRect: .zero, displayID: nil))
        _ = store.thumbnail(for: item, height: 430)
        _ = store.thumbnail(for: item, height: 240)
        store.remove(id: item.id)

        XCTAssertNil(store.thumbnail(for: item, height: 430))
        XCTAssertNil(store.thumbnail(for: item, height: 240))
    }
}
