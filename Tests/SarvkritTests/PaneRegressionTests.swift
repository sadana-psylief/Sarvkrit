import Combine
import XCTest
@testable import Sarvkrit

/// Regressions for bugs that shipped: a preview that could never match, and an App Sweep that
/// forgot every deletion it wasn't awake to see.
final class PaneRegressionTests: XCTestCase {
    private var watched: URL!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        watched = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-pane-\(UUID().uuidString)")
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-pane-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: watched)
        try? FileManager.default.removeItem(at: storeDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Preview must work on a rule you're still building

    private func disabledRule() throws -> Rule {
        Rule(
            name: "under construction",
            isEnabled: false,
            folderBookmark: try XCTUnwrap(ActionRunner.bookmark(for: watched)),
            conditions: [Condition(attribute: .fileExtension, comparison: .isExactly, value: .text("txt"))],
            actions: [.sortIntoSubfolder(pattern: "Text")]
        )
    }

    func testPreviewMatchesEvenThoughTheRuleIsDisabled() throws {
        // The shipped bug: you preview a rule precisely while building it, and a rule under
        // construction is disabled — so the matcher was correctly answering "no match" every time,
        // and the preview looked broken.
        try "x".write(to: watched.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let store = RuleStore(directory: storeDirectory)
        let feature = FileRulesFeature(store: store)
        let reports = feature.preview(rule: try disabledRule())

        XCTAssertEqual(reports.count, 1)
        guard case .acted = reports[0].verdict else {
            return XCTFail("preview reported \(reports[0].verdict) for a matching file")
        }
    }

    func testPreviewStillChangesNothing() throws {
        try "x".write(to: watched.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let feature = FileRulesFeature(store: RuleStore(directory: storeDirectory))
        _ = feature.preview(rule: try disabledRule())

        XCTAssertTrue(FileManager.default.fileExists(atPath: watched.appendingPathComponent("note.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: watched.appendingPathComponent("Text").path))
    }

    func testADisabledRuleStillNeverRunsForReal() throws {
        // Previewing as-if-enabled must not leak into the live path — the enabled switch has to
        // keep meaning something.
        try "x".write(to: watched.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let store = RuleStore(directory: storeDirectory)
        store.replace(with: [try disabledRule()])
        let feature = FileRulesFeature(store: store)
        feature.activate()
        defer { feature.deactivate() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: watched.appendingPathComponent("note.txt").path),
                      "a disabled rule filed a file")
    }

    func testMatcherItselfStillRefusesDisabledRules() throws {
        let file = FileSnapshot(
            url: URL(fileURLWithPath: "/tmp/a.txt"), name: "a", fileExtension: "txt",
            fullName: "a.txt", kind: .document, size: 1,
            dateAdded: Date(), dateModified: Date(), sourceURL: nil, tags: [], isDirectory: false)
        XCTAssertFalse(RuleMatcher.matches(file, rule: try disabledRule()))
    }

    // MARK: - App Sweep must survive being restarted

    func testAnAppDeletedWhileNotWatchingIsStillNoticed() {
        // The shipped bug: activate() overwrote the inventory, so anything removed while Sarvkrit
        // was quit was silently forgotten on the next launch.
        let defaults = UserDefaults(suiteName: "sweep.\(UUID())")!
        let feature = AppSweepFeature(defaults: defaults)

        // A remembered app that is not on disk and not registered anywhere.
        let ghost = AppLeftovers.InstalledApp(
            bundleID: "com.example.ghost-\(UUID().uuidString)",
            name: "Ghost",
            path: "/Applications/Ghost-\(UUID().uuidString).app")
        let encoded = try! JSONEncoder().encode([ghost])
        defaults.set(encoded, forKey: "appSweep.inventory")

        let reloaded = AppSweepFeature(defaults: defaults)
        XCTAssertEqual(reloaded.inventory.map(\.bundleID), [ghost.bundleID],
                       "the stored inventory should be loaded, not discarded")

        let removed = AppLeftovers.removedApps(
            inventory: reloaded.inventory,
            stillPresentPaths: [],
            stillRegisteredBundleIDs: [])
        XCTAssertEqual(removed.map(\.bundleID), [ghost.bundleID])
        _ = feature
    }

    func testTheInventoryIsPublishedSoTheCountRefreshes() {
        // "Apps tracked" read a computed property over UserDefaults and so never updated —
        // including immediately after pressing Rescan.
        let defaults = UserDefaults(suiteName: "sweep.\(UUID())")!
        let feature = AppSweepFeature(defaults: defaults)

        var notifications = 0
        let token = feature.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        feature.refreshInventory()

        XCTAssertGreaterThan(notifications, 0, "a rescan must tell the pane something changed")
        XCTAssertFalse(feature.inventory.isEmpty, "/Applications is not empty on a real Mac")
    }

    func testSeedingHappensOnlyWhenNothingIsRemembered() {
        let defaults = UserDefaults(suiteName: "sweep.\(UUID())")!
        let feature = AppSweepFeature(defaults: defaults)

        XCTAssertTrue(feature.inventory.isEmpty, "nothing is remembered before the first scan")
        feature.checkForRemovals()
        XCTAssertFalse(feature.inventory.isEmpty, "a first run should seed the inventory")
    }

    // MARK: - Trash access is known without being asked

    func testUnreadableTrashIsReportedWithoutRunningAPreviewFirst() {
        // The pane now probes on appear; the feature must report denial from that alone.
        let defaults = UserDefaults(suiteName: "trash.\(UUID())")!
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        let feature = TrashCleanupFeature(defaults: defaults, trashURL: missing)

        _ = feature.run(dryRun: true)

        XCTAssertEqual(feature.access, .denied)
        XCTAssertEqual(feature.trashItemCount, 0)
    }

    func testAReadableTrashReportsItsSizeSoZeroMatchesIsLegible() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fake) }
        try "x".write(to: fake.appendingPathComponent("recent.txt"), atomically: true, encoding: .utf8)

        let feature = TrashCleanupFeature(
            defaults: UserDefaults(suiteName: "trash.\(UUID())")!, trashURL: fake)
        let doomed = feature.run(dryRun: true)

        XCTAssertEqual(feature.access, .granted)
        XCTAssertEqual(feature.trashItemCount, 1)
        // Nothing qualifies yet — which the pane must be able to say differently from "broken".
        XCTAssertTrue(doomed.isEmpty)
    }
}
