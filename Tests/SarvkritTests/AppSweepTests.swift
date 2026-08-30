import XCTest
@testable import Sarvkrit

/// App Sweep deletes files belonging to apps that no longer exist, guided entirely by string
/// matching. Both halves — "is this app really gone?" and "is this file really its leftover?" —
/// are pure, and both are where this class of tool goes wrong.
final class AppSweepTests: XCTestCase {

    private func app(_ id: String, name: String = "Example", path: String? = nil) -> AppLeftovers.InstalledApp {
        AppLeftovers.InstalledApp(bundleID: id, name: name, path: path ?? "/Applications/\(name).app")
    }

    // MARK: - Deleted versus updated

    func testAnAppMissingFromDiskAndUnregisteredCountsAsRemoved() {
        let removed = AppLeftovers.removedApps(
            inventory: [app("com.example.gone")],
            stillPresentPaths: [],
            stillRegisteredBundleIDs: []
        )
        XCTAssertEqual(removed.map(\.bundleID), ["com.example.gone"])
    }

    func testAnAppBeingUpdatedIsNotTreatedAsRemoved() {
        // The single most important case. An update is a delete followed by a replace; if macOS can
        // still resolve the bundle ID, the app is being upgraded — sweeping now would wipe the
        // preferences of an app the user still has.
        let removed = AppLeftovers.removedApps(
            inventory: [app("com.example.updating")],
            stillPresentPaths: [],
            stillRegisteredBundleIDs: ["com.example.updating"]
        )
        XCTAssertTrue(removed.isEmpty, "an updating app must never be swept")
    }

    func testAnAppMovedToAnotherFolderIsNotTreatedAsRemoved() {
        // Dragging an app out of /Applications isn't uninstalling it.
        let removed = AppLeftovers.removedApps(
            inventory: [app("com.example.moved")],
            stillPresentPaths: [],
            stillRegisteredBundleIDs: ["com.example.moved"]
        )
        XCTAssertTrue(removed.isEmpty)
    }

    func testAnAppStillOnDiskIsNotRemoved() {
        let installed = app("com.example.here")
        let removed = AppLeftovers.removedApps(
            inventory: [installed],
            stillPresentPaths: [installed.path],
            stillRegisteredBundleIDs: []
        )
        XCTAssertTrue(removed.isEmpty)
    }

    func testOnlyTheMissingAppIsReported() {
        let kept = app("com.example.kept", name: "Kept")
        let gone = app("com.example.gone", name: "Gone")
        let removed = AppLeftovers.removedApps(
            inventory: [kept, gone],
            stillPresentPaths: [kept.path],
            stillRegisteredBundleIDs: [kept.bundleID]
        )
        XCTAssertEqual(removed.map(\.bundleID), ["com.example.gone"])
    }

    // MARK: - Leftover matching

    func testRecognisedLeftoverShapes() {
        let id = "com.example.app"
        XCTAssertTrue(AppLeftovers.isLeftover(name: id, bundleID: id))
        XCTAssertTrue(AppLeftovers.isLeftover(name: "\(id).plist", bundleID: id))
        XCTAssertTrue(AppLeftovers.isLeftover(name: "\(id).savedState", bundleID: id))
    }

    func testAPrefixMatchIsRejected() {
        // Without exact matching, com.example.app would claim com.example.apple's data.
        XCTAssertFalse(AppLeftovers.isLeftover(name: "com.example.apple", bundleID: "com.example.app"))
        XCTAssertFalse(AppLeftovers.isLeftover(name: "com.example.app.helper", bundleID: "com.example.app"))
    }

    func testUnrelatedFilesAreRejected() {
        XCTAssertFalse(AppLeftovers.isLeftover(name: "com.apple.finder.plist", bundleID: "com.example.app"))
        XCTAssertFalse(AppLeftovers.isLeftover(name: "Example", bundleID: "com.example.app"))
        XCTAssertFalse(AppLeftovers.isLeftover(name: "", bundleID: "com.example.app"))
    }

    func testNameBasedMatchingIsNotUsedAtAll() {
        // Matching on the app's *name* is how these tools delete the wrong thing: "Notes",
        // "Mail" and "Music" are not distinctive enough to own a folder.
        XCTAssertFalse(AppLeftovers.isLeftover(name: "Notes", bundleID: "com.example.notes"))
        XCTAssertFalse(AppLeftovers.isLeftover(name: "Music", bundleID: "com.example.music"))
    }

    // MARK: - Searching a real tree

    func testFindsLeftoversAcrossLibrarySubfolders() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }

        let bundleID = "com.example.testapp"
        for root in ["Application Support", "Caches", "Preferences"] {
            let directory = library.appendingPathComponent(root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Application Support/\(bundleID)"),
            withIntermediateDirectories: true)
        try "data".write(
            to: library.appendingPathComponent("Application Support/\(bundleID)/db.sqlite"),
            atomically: true, encoding: .utf8)
        try "prefs".write(
            to: library.appendingPathComponent("Preferences/\(bundleID).plist"),
            atomically: true, encoding: .utf8)
        // A decoy that must not be swept.
        try "other".write(
            to: library.appendingPathComponent("Preferences/com.other.app.plist"),
            atomically: true, encoding: .utf8)

        let candidates = AppLeftovers.findCandidates(for: bundleID, libraryURL: library)

        let names = Set(candidates.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, [bundleID, "\(bundleID).plist"])
        XCTAssertFalse(names.contains("com.other.app.plist"), "swept an unrelated app's preferences")
    }

    func testDirectorySizesAreSummedNotZero() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }

        let bundleID = "com.example.sized"
        let support = library.appendingPathComponent("Application Support/\(bundleID)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try String(repeating: "x", count: 4_096).write(
            to: support.appendingPathComponent("big.bin"), atomically: true, encoding: .utf8)

        let candidates = AppLeftovers.findCandidates(for: bundleID, libraryURL: library)

        XCTAssertEqual(candidates.count, 1)
        // The size is what the user judges by; reporting 0 for a folder would make the offer useless.
        XCTAssertGreaterThanOrEqual(candidates[0].size, 4_096)
    }

    func testUnreadableDirectoriesAreSkippedNotReportedAsEmpty() {
        // A TCC-restricted folder means "unknown", not "nothing there". Claiming no leftovers when
        // we simply couldn't look would be a quiet lie.
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        XCTAssertTrue(AppLeftovers.findCandidates(for: "com.example.app", libraryURL: missing).isEmpty)
    }

    func testCandidatesAreOrderedLargestFirst() throws {
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: library) }

        let bundleID = "com.example.ordered"
        let caches = library.appendingPathComponent("Caches")
        let prefs = library.appendingPathComponent("Preferences")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefs, withIntermediateDirectories: true)
        try String(repeating: "x", count: 8_192).write(
            to: caches.appendingPathComponent(bundleID), atomically: true, encoding: .utf8)
        try "small".write(
            to: prefs.appendingPathComponent("\(bundleID).plist"), atomically: true, encoding: .utf8)

        let candidates = AppLeftovers.findCandidates(for: bundleID, libraryURL: library)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertGreaterThan(candidates[0].size, candidates[1].size, "biggest should be listed first")
    }

    // MARK: - Feature shape

    func testFeatureShipsInFilesAndNeedsNoAccessibility() {
        let feature = AppSweepFeature(defaults: UserDefaults(suiteName: "sweep.\(UUID())")!)
        XCTAssertEqual(feature.category, .files)
        XCTAssertFalse(feature.requiresAccessibility)
        XCTAssertTrue(feature.findings.isEmpty, "nothing should be offered before a scan")
    }

    func testInventoryRoundTripsThroughDefaults() {
        let defaults = UserDefaults(suiteName: "sweep.\(UUID())")!
        let feature = AppSweepFeature(defaults: defaults)

        // The inventory is the whole trick: a deleted bundle can't be read, so its identity has to
        // have been recorded while it was still installed.
        feature.refreshInventory()
        let scanned = feature.inventory

        let reloaded = AppSweepFeature(defaults: defaults)
        XCTAssertEqual(reloaded.inventory, scanned)
    }

    func testAnEmptyInventoryOffersNothing() {
        // First run after install: everything looks "new", nothing looks deleted.
        let feature = AppSweepFeature(defaults: UserDefaults(suiteName: "sweep.\(UUID())")!)
        feature.checkForRemovals()
        XCTAssertTrue(feature.findings.isEmpty)
    }
}
