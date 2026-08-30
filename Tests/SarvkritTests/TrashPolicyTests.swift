import XCTest
@testable import Sarvkrit

/// This is the one feature that deletes irrecoverably, so the arithmetic deciding what goes is
/// tested exhaustively and in isolation from the filesystem.
final class TrashPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, daysAgo: Double, size: Int64 = 1_048_576) -> TrashPolicy.Item {
        TrashPolicy.Item(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            dateTrashed: now.addingTimeInterval(-daysAgo * 86_400),
            size: size
        )
    }

    // MARK: - Age

    func testOnlyItemsOlderThanTheLimitAreRemoved() {
        let items = [item("old", daysAgo: 40), item("fresh", daysAgo: 2)]
        let doomed = TrashPolicy.itemsToRemove(
            from: items, settings: .init(deleteAfterDays: 30, sizeCapBytes: nil), now: now)

        XCTAssertEqual(doomed.map { $0.url.lastPathComponent }, ["old"])
    }

    func testAnItemExactlyAtTheLimitIsKept() {
        // Boundary in the safe direction: "after 30 days" should not fire on day 30.
        let doomed = TrashPolicy.itemsToRemove(
            from: [item("borderline", daysAgo: 30)],
            settings: .init(deleteAfterDays: 30, sizeCapBytes: nil),
            now: now)
        XCTAssertTrue(doomed.isEmpty)
    }

    func testZeroOrNilDaysDisablesAgeBasedRemoval() {
        let items = [item("ancient", daysAgo: 9_999)]
        XCTAssertTrue(TrashPolicy.itemsToRemove(
            from: items, settings: .init(deleteAfterDays: nil, sizeCapBytes: nil), now: now).isEmpty)
        XCTAssertTrue(TrashPolicy.itemsToRemove(
            from: items, settings: .init(deleteAfterDays: 0, sizeCapBytes: nil), now: now).isEmpty)
    }

    func testNoSettingsMeansNothingIsEverRemoved() {
        // The default state. A cleanup feature that deletes before being configured would be
        // indefensible.
        let items = [item("a", daysAgo: 500), item("b", daysAgo: 900)]
        XCTAssertTrue(TrashPolicy.itemsToRemove(from: items, settings: .init(), now: now).isEmpty)
    }

    // MARK: - Size cap

    func testSizeCapRemovesOldestFirst() {
        // If the trash must shrink, the thing least likely to be wanted back is the oldest.
        let items = [
            item("newest", daysAgo: 1, size: 4_194_304),
            item("middle", daysAgo: 5, size: 4_194_304),
            item("oldest", daysAgo: 9, size: 4_194_304),
        ]
        let doomed = TrashPolicy.itemsToRemove(
            from: items, settings: .init(deleteAfterDays: nil, sizeCapBytes: 8_388_608), now: now)

        XCTAssertEqual(doomed.map { $0.url.lastPathComponent }, ["oldest"])
    }

    func testSizeCapRemovesAsManyAsNeeded() {
        let items = (1...5).map { item("f\($0)", daysAgo: Double(10 - $0), size: 2_097_152) }
        let doomed = TrashPolicy.itemsToRemove(
            from: items, settings: .init(deleteAfterDays: nil, sizeCapBytes: 4_194_304), now: now)

        XCTAssertEqual(doomed.count, 3, "10MB down to a 4MB cap needs three 2MB items gone")
    }

    func testUnderTheCapNothingIsRemoved() {
        let items = [item("small", daysAgo: 1, size: 1_024)]
        XCTAssertTrue(TrashPolicy.itemsToRemove(
            from: items, settings: .init(deleteAfterDays: nil, sizeCapBytes: 1_048_576), now: now).isEmpty)
    }

    // MARK: - Both together

    func testAgeAndCapDoNotDoubleCountAnItem() {
        // An item removed for age must not be counted again by the cap, or the cap over-deletes.
        let items = [
            item("old-and-big", daysAgo: 90, size: 8_388_608),
            item("new-and-big", daysAgo: 1, size: 4_194_304),
        ]
        let doomed = TrashPolicy.itemsToRemove(
            from: items,
            settings: .init(deleteAfterDays: 30, sizeCapBytes: 8_388_608),
            now: now)

        XCTAssertEqual(doomed.map { $0.url.lastPathComponent }, ["old-and-big"])
        XCTAssertEqual(Set(doomed.map(\.url)).count, doomed.count, "an item was listed twice")
    }

    func testEmptyTrashIsHandled() {
        XCTAssertTrue(TrashPolicy.itemsToRemove(
            from: [], settings: .init(deleteAfterDays: 1, sizeCapBytes: 1), now: now).isEmpty)
    }

    // MARK: - Feature defaults

    func testShipsWithConservativeDefaultsAndNoSizeCap() {
        let defaults = UserDefaults(suiteName: "trash.\(UUID())")!
        let feature = TrashCleanupFeature(defaults: defaults)

        XCTAssertEqual(feature.deleteAfterDays, 30)
        XCTAssertEqual(feature.sizeCapMB, 0, "a size cap must be opted into, never defaulted on")
        XCTAssertNil(feature.settings.sizeCapBytes)
        XCTAssertEqual(feature.category, .files)
        XCTAssertFalse(feature.requiresAccessibility)
    }

    func testUnreadableTrashReportsDeniedRatherThanEmpty() {
        // No API exists to query Full Disk Access; the only honest signal is a failed read. It must
        // not be mistaken for "the trash is empty", which would silently do nothing forever.
        let defaults = UserDefaults(suiteName: "trash.\(UUID())")!
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let feature = TrashCleanupFeature(defaults: defaults, trashURL: missing)

        XCTAssertNil(feature.currentItems())
        _ = feature.run()
        XCTAssertEqual(feature.access, .denied)
    }

    func testRunAgainstARealDirectoryRemovesOnlyExpiredItems() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }

        let keep = fake.appendingPathComponent("keep.txt")
        try "x".write(to: keep, atomically: true, encoding: .utf8)

        let defaults = UserDefaults(suiteName: "trash.\(UUID())")!
        let feature = TrashCleanupFeature(defaults: defaults, trashURL: fake)
        feature.deleteAfterDays = 30

        _ = feature.run(now: Date())

        XCTAssertEqual(feature.access, .granted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path),
                      "a just-added item must survive a 30-day policy")
    }

    func testDryRunRemovesNothing() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }

        let file = fake.appendingPathComponent("old.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let defaults = UserDefaults(suiteName: "trash.\(UUID())")!
        let feature = TrashCleanupFeature(defaults: defaults, trashURL: fake)
        feature.deleteAfterDays = 1

        // Far-future "now" makes today's file look ancient without waiting a day.
        let doomed = feature.run(now: Date().addingTimeInterval(86_400 * 30), dryRun: true)

        XCTAssertEqual(doomed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "dry run deleted a file")
    }
}
