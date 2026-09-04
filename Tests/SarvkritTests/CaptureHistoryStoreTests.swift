import XCTest
@testable import Sarvkrit

/// Runs against a real temporary directory and asserts the filesystem afterwards, the way
/// `ShelfStoreTests` and `ActionRunnerTests` do — the point of a store is its effect on disk.
final class CaptureHistoryStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-captures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeStore(retention: CaptureRetention.Window = .month) -> CaptureHistoryStore {
        CaptureHistoryStore(directory: root, retention: retention)
    }

    private func image(_ width: Int = 40, _ height: Int = 30) throws -> CGImage {
        try StubScreenCaptureService.image(size: CGSize(width: width, height: height))
    }

    func testAddingWritesAPNGAndRecordsIt() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.add(image: try image(64, 48), mode: .area))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(item.pixelWidth, 64)
        XCTAssertEqual(item.pixelHeight, 48)
        XCTAssertGreaterThan(item.byteCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url(for: item).path))
    }

    func testTheNewestCaptureIsFirst() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.add(image: try image(), mode: .area))
        let second = try XCTUnwrap(store.add(image: try image(), mode: .window))
        XCTAssertEqual(store.items.map(\.id), [second.id, first.id])
    }

    func testRemovingDeletesTheFile() throws {
        // The line this store draws opposite to the Shelf: every byte here is ours, so removing
        // an item really does delete.
        let store = makeStore()
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area))
        let path = store.url(for: item).path

        store.remove(id: item.id)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testClearRemovesEveryFile() throws {
        let store = makeStore()
        let paths = try (0..<3).map { _ -> String in
            store.url(for: try XCTUnwrap(store.add(image: try image(), mode: .area))).path
        }
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testTheIndexSurvivesAReload() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.add(image: try image(20, 10), mode: .fullscreen))
        store.flush()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.items.map(\.id), [item.id])
        XCTAssertEqual(reloaded.items.first?.mode, .fullscreen)
        XCTAssertEqual(reloaded.items.first?.pixelWidth, 20)
    }

    func testReplacingKeepsTheIdentityAndUpdatesTheSize() throws {
        // How the editor hands work back. Keeping the id and position matters: the overlay and the
        // history row are both pointing at it while the edit happens.
        let store = makeStore()
        let item = try XCTUnwrap(store.add(image: try image(40, 30), mode: .area))

        XCTAssertTrue(store.replaceImage(of: item.id, with: try image(80, 60)))

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items[0].id, item.id)
        XCTAssertEqual(store.items[0].pixelWidth, 80)
        XCTAssertEqual(store.items[0].fileName, item.fileName, "the file must be rewritten in place")
    }

    func testAnUnreadableIndexLeavesThePayloadsAlone() throws {
        // Logged and left, not overwritten: an index we can't parse might be recoverable by hand,
        // and the PNGs beside it certainly are.
        let store = makeStore()
        let item = try XCTUnwrap(store.add(image: try image(), mode: .area))
        store.flush()
        let payload = store.url(for: item).path

        try Data("not json".utf8).write(to: root.appendingPathComponent("captures.json"))
        let reloaded = makeStore()

        XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload),
                      "a corrupt index must not take the captures with it")
    }

    func testExpiredCapturesArePrunedOnLoad() throws {
        let store = makeStore()
        _ = store.add(image: try image(), mode: .area)
        store.flush()

        // Rewrite the index with an ancient date, then reload through the pruning path.
        let indexURL = root.appendingPathComponent("captures.json")
        var items = try JSONDecoder().decode([CaptureHistoryItem].self,
                                             from: Data(contentsOf: indexURL))
        items[0].createdAt = Date(timeIntervalSinceNow: -60 * 24 * 60 * 60)
        let stalePath = store.url(for: items[0]).path
        try JSONEncoder().encode(items).write(to: indexURL)

        let reloaded = CaptureHistoryStore(directory: root, retention: .month)
        XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath))
    }

    func testForeverRetentionPrunesNothing() throws {
        let store = CaptureHistoryStore(directory: root, retention: .forever)
        _ = store.add(image: try image(), mode: .area)
        store.flush()

        let indexURL = root.appendingPathComponent("captures.json")
        var items = try JSONDecoder().decode([CaptureHistoryItem].self,
                                             from: Data(contentsOf: indexURL))
        items[0].createdAt = Date(timeIntervalSinceNow: -3650 * 24 * 60 * 60)
        try JSONEncoder().encode(items).write(to: indexURL)

        let reloaded = CaptureHistoryStore(directory: root, retention: .forever)
        XCTAssertEqual(reloaded.items.count, 1)
    }

    func testTighteningRetentionPrunesImmediately() throws {
        let store = CaptureHistoryStore(directory: root, retention: .forever)
        _ = store.add(image: try image(), mode: .area)
        store.flush()

        let indexURL = root.appendingPathComponent("captures.json")
        var items = try JSONDecoder().decode([CaptureHistoryItem].self,
                                             from: Data(contentsOf: indexURL))
        items[0].createdAt = Date(timeIntervalSinceNow: -14 * 24 * 60 * 60)
        try JSONEncoder().encode(items).write(to: indexURL)

        let reloaded = CaptureHistoryStore(directory: root, retention: .forever)
        XCTAssertEqual(reloaded.items.count, 1)
        reloaded.retention = .week
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    func testDimensionTextUsesAMultiplicationSign() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.add(image: try image(1920, 1080), mode: .fullscreen))
        XCTAssertEqual(item.dimensionText, "1920 × 1080")
    }
}
