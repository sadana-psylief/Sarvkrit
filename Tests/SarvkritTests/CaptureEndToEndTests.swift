import AppKit
import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The whole chain, from a capture arriving to a file another app can accept.
///
/// **What this exists to cover.** Every stage of this feature has its own unit tests, and they all
/// passed while the editor rendered upside down — because nothing exercised the stages *together*.
/// These drive the real types end to end with only the ScreenCaptureKit call stubbed, which is the
/// one part that cannot run in the test host without a TCC grant.
///
/// The literal mouse drag is still not covered: `CaptureOverlayController` needs an `NSEvent`.
/// Everything either side of it is.
@MainActor
final class CaptureEndToEndTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// A recognisable image: a red top half over a blue bottom half.
    private func scene(_ width: Int = 400, _ height: Int = 300) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.15, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.25, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixel(_ image: CGImage, x: Int, yFromTop: Int) throws -> (Int, Int, Int) {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(buffer.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (yFromTop * image.width + x) * 4
        return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
    }

    // MARK: - Capture → file another app can take

    func testACaptureBecomesAFileThatIsReadyToShare() async throws {
        let display = DisplaySnapshotGeometry(
            displayID: 1, frame: CGRect(x: 0, y: 0, width: 200, height: 150), scale: 2,
            pixelSize: CGSize(width: 400, height: 300))
        let capturer = StubScreenCaptureService(displays: [display])
        let store = CaptureHistoryStore(directory: root)

        // 1. The capture itself.
        let frames = try await capturer.snapshotAllDisplays(options: CaptureOptions())
        let frame = try XCTUnwrap(frames.first)

        // 2. A selection, cropped the way the overlay crops it.
        var gesture = SelectionGesture(display: display)
        gesture.began(at: CGPoint(x: 40, y: 30))
        gesture.moved(to: CGPoint(x: 140, y: 105))
        let rect = try XCTUnwrap(gesture.ended())
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: rect, in: display)
        let cropped = try XCTUnwrap(frame.image.cropping(to: pixels.integral))
        XCTAssertEqual(cropped.width, 200, "100pt at 2x")

        // 3. Filed, which is what makes it draggable at all.
        let item = try XCTUnwrap(store.add(image: cropped, mode: .area,
                                           sourceRect: rect, displayID: display.displayID))
        let url = store.url(for: item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the overlay drags a file URL, so the file must exist before it appears")

        // 4. What a drop into another app actually receives.
        let dropped = try XCTUnwrap(NSImage(contentsOf: url))
        XCTAssertEqual(dropped.size.width, 200)

        // 5. And the clipboard route.
        XCTAssertNotNil(CaptureWriter.pngData(from: cropped))
    }

    func testTheSharedFileIsTheRightWayUp() async throws {
        // The bug that survived a green suite: every stage passed, the composition was inverted.
        let display = StubScreenCaptureService.defaultDisplay
        let capturer = StubScreenCaptureService(displays: [display])
        _ = try await capturer.snapshotAllDisplays(options: CaptureOptions())

        let base = try scene()
        let store = CaptureHistoryStore(directory: root)
        let item = try XCTUnwrap(store.add(image: base, mode: .area))

        let reloaded = try XCTUnwrap(NSImage(contentsOf: store.url(for: item)))
        let cgImage = try XCTUnwrap(reloaded.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertGreaterThan(try pixel(cgImage, x: 200, yFromTop: 20).0, 180, "top stays red")
        XCTAssertGreaterThan(try pixel(cgImage, x: 200, yFromTop: 280).2, 180, "bottom stays blue")
    }

    // MARK: - Capture → annotate → save → reopen

    func testAnnotatingAndSavingRoundTripsThroughTheRealFileFormat() throws {
        let base = try scene()
        let store = CaptureHistoryStore(directory: root)
        let item = try XCTUnwrap(store.add(image: base, mode: .area))

        // Open it the way the overlay's Annotate button does.
        let data = try Data(contentsOf: store.url(for: item))
        let contents = try CaptureDocumentFile.decode(data)
        let model = EditorDocumentModel(base: contents.base ?? contents.flattened,
                                        document: contents.document,
                                        historyItemID: item.id)

        model.edit {
            $0.add(.arrow(ArrowElement(start: CGPoint(x: 40, y: 240),
                                       end: CGPoint(x: 300, y: 60),
                                       head: .curved,
                                       stroke: StrokeStyle(colour: .yellow, width: 14))))
        }
        var style = CaptureBackground()
        style.padding = 40
        style.aspect = AspectRatio.free
        model.edit { $0.background = style }

        // Save the way Done does, and write it back where the overlay pointed.
        let flattened = try XCTUnwrap(model.flattenWithBackground())
        XCTAssertEqual(flattened.width, 400 + 80, "the background widened the canvas")
        XCTAssertTrue(store.replaceImage(of: item.id, with: flattened))
        XCTAssertEqual(store.items.count, 1, "editing replaces in place rather than adding")

        // Save-as-editable, then reopen and confirm the annotation survived as an annotation.
        let editable = try CaptureDocumentFile.encode(document: model.document,
                                                      base: model.base, flattened: flattened)
        let reopened = try CaptureDocumentFile.decode(editable)
        XCTAssertEqual(reopened.document?.elements.count, 1)
        guard case .arrow(let arrow) = try XCTUnwrap(reopened.document?.elements.first?.kind) else {
            return XCTFail("the arrow should come back as an arrow, not as pixels")
        }
        XCTAssertEqual(arrow.head, .curved)
        XCTAssertEqual(reopened.document?.background?.padding, 40)
    }

    // MARK: - Scrolling capture

    func testScrollingCaptureStitchesATallPageFromRealFrames() throws {
        // The full scrolling path minus the user's scroll wheel: real bitmaps, real signatures,
        // real plan, real blit.
        let width = 120, viewport = 90, step = 30
        let page = try tallPage(width: width, height: 240)
        let frames = try (0..<6).map { index -> CGImage in
            let y = min(index * step, 240 - viewport)
            return try XCTUnwrap(page.cropping(to: CGRect(x: 0, y: y,
                                                          width: width, height: viewport)))
        }

        let scrollFrames = frames.map {
            ScrollFrame(lines: ImageLineSignature.signatures(of: $0, axis: .vertical),
                        width: $0.width, height: $0.height)
        }
        let plan = ScrollStitcher.plan(frames: scrollFrames, axis: .vertical,
                                       options: ScrollStitcher.Options(minimumOverlap: 12,
                                                                       minimumMargin: 0.1,
                                                                       frameLimit: 40))
        XCTAssertGreaterThan(plan.totalLength, viewport,
                             "a stitch must be taller than one viewport or it did nothing")
        XCTAssertLessThanOrEqual(plan.totalLength, 240 + 2)

        let stitched = try XCTUnwrap(ScrollStitcher.render(plan, images: frames, axis: .vertical))
        XCTAssertEqual(stitched.width, width)
        XCTAssertEqual(stitched.height, plan.totalLength)

        // And it files like any other capture.
        let store = CaptureHistoryStore(directory: root)
        XCTAssertNotNil(store.add(image: stitched, mode: .scrolling))
        XCTAssertEqual(store.items.first?.mode, .scrolling)
    }

    /// A page of distinct numbered bands, so a stitch that duplicates or drops one is detectable.
    private func tallPage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for row in 0..<height {
            let value = Double((row * 7) % 251) / 255
            context.setFillColor(CGColor(srgbRed: value, green: 1 - value,
                                         blue: Double((row * 3) % 251) / 255, alpha: 1))
            context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - One shortcut, every mode

    func testEveryCaptureModeIsReachableByShortcut() {
        // "One shortcut. Every capture mode." Two readings, and both have to hold: every mode has
        // its own key, *and* one key opens a picker containing all of them.
        let bindings = ScreenshotAction.defaults
        let byMode: [CaptureMode: ScreenshotAction] = [
            .area: .area, .window: .window, .fullscreen: .fullscreen,
            .scrolling: .scrolling, .textRecognition: .textRecognition,
        ]
        for (mode, action) in byMode {
            XCTAssertNotNil(bindings[action], "\(mode) has no shortcut")
        }
        XCTAssertNotNil(bindings[.allInOne], "there must be one key that opens all of them")
    }

    func testTheAllInOnePickerRemembersWhatYouChose() {
        // The retake: press the key, the mode and size you used last are already set.
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        CaptureModeMemory(mode: .scrolling, pixelSize: CGSize(width: 1280, height: 720),
                          aspectLocked: true).save(to: defaults)
        let remembered = CaptureModeMemory.load(from: defaults)
        XCTAssertEqual(remembered.mode, .scrolling)
        XCTAssertEqual(remembered.pixelSize, CGSize(width: 1280, height: 720))
    }

    // MARK: - A month of history

    func testHistoryKeepsAMonthByDefault() throws {
        // "Store up to 1 month of history" — the default, not merely an option.
        let store = CaptureHistoryStore(directory: root)
        XCTAssertEqual(store.retention, .month)

        let now = Date()
        let ids = (id: UUID(), createdAt: now.addingTimeInterval(-29 * 86_400))
        XCTAssertTrue(CaptureRetention.expired(items: [ids], now: now, window: .month).isEmpty,
                      "29 days old must survive")
        let old = (id: UUID(), createdAt: now.addingTimeInterval(-31 * 86_400))
        XCTAssertEqual(CaptureRetention.expired(items: [old], now: now, window: .month).count, 1,
                       "31 days old must not")
    }

    func testACaptureFromThreeWeeksAgoIsStillThereAfterAReload() throws {
        let store = CaptureHistoryStore(directory: root)
        _ = store.add(image: try scene(40, 30), mode: .area)
        store.flush()

        let indexURL = root.appendingPathComponent("captures.json")
        var items = try JSONDecoder().decode([CaptureHistoryItem].self,
                                             from: Data(contentsOf: indexURL))
        items[0].createdAt = Date(timeIntervalSinceNow: -21 * 86_400)
        try JSONEncoder().encode(items).write(to: indexURL)

        let reloaded = CaptureHistoryStore(directory: root)
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: reloaded.url(for: reloaded.items[0]).path))
    }
}

/// The interactive half: a real drag on the real overlay view.
///
/// **This is the part I could not reach before.** Driving it through the window server needs an
/// Accessibility grant the test host does not have, so it stayed unverified — but the view's
/// handlers take `NSEvent`s, and those can be constructed. Synthesising the drag exercises exactly
/// the code a mouse would, including the crop out of the frozen bitmap.
@MainActor
final class SelectionOverlayInteractionTests: XCTestCase {

    private final class Recorder: SelectionViewDelegate {
        var confirmed: CGRect?
        var confirmedWindow: CapturableWindow?
        var cancelled = false
        func selectionView(_ view: SelectionView, didConfirm rect: CGRect) { confirmed = rect }
        func selectionView(_ view: SelectionView, didConfirmWindow window: CapturableWindow) {
            confirmedWindow = window
        }
        func selectionViewDidCancel(_ view: SelectionView) { cancelled = true }
    }

    private let display = DisplaySnapshotGeometry(
        displayID: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), scale: 2,
        pixelSize: CGSize(width: 800, height: 600))

    private func frozen() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        return try XCTUnwrap(context.makeImage())
    }

    /// A view inside a real window, so `convert(_:from:)` behaves as it does in the app.
    private func makeView(mode: SelectionMode = .area) throws -> (SelectionView, Recorder) {
        let view = SelectionView(display: display, frozenImage: try frozen(), mode: mode)
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        let recorder = Recorder()
        view.delegate = recorder
        return (view, recorder)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint,
                       clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0,
            clickCount: clickCount, pressure: 1))
    }

    func testADragSettlesTheSelectionRatherThanFiringImmediately() throws {
        let (view, recorder) = try makeView()
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 60)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 240, y: 180)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 240, y: 180)))

        XCTAssertNil(recorder.confirmed, "mouse-up settles; it does not take the shot")
        XCTAssertFalse(recorder.cancelled)
    }

    func testClickingInsideASettledSelectionTakesIt() throws {
        let (view, recorder) = try makeView()
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 60)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 240, y: 180)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 240, y: 180)))

        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 160, y: 120)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 160, y: 120)))

        let rect = try XCTUnwrap(recorder.confirmed)
        XCTAssertEqual(rect.width, 160, accuracy: 1)
        XCTAssertEqual(rect.height, 120, accuracy: 1)
    }

    func testTheConfirmedRectCropsTheFrozenBitmapCorrectly() throws {
        let (view, recorder) = try makeView()
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 200, y: 175)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 200, y: 175)))
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 150, y: 140)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 150, y: 140)))

        let rect = try XCTUnwrap(recorder.confirmed)
        let pixels = CaptureGeometry.pixelRect(forGlobalRect: rect, in: display)
        let cropped = try XCTUnwrap(try frozen().cropping(to: pixels.integral),
                                    "the crop fell outside the bitmap: \(pixels)")
        XCTAssertEqual(cropped.width, 200, accuracy: 2, "100pt at 2x")
        XCTAssertEqual(cropped.height, 150, accuracy: 2)
    }

    func testAClickWithNoDragDismisses() throws {
        // Otherwise a stray click leaves the user behind a full-screen overlay.
        let (view, recorder) = try makeView()
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 200, y: 150)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 201, y: 151)))
        XCTAssertTrue(recorder.cancelled)
        XCTAssertNil(recorder.confirmed)
    }

    func testEscapeCancels() throws {
        let (view, recorder) = try makeView()
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 80, y: 60)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 240, y: 180)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 240, y: 180)))

        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        view.keyDown(with: escape)

        XCTAssertTrue(recorder.cancelled)
        XCTAssertNil(recorder.confirmed)
    }

    func testDraggingAHandleResizesTheSettledSelection() throws {
        let (view, recorder) = try makeView()
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 200, y: 180)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 200, y: 180)))

        // Grab the bottom-right handle and pull it out.
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 200, y: 180)))
        view.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 300, y: 250)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 250)))

        XCTAssertNil(recorder.confirmed, "adjusting is not confirming")

        // Inside the rect, not on the corner — a press on the corner is another handle grab.
        view.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 180, y: 160)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 180, y: 160)))
        let rect = try XCTUnwrap(recorder.confirmed)
        XCTAssertGreaterThan(rect.width, 150, "the handle drag should have widened it")
    }

    func testHoveringAWindowInWindowModeHighlightsAndClickTakesIt() throws {
        let target = CapturableWindow(id: 7, frame: CGRect(x: 60, y: 40, width: 200, height: 140),
                                      title: "Target", owningBundleID: "com.example",
                                      owningAppName: "Example", layer: 0, isOnScreen: true)
        let (view, recorder) = try makeView(mode: .window([target]))

        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 150, y: 100)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 150, y: 100)))

        XCTAssertEqual(recorder.confirmedWindow?.id, 7)
    }

    func testClickingEmptySpaceInWindowModeDismisses() throws {
        let target = CapturableWindow(id: 7, frame: CGRect(x: 60, y: 40, width: 60, height: 40),
                                      title: "Target", owningBundleID: "com.example",
                                      owningAppName: "Example", layer: 0, isOnScreen: true)
        let (view, recorder) = try makeView(mode: .window([target]))
        view.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 350, y: 260)))
        view.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 350, y: 260)))
        XCTAssertTrue(recorder.cancelled)
    }
}
