import XCTest
@testable import Sarvkrit

/// What the user chose before pressing Record.
///
/// Pure, and persisted, because **the single most costly failure this feature has is discovering
/// after a ten-minute take that the camera was off or pointed at the ceiling.** Remembering the
/// last choice is most of the defence; the live preview in the bar is the rest.
final class RecordingSetupTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ai.psylief.sarvkrit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAFreshSetupRecordsTheWholeDisplay() {
        XCTAssertEqual(RecordingSetup(defaults: defaults).source, .display)
    }

    /// Nothing is switched on for you. A recorder that turns the camera on by default is a
    /// recorder that has filmed somebody without them deciding to be filmed.
    func testNothingIsOnByDefault() {
        let setup = RecordingSetup(defaults: defaults)
        XCTAssertNil(setup.cameraID)
        XCTAssertNil(setup.microphoneID)
        XCTAssertFalse(setup.capturesSystemAudio)
    }

    func testTheChoicesSurviveARelaunch() {
        let first = RecordingSetup(defaults: defaults)
        first.source = .area
        first.cameraID = "camera-1"
        first.microphoneID = "mic-1"
        first.capturesSystemAudio = true
        first.countdownSeconds = 5

        let second = RecordingSetup(defaults: defaults)
        XCTAssertEqual(second.source, .area)
        XCTAssertEqual(second.cameraID, "camera-1")
        XCTAssertEqual(second.microphoneID, "mic-1")
        XCTAssertTrue(second.capturesSystemAudio)
        XCTAssertEqual(second.countdownSeconds, 5)
    }

    /// A device that has been unplugged since last time must not silently stay selected, or the
    /// bar shows a camera that is not there and Record produces nothing.
    func testADeviceThatHasGoneIsForgotten() {
        let setup = RecordingSetup(defaults: defaults)
        setup.cameraID = "unplugged"
        setup.reconcile(cameraIDs: ["still-here"], microphoneIDs: [])
        XCTAssertNil(setup.cameraID)
    }

    func testADeviceStillPresentIsKept() {
        let setup = RecordingSetup(defaults: defaults)
        setup.cameraID = "still-here"
        setup.reconcile(cameraIDs: ["still-here"], microphoneIDs: [])
        XCTAssertEqual(setup.cameraID, "still-here")
    }

    func testTheMicrophoneIsReconciledToo() {
        let setup = RecordingSetup(defaults: defaults)
        setup.microphoneID = "gone"
        setup.reconcile(cameraIDs: [], microphoneIDs: ["present"])
        XCTAssertNil(setup.microphoneID)
    }

    /// Only these three, and only these: the countdown exists to let you get to the window you are
    /// about to demonstrate, and a menu of eleven durations is a decision nobody wants to make.
    func testTheCountdownOffersAShortList() {
        XCTAssertEqual(RecordingSetup.countdownChoices, [0, 3, 5, 10])
    }

    func testAnUnknownCountdownFallsBackToNone() {
        defaults.set(97, forKey: "recording.countdown")
        XCTAssertEqual(RecordingSetup(defaults: defaults).countdownSeconds, 0)
    }

    // MARK: - The area to record

    func testAFreshSetupRemembersNoArea() {
        XCTAssertNil(RecordingSetup(defaults: defaults).lastArea)
    }

    /// The whole point of item 3: the second area recording opens with the first one's rectangle
    /// already on screen, so it can be nudged rather than redrawn.
    func testTheAreaSurvivesARelaunch() {
        let first = RecordingSetup(defaults: defaults)
        first.lastArea = CGRect(x: 100, y: 200, width: 640, height: 480)

        XCTAssertEqual(RecordingSetup(defaults: defaults).lastArea,
                       CGRect(x: 100, y: 200, width: 640, height: 480))
    }

    /// An empty rect would seed the overlay with a selection that has no handles to grab, which is
    /// worse than seeding nothing.
    func testAnEmptyAreaIsNotRemembered() {
        let setup = RecordingSetup(defaults: defaults)
        setup.lastArea = CGRect(x: 10, y: 10, width: 0, height: 100)
        XCTAssertNil(setup.lastArea)
    }

    func testTheAreaCanBeForgotten() {
        let setup = RecordingSetup(defaults: defaults)
        setup.lastArea = CGRect(x: 1, y: 2, width: 3, height: 4)
        setup.lastArea = nil
        XCTAssertNil(setup.lastArea)
    }

    /// Stored as four numbers rather than an archived rect, for the reason the screenshot path
    /// gives: a change to how rects are persisted must not make an old value decode as something
    /// plausible but wrong, because the failure there is recording the wrong part of the screen.
    func testAHalfWrittenAreaIsIgnored() {
        defaults.set([10.0, 20.0], forKey: "recording.lastArea")
        XCTAssertNil(RecordingSetup(defaults: defaults).lastArea)
    }

    // MARK: - Turning a choice into a request

    func testTheRequestCarriesTheChosenSource() {
        let setup = RecordingSetup(defaults: defaults)
        setup.source = .window
        let request = setup.request(fps: 60, hidesDesktopIcons: true,
                                    destination: URL(fileURLWithPath: "/tmp/x.sarvrec"))
        XCTAssertEqual(request.source, .window)
    }

    func testTheRequestCarriesTheAudioChoice() {
        let setup = RecordingSetup(defaults: defaults)
        setup.capturesSystemAudio = true
        let request = setup.request(fps: 30, hidesDesktopIcons: false,
                                    destination: URL(fileURLWithPath: "/tmp/x.sarvrec"))
        XCTAssertTrue(request.capturesSystemAudio)
        XCTAssertEqual(request.fps, 30)
        XCTAssertFalse(request.hidesDesktopIcons)
    }

    /// A source aimed by dragging needs the frozen overlay; the other two are pointed at something
    /// that already has edges.
    func testOnlyAnAreaNeedsTheSelectionOverlay() {
        XCTAssertTrue(RecordingSource.area.aimsByDragging)
        XCTAssertFalse(RecordingSource.display.aimsByDragging)
        XCTAssertFalse(RecordingSource.window.aimsByDragging)
    }
}
