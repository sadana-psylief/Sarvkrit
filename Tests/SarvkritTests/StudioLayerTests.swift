import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Masks, the camera track and the keystroke overlay — the three layers that are decisions rather
/// than drawing, kept pure so the decisions can be asserted without a pixel.
final class StudioLayerTests: XCTestCase {

    private let canvas = CGSize(width: 1000, height: 600)

    // MARK: - Masks

    private func mask(_ start: TimeInterval, _ end: TimeInterval,
                      mode: StudioMask.Mode = .secureBlur) -> StudioMask {
        StudioMask(mode: mode,
                   rects: [CGRect(x: 100, y: 100, width: 200, height: 50)],
                   start: start, end: end)
    }

    func testAMaskIsVisibleOnlyInsideItsRange() {
        let one = mask(2, 5)
        XCTAssertFalse(one.covers(1.9))
        XCTAssertTrue(one.covers(3))
        XCTAssertFalse(one.covers(5.1))
    }

    /// One mask, several rectangles: "hide every price in this table" is one object with one time
    /// range, not nine to keep in sync.
    func testAMaskCanCoverSeveralRectangles() {
        var many = mask(0, 10)
        many.rects.append(RectBox(CGRect(x: 400, y: 100, width: 120, height: 50)))
        XCTAssertEqual(many.rects.count, 2)
    }

    /// **The safe failure direction, and it is worth a test.** A mask pinned to a window whose
    /// window has gone must stay exactly where it is and stay opaque — uncovering what it was
    /// hiding because the thing moved is the one outcome that must never happen.
    func testAMaskWhoseWindowVanishesStaysPut() {
        var pinned = mask(0, 10)
        pinned.followsWindowID = 42
        let original = pinned.rects
        let resolved = pinned.resolved(windowFrames: [:], recordingSize: canvas)
        XCTAssertEqual(resolved.rects, original)
        XCTAssertTrue(resolved.covers(5), "a mask stopped covering when its window disappeared")
    }

    func testAPinnedMaskFollowsItsWindow() {
        var pinned = mask(0, 10)
        pinned.followsWindowID = 42
        pinned.windowOriginAtCreation = CGPoint(x: 0, y: 0)
        let moved = pinned.resolved(windowFrames: [42: CGRect(x: 50, y: 20, width: 800, height: 600)],
                                    recordingSize: canvas)
        XCTAssertEqual(moved.rects[0].x, 150, accuracy: 0.001)
        XCTAssertEqual(moved.rects[0].y, 120, accuracy: 0.001)
    }

    /// Secure blur is the default because the README already argues the case: an ordinary blur is
    /// a linear convolution and is routinely inverted, which is exactly the password situation.
    func testTheDefaultMaskModeIsTheSafeOne() {
        XCTAssertEqual(StudioMask(rects: [], start: 0, end: 1).mode, .secureBlur)
    }

    func testAMaskSurvivesARoundTrip() throws {
        let original = mask(1, 4, mode: .pixellate)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(StudioMask.self, from: data), original)
    }

    /// A highlight is the inverse — it dims everything outside itself — so it is one mode of the
    /// same object rather than a second kind of thing.
    func testAHighlightIsAMaskMode() {
        XCTAssertTrue(StudioMask.Mode.allCases.contains(.highlight))
    }

    // MARK: - Camera

    private func camera() -> CameraSettings { CameraSettings() }

    func testWithNoSegmentsTheCameraIsAPictureInPicture() throws {
        let state = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: camera(), canvas: canvas, zoom: 1))
        XCTAssertLessThan(state.rect.width, canvas.width / 2)
        XCTAssertEqual(state.opacity, 1, accuracy: 0.001)
    }

    /// **The camera holds still while the frame zooms.** It is drawn in canvas space, so a zoom can
    /// never move it — but `pipRect` also scaled it, and the default `sizeDuringZoom` of `.shrink`
    /// meant it quietly got smaller every time the auto-zoom fired. Watching your own face change
    /// size whenever the picture pushes in reads as a bug, because it is one.
    ///
    /// The setting keeps all three options; only the default changed.
    func testTheCameraDoesNotChangeSizeWhenTheFrameZooms() throws {
        let atRest = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: camera(), canvas: canvas, zoom: 1))
        let zoomed = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: camera(), canvas: canvas, zoom: 2.5))

        XCTAssertEqual(zoomed.rect, atRest.rect,
                       "the camera changed size or position under a zoom")
    }

    /// **The camera fades in when it starts, rather than appearing at full strength.**
    ///
    /// It begins a couple of seconds after the screen, because that is how long a capture session
    /// takes to come up. `CameraSettings.fadeSeconds` existed and was offered in the inspector, and
    /// nothing rendered it — so the bubble arrived in one frame.
    func testTheCameraFadesInFromWhereItStarted() throws {
        var settings = camera()
        settings.fadeSeconds = 0.4

        let arriving = try XCTUnwrap(CameraLayoutResolver.state(
            at: 2.5, segments: [], settings: settings, canvas: canvas, zoom: 1,
            cameraStart: 2.4))
        let settled = try XCTUnwrap(CameraLayoutResolver.state(
            at: 6, segments: [], settings: settings, canvas: canvas, zoom: 1,
            cameraStart: 2.4))

        XCTAssertLessThan(arriving.opacity, 0.5, "the camera appeared at full strength")
        XCTAssertGreaterThan(arriving.opacity, 0, "and it should be on its way in, not absent")
        XCTAssertEqual(settled.opacity, 1, accuracy: 0.001)
    }

    /// With no fade asked for, it simply appears — the setting is honoured either way.
    func testNoFadeMeansItAppearsAtOnce() throws {
        var settings = camera()
        settings.fadeSeconds = 0
        let state = try XCTUnwrap(CameraLayoutResolver.state(
            at: 2.4, segments: [], settings: settings, canvas: canvas, zoom: 1,
            cameraStart: 2.4))
        XCTAssertEqual(state.opacity, 1, accuracy: 0.001)
    }

    func testAHiddenSegmentDrawsNoCamera() {
        let hidden = CameraSegment(start: 0, end: 5, layout: .hidden)
        XCTAssertNil(CameraLayoutResolver.state(at: 2, segments: [hidden],
                                                settings: camera(), canvas: canvas, zoom: 1))
    }

    /// The shape a good demo takes: full-frame for the intro, picture-in-picture for the
    /// walkthrough. A single "camera position" setting cannot express it, which is why this is a
    /// track rather than a checkbox.
    func testAFullFrameSegmentFillsTheCanvas() throws {
        let intro = CameraSegment(start: 0, end: 5, layout: .fullFrame)
        let state = try XCTUnwrap(CameraLayoutResolver.state(
            at: 2.5, segments: [intro], settings: camera(), canvas: canvas, zoom: 1))
        XCTAssertEqual(state.rect.width, canvas.width, accuracy: 1)
    }

    /// A full-frame camera should *become* the small one rather than cutting to it.
    func testTheLayoutChangeIsAnimatedRatherThanCut() throws {
        let intro = CameraSegment(start: 0, end: 5, layout: .fullFrame)
        let mid = try XCTUnwrap(CameraLayoutResolver.state(
            at: 4.9, segments: [intro], settings: camera(), canvas: canvas, zoom: 1))
        XCTAssertLessThan(mid.rect.width, canvas.width)
        XCTAssertGreaterThan(mid.rect.width, canvas.width * 0.3)
    }

    /// **The camera shrinks when the frame zooms in, not the other way round.** A zoom exists to
    /// show something, and the camera covering it defeats the zoom.
    ///
    /// Asked for explicitly, because this is no longer the default — a camera that changes size
    /// whenever the auto-zoom fires reads as a glitch. See
    /// `testTheCameraDoesNotChangeSizeWhenTheFrameZooms`.
    func testTheCameraShrinksWhileTheFrameIsZoomed() throws {
        var shrinking = camera()
        shrinking.sizeDuringZoom = .shrink
        let atRest = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: shrinking, canvas: canvas, zoom: 1))
        let zoomed = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: shrinking, canvas: canvas, zoom: 2.5))
        XCTAssertLessThan(zoomed.rect.width, atRest.rect.width)
    }

    func testTheCameraCanBeToldToHoldItsSize() throws {
        var held = camera()
        held.sizeDuringZoom = .hold
        let atRest = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: held, canvas: canvas, zoom: 1))
        let zoomed = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: held, canvas: canvas, zoom: 2.5))
        XCTAssertEqual(zoomed.rect.width, atRest.rect.width, accuracy: 0.5)
    }

    /// The margin is measured from the canvas edge, not from the padding — otherwise raising the
    /// project's padding appears to move the camera for no reason.
    func testTheCameraKeepsAConstantMarginFromTheEdge() throws {
        let state = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: camera(), canvas: canvas, zoom: 1))
        XCTAssertEqual(state.rect.minX, canvas.width * CGFloat(camera().marginFraction),
                       accuracy: 1)
    }

    /// Computed from the shorter side, so a non-square camera does not end up with lozenge ends.
    func testTheCornerRadiusComesFromTheShorterSide() throws {
        var wide = camera()
        wide.aspect = 2
        let state = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: wide, canvas: canvas, zoom: 1))
        XCTAssertLessThanOrEqual(state.cornerRadius, min(state.rect.width, state.rect.height) / 2)
    }

    func testACircleIsFullyRounded() throws {
        var round = camera()
        round.shape = .circle
        let state = try XCTUnwrap(CameraLayoutResolver.state(
            at: 1, segments: [], settings: round, canvas: canvas, zoom: 1))
        XCTAssertEqual(state.cornerRadius, min(state.rect.width, state.rect.height) / 2,
                       accuracy: 0.5)
    }

    // MARK: - Keystrokes

    private func key(_ t: TimeInterval, _ label: String, combination: Bool = true) -> KeyEvent {
        KeyEvent(t: t, label: label, isModifierCombination: combination)
    }

    func testNothingIsShownBeforeAnyKey() {
        XCTAssertTrue(KeystrokeOverlay.pills(at: 0, keys: [key(5, "⌘C")],
                                             settings: KeystrokeSettings()).isEmpty)
    }

    func testAKeyIsShownWhenItIsPressed() {
        let pills = KeystrokeOverlay.pills(at: 5.1, keys: [key(5, "⌘C")],
                                           settings: KeystrokeSettings())
        XCTAssertEqual(pills.first?.label, "⌘C")
    }

    func testAKeyFadesAwayAfterwards() {
        let settings = KeystrokeSettings()
        let pills = KeystrokeOverlay.pills(at: 5 + settings.holdSeconds + 0.5,
                                           keys: [key(5, "⌘C")], settings: settings)
        XCTAssertTrue(pills.isEmpty)
    }

    /// Otherwise holding a key stacks a tower of identical pills, which is noise rather than
    /// information.
    func testARepeatedKeyCollapsesIntoACount() {
        let repeated = (0..<5).map { key(5 + Double($0) * 0.1, "⌘V") }
        let pills = KeystrokeOverlay.pills(at: 5.5, keys: repeated, settings: KeystrokeSettings())
        XCTAssertEqual(pills.count, 1)
        XCTAssertEqual(pills.first?.repeatCount, 5)
    }

    /// The default shows combinations only — ⌘C, ⌃⇧R — because that is what a demo needs, and
    /// showing every letter somebody types is a much larger promise about what is being recorded.
    func testByDefaultOnlyCombinationsAreShown() {
        let mixed = [key(5, "⌘C"), key(5.1, "A", combination: false)]
        let pills = KeystrokeOverlay.pills(at: 5.2, keys: mixed, settings: KeystrokeSettings())
        XCTAssertEqual(pills.map(\.label), ["⌘C"])
    }

    func testBareKeysCanBeShownWhenAsked() {
        var settings = KeystrokeSettings()
        settings.showsBareKeys = true
        let mixed = [key(5, "⌘C"), key(5.1, "A", combination: false)]
        XCTAssertEqual(KeystrokeOverlay.pills(at: 5.2, keys: mixed, settings: settings).count, 2)
    }

    func testTheMostRecentKeyComesLast() {
        let keys = [key(5, "⌘C"), key(5.4, "⌘V")]
        let pills = KeystrokeOverlay.pills(at: 5.5, keys: keys, settings: KeystrokeSettings())
        XCTAssertEqual(pills.last?.label, "⌘V")
    }

    /// A wall of pills is worse than the last few.
    func testOnlyTheLastFewAreKept() {
        let many = (0..<12).map { key(5 + Double($0) * 0.05, "⌘\($0)") }
        let pills = KeystrokeOverlay.pills(at: 5.6, keys: many, settings: KeystrokeSettings())
        XCTAssertLessThanOrEqual(pills.count, KeystrokeSettings().maximumPills)
    }
}
