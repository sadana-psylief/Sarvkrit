import XCTest
@testable import Sarvkrit

final class FeatureStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ai.psylief.sarvkrit.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultsToNothingEnabled() {
        let store = FeatureStore(defaults: defaults)
        XCTAssertFalse(store.isEnabled("finder-cut-paste"))
        XCTAssertTrue(store.enabledIDs.isEmpty)
    }

    func testEnablingPersistsAcrossInstances() {
        let store = FeatureStore(defaults: defaults)
        store.setEnabled("finder-cut-paste", true)

        let reloaded = FeatureStore(defaults: defaults)
        XCTAssertTrue(reloaded.isEnabled("finder-cut-paste"))
        XCTAssertFalse(reloaded.isEnabled("quit-on-close"))
    }

    func testDisablingPersists() {
        let store = FeatureStore(defaults: defaults)
        store.setEnabled("quit-on-close", true)
        store.setEnabled("quit-on-close", false)

        XCTAssertFalse(FeatureStore(defaults: defaults).isEnabled("quit-on-close"))
    }

    func testFeaturesAreIndependent() {
        let store = FeatureStore(defaults: defaults)
        store.setEnabled("finder-cut-paste", true)
        store.setEnabled("quit-on-close", true)
        store.setEnabled("finder-cut-paste", false)

        let reloaded = FeatureStore(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled("finder-cut-paste"))
        XCTAssertTrue(reloaded.isEnabled("quit-on-close"))
    }

    func testRedundantWritesAreIgnored() {
        let store = FeatureStore(defaults: defaults)
        store.setEnabled("quit-on-close", false)
        XCTAssertTrue(store.enabledIDs.isEmpty)
    }

    func testRegistryIDsAreUniqueAndStable() {
        // A duplicate id would silently make two features share one toggle.
        let ids = FeatureRegistry.makeAll().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids, ["finder-cut-paste", "text-snippets", "clipboard-history",
                             "window-management", "quit-on-close", "file-rules", "trash-cleanup",
                             "app-sweep", "shelf", "audio-switcher",
                             "mute-microphone", "keep-awake"])
    }
}
