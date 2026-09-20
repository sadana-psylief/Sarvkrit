import XCTest
@testable import Sarvkrit

/// What happens to the file when a capture is deleted.
///
/// **These are the user's screenshots, and there was no way back to one.** `remove`, `clear` and
/// the retention sweep all went through `FileManager.removeItem`, which erases — so a capture that
/// aged out, or one lost to a mis-click on "Delete All Captures", was gone with no undo and
/// nothing in the Trash. The recordings list already treats its bundles the other way for exactly
/// this reason.
final class CaptureDeletionTests: XCTestCase {

    /// Records what was asked of it instead of touching the real Trash, which a test has no
    /// business filling.
    private final class RecordingFileManager: FileManager {
        var trashed: [URL] = []
        var removed: [URL] = []
        /// Makes trashing fail, as it does on a volume that has no Trash.
        var refusesToTrash = false

        override func trashItem(at url: URL,
                                resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?)
            throws {
            if refusesToTrash {
                throw CocoaError(.fileWriteUnknown)
            }
            trashed.append(url)
            try? super.removeItem(at: url)
        }

        override func removeItem(at url: URL) throws {
            removed.append(url)
            try? super.removeItem(at: url)
        }
    }

    private var root: URL!
    private var fileManager: RecordingFileManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-deletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileManager = RecordingFileManager()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func store(retention: CaptureRetention.Window = .forever,
                       now: Date = Date()) -> CaptureHistoryStore {
        CaptureHistoryStore(directory: root, fileManager: fileManager,
                            retention: retention, now: now)
    }

    @discardableResult
    private func add(to store: CaptureHistoryStore) throws -> CaptureHistoryItem {
        let image = try StubScreenCaptureService.image(size: CGSize(width: 20, height: 16))
        return try XCTUnwrap(store.add(image: image, mode: .area))
    }

    /// Ages the newest entry on disk and reloads, which is the only way to reach the sweep — it
    /// runs on load, the same path `CaptureHistoryStoreTests` uses.
    private func ageNewestEntry(by seconds: TimeInterval) throws {
        let indexURL = root.appendingPathComponent("captures.json")
        var items = try JSONDecoder().decode([CaptureHistoryItem].self,
                                             from: Data(contentsOf: indexURL))
        items[0].createdAt = Date(timeIntervalSinceNow: -seconds)
        try JSONEncoder().encode(items).write(to: indexURL)
    }

    // MARK: - One capture

    func testDeletingOneCaptureSendsItToTheTrash() throws {
        let store = store()
        let item = try add(to: store)

        store.remove(id: item.id)

        XCTAssertEqual(fileManager.trashed.map(\.lastPathComponent),
                       [store.url(for: item).lastPathComponent])
        XCTAssertTrue(fileManager.removed.isEmpty, "it was erased rather than trashed")
    }

    /// **A delete that cannot trash must still delete.** Some volumes have no Trash, and a button
    /// that silently does nothing is worse than one that is blunt.
    func testADeleteFallsBackToErasingWhenTrashingIsRefused() throws {
        fileManager.refusesToTrash = true
        let store = store()
        let item = try add(to: store)

        store.remove(id: item.id)

        XCTAssertEqual(fileManager.removed.map(\.lastPathComponent),
                       [store.url(for: item).lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: item).path))
    }

    /// Whatever happened to the file, the entry goes — a history row pointing at nothing is worse
    /// than no row.
    func testTheEntryIsForgottenEvenIfTheFileWillNotBudge() throws {
        fileManager.refusesToTrash = true
        let store = store()
        let item = try add(to: store)
        store.remove(id: item.id)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - All of them

    func testClearingEverythingSendsItAllToTheTrash() throws {
        let store = store()
        let first = try add(to: store)
        let second = try add(to: store)

        store.clear()

        XCTAssertEqual(Set(fileManager.trashed.map(\.lastPathComponent)),
                       Set([first, second].map { store.url(for: $0).lastPathComponent }))
        XCTAssertTrue(fileManager.removed.isEmpty)
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - The sweep nobody asked for

    /// **The one that matters most.** Retention runs on load, without anybody pressing anything —
    /// so a capture from five weeks ago disappears while you are doing something else. Recoverable
    /// is the only defensible way to do that.
    func testTheRetentionSweepTrashesRatherThanErases() throws {
        let keeper = store(retention: .forever)
        let stale = try add(to: keeper)
        keeper.flush()
        try ageNewestEntry(by: 40 * 24 * 60 * 60)

        // Reopened with a month's retention, which is the default: the sweep runs on load.
        fileManager.trashed = []
        fileManager.removed = []
        let reopened = store(retention: .month)

        XCTAssertEqual(fileManager.trashed.map(\.lastPathComponent),
                       [reopened.url(for: stale).lastPathComponent])
        XCTAssertTrue(fileManager.removed.isEmpty, "an expired capture was erased, not trashed")
        XCTAssertTrue(reopened.items.isEmpty)
    }
    // MARK: - An edited capture stays editable

    /// **Annotate a capture, close it, reopen it from history — and the annotations had become
    /// permanent pixels.** `commitEdit` wrote back only the flattened image through
    /// `replaceImage`, so the history entry was a flat PNG: reopening found no base bitmap and no
    /// document, and handed the editor a single-layer image with the arrow baked into it. Nothing
    /// said so; the arrow was simply no longer a thing you could select or delete.
    ///
    /// The fix costs roughly double the file size, and `CaptureDocumentFile` already argues that
    /// is the right trade "only where it buys something" — an edited capture is exactly that case.
    /// An un-edited one stays flat.
    func testAnEditedCaptureIsStoredSoItCanBeEditedAgain() throws {
        let store = store()
        let item = try add(to: store)
        let base = try StubScreenCaptureService.image(size: CGSize(width: 20, height: 16))
        let flattened = try StubScreenCaptureService.image(size: CGSize(width: 20, height: 16))

        var document = AnnotationDocument(imageSize: CGSize(width: 20, height: 16))
        document.add(.rectangle(ShapeElement(rect: CGRect(x: 1, y: 1, width: 5, height: 5))))

        XCTAssertTrue(store.replaceImage(of: item.id, with: flattened,
                                         document: document, base: base))

        let data = try Data(contentsOf: store.url(for: item))
        let read = try CaptureDocumentFile.decode(data)
        XCTAssertNotNil(read.base, "the original pixels were not kept, so the edit is permanent")
        XCTAssertEqual(read.document?.elements.count, 1,
                       "the annotations came back as pixels rather than as elements")
    }

    /// A plain capture is still flat: the doubled size is paid only by the captures that gain
    /// something from it.
    func testAnUnEditedCaptureStaysFlat() throws {
        let store = store()
        let item = try add(to: store)
        let data = try Data(contentsOf: store.url(for: item))
        XCTAssertNil(try CaptureDocumentFile.decode(data).base)
    }
}
