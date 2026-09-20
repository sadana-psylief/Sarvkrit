import XCTest
@testable import Sarvkrit

/// The dead seconds at the head of a take.
///
/// A capture session needs two to three seconds to come up, so a recording with a camera or a
/// microphone begins with no camera and no narration. Holding the camera's first frame was one
/// wrong answer — it showed a frozen face — and leaving a hole is another. **The take starts when
/// everything is running**, and the material is trimmed rather than cut, so it is one context-menu
/// item away from coming back.
final class StudioLeadInTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lead-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func bundle(offset: TimeInterval, duration: TimeInterval = 30) throws
        -> (RecordingBundle, RecordingManifest) {
        let bundle = try RecordingBundle.create(
            at: directory.appendingPathComponent("r-\(UUID().uuidString).sarvrec"))
        var manifest = RecordingManifest(source: .display,
                                         pixelSize: CGSize(width: 200, height: 120),
                                         pointPixelScale: 1, fps: 60)
        manifest.state = .complete
        manifest.duration = duration
        manifest.hasCamera = offset > 0
        manifest.cameraStartOffset = offset
        try bundle.write(manifest)
        try bundle.writeEvents(EventLog())
        return (bundle, manifest)
    }

    @MainActor
    func testANewProjectStartsWhereTheCaptureBecameReady() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart ?? -1, 3.2, accuracy: 0.001)
        XCTAssertEqual(model.project.timeline.clips.first?.sourceEnd ?? -1, 30, accuracy: 0.001)
    }

    /// A screen-only take has nothing to wait for, so nothing is hidden from it.
    @MainActor
    func testAScreenOnlyTakeStartsAtZero() throws {
        let (bundle, manifest) = try bundle(offset: 0)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart, 0)
    }

    /// **Only on first creation.** Re-trimming on every open would eat three more seconds each
    /// time the editor was reopened — the thing item 1 exists to make possible.
    @MainActor
    func testReopeningDoesNotTrimAgain() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let first = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        first.markSaved()

        let second = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(second.project.timeline.clips.first?.sourceStart ?? -1, 3.2, accuracy: 0.001)
    }

    /// Somebody who deliberately un-trims and closes must not find it trimmed again next time.
    @MainActor
    func testADeliberateUntrimSurvivesAReopen() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let first = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        let clipID = try XCTUnwrap(first.project.timeline.clips.first?.id)
        first.untrimClip(clipID)
        first.markSaved()

        let second = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(second.project.timeline.clips.first?.sourceStart, 0)
    }

    /// The trim is a window, never a cut: putting it back reaches the real first frame.
    @MainActor
    func testTheHiddenMaterialCanBePutBack() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        let clipID = try XCTUnwrap(model.project.timeline.clips.first?.id)
        model.untrimClip(clipID)
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart, 0)
    }

    /// An offset longer than the recording would leave an empty timeline — nothing to play, no way
    /// back except a menu item on a clip that has no width to right-click.
    @MainActor
    func testAnAbsurdOffsetIsIgnored() throws {
        let (bundle, manifest) = try bundle(offset: 9, duration: 9.4)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart, 0)
    }

    // MARK: - Saying so

    /// The notice is the whole point of trimming rather than silently starting late: it is on
    /// screen, it says how much, and it undoes itself in one click.
    @MainActor
    func testTheNoticeOffersThePutBack() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(model.leadInNotice ?? -1, 3.2, accuracy: 0.001)

        model.putBackLeadIn()
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart, 0)
        XCTAssertNil(model.leadInNotice, "the notice outlived the thing it was about")
    }

    /// The banner is about the head of the take and nothing else.
    ///
    /// `untrimClip` restores *both* ends, so delegating to it would undo a tail trim the user made
    /// deliberately — losing the end of their edit to a button that promised to fix the start.
    @MainActor
    func testPuttingBackTheLeadInLeavesTheTailAlone() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        model.edit { $0.timeline.clips[0].sourceEnd = 18 }

        model.putBackLeadIn()
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart, 0)
        XCTAssertEqual(model.project.timeline.clips.first?.sourceEnd, 18,
                       "the banner threw away the tail the user had trimmed")
    }

    /// Dismissing it is not the same as undoing it — somebody who agrees with the trim wants the
    /// banner gone and the trim kept.
    @MainActor
    func testDismissingTheNoticeKeepsTheTrim() throws {
        let (bundle, manifest) = try bundle(offset: 3.2)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        model.dismissLeadInNotice()
        XCTAssertNil(model.leadInNotice)
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart ?? -1, 3.2, accuracy: 0.001)
    }

    /// A tenth of a second is not worth mentioning to anybody, and the timeline's own badge
    /// threshold ignores anything under 0.15 s anyway.
    @MainActor
    func testATinyOffsetIsNotWorthTrimming() throws {
        let (bundle, manifest) = try bundle(offset: 0.1)
        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertEqual(model.project.timeline.clips.first?.sourceStart, 0)
    }

    /// The editor has to be able to say what it did, or the trim is another silent decision.
    @MainActor
    func testTheModelReportsWhatItHid() throws {
        let (trimmed, trimmedManifest) = try bundle(offset: 3.2)
        let model = StudioDocumentModel(bundle: trimmed, manifest: trimmedManifest,
                                        events: EventLog())
        XCTAssertEqual(model.trimmedLeadIn ?? -1, 3.2, accuracy: 0.001)
    }

    @MainActor
    func testAScreenOnlyTakeHasNothingToReport() throws {
        let (plain, plainManifest) = try bundle(offset: 0)
        let model = StudioDocumentModel(bundle: plain, manifest: plainManifest, events: EventLog())
        XCTAssertNil(model.trimmedLeadIn)
    }
}
