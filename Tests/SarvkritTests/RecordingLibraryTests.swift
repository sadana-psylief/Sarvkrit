import XCTest
@testable import Sarvkrit

/// Finding the recordings that are already on disk.
///
/// **A recording was saved correctly and then unreachable.** `project.json` is written on every
/// edit and flushed again as the window closes, so nothing was ever lost — but the only caller of
/// `StudioEditorController.open` was `stopRecording`, so the only way back into a take was to not
/// have closed it. This is the list that fixes that, and it needs no index: the bundles all live in
/// one directory and each carries its own manifest.
final class RecordingLibraryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    @discardableResult
    private func make(_ name: String, duration: TimeInterval = 12,
                      hasCamera: Bool = false,
                      state: RecordingManifest.State = .complete) throws -> URL {
        let url = directory.appendingPathComponent("\(name).sarvrec")
        let bundle = try RecordingBundle.create(at: url)
        var manifest = RecordingManifest(source: .display,
                                         pixelSize: CGSize(width: 200, height: 120),
                                         pointPixelScale: 1, fps: 60)
        manifest.state = state
        manifest.duration = duration
        manifest.hasCamera = hasCamera
        try bundle.write(manifest)
        return url
    }

    func testAnEmptyDirectoryHasNoRecordings() {
        XCTAssertTrue(RecordingLibrary.entries(in: directory).isEmpty)
    }

    /// A directory that has never held a recording is not an error — it is a new install.
    func testAMissingDirectoryHasNoRecordings() {
        XCTAssertTrue(RecordingLibrary.entries(
            in: directory.appendingPathComponent("never-existed")).isEmpty)
    }

    func testARecordingIsFound() throws {
        try make("one", duration: 42, hasCamera: true)
        let entries = RecordingLibrary.entries(in: directory)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "one")
        XCTAssertEqual(entries.first?.duration ?? -1, 42, accuracy: 0.001)
        XCTAssertEqual(entries.first?.hasCamera, true)
        XCTAssertFalse(entries.first?.needsRecovery ?? true)
    }

    /// Newest first, because the recording somebody wants back is almost always the last one.
    func testTheNewestComesFirst() throws {
        let older = try make("older")
        Thread.sleep(forTimeInterval: 0.05)
        let newer = try make("newer")

        // Set explicitly rather than trusted to the filesystem's own clock, whose resolution is
        // not guaranteed to separate two writes this close together.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newer.path)

        XCTAssertEqual(RecordingLibrary.entries(in: directory).map { $0.name }, ["newer", "older"])
    }

    /// Screenshots and stray files share no directory with these, but a `.DS_Store` does.
    func testOnlyRecordingsAreListed() throws {
        try make("real")
        try Data().write(to: directory.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("notes"), withIntermediateDirectories: true)

        XCTAssertEqual(RecordingLibrary.entries(in: directory).map { $0.name }, ["real"])
    }

    /// **A bundle the app died inside is offered back rather than ignored.** `needsRecovery`
    /// existed, was written faithfully, and was read by nothing but its own tests — so a crashed
    /// take was indistinguishable from no take at all.
    func testABundleLeftMidRecordingIsFlagged() throws {
        try make("interrupted", state: .recording)
        let entry = try XCTUnwrap(RecordingLibrary.entries(in: directory).first)
        XCTAssertTrue(entry.needsRecovery)
    }

    /// Listed rather than hidden. There is nothing to open, but there is something taking up disk
    /// space, and hiding it leaves no way to be rid of it except the Finder.
    func testABundleWithNoManifestIsStillListed() throws {
        try RecordingBundle.create(at: directory.appendingPathComponent("broken.sarvrec"))
        let entry = try XCTUnwrap(RecordingLibrary.entries(in: directory).first)
        XCTAssertEqual(entry.name, "broken")
        XCTAssertNil(entry.duration)
        XCTAssertFalse(entry.canOpen)
    }

    func testAGoodRecordingCanBeOpened() throws {
        try make("fine")
        XCTAssertTrue(try XCTUnwrap(RecordingLibrary.entries(in: directory).first).canOpen)
    }

    // MARK: - Saying how long it is

    func testALengthIsSaidInMinutesAndSeconds() {
        XCTAssertEqual(RecordingLibrary.Entry.lengthDescription(for: 9), "0:09")
        XCTAssertEqual(RecordingLibrary.Entry.lengthDescription(for: 75), "1:15")
        XCTAssertEqual(RecordingLibrary.Entry.lengthDescription(for: 3_601), "1:00:01")
        XCTAssertEqual(RecordingLibrary.Entry.lengthDescription(for: nil), "—")
    }
}
