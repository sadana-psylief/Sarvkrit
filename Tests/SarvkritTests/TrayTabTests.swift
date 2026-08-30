import Combine
import XCTest
@testable import Sarvkrit

final class TrayTabTests: XCTestCase {

    private func makeState(features: [Feature], defaults: UserDefaults) -> AppState {
        AppState(
            features: features,
            store: FeatureStore(defaults: UserDefaults(suiteName: "traytab.\(UUID())")!),
            permissions: PermissionsManager(),
            defaults: defaults
        )
    }

    // MARK: - Composition

    func testGeneralIsAlwaysLast() {
        let tabs = TrayTab.tabs(for: [.keyboard, .windows, .files])
        XCTAssertEqual(tabs.last, .general)
        XCTAssertEqual(tabs.map(\.id), ["keyboard", "windows", "files", "general"])
    }

    func testEmptyCategoriesNeverGetATab() {
        // The category list handed in is already filtered; this pins that no tab is invented for
        // one that isn't there.
        let tabs = TrayTab.tabs(for: [.keyboard])
        XCTAssertEqual(tabs.map(\.id), ["keyboard", "general"])
        XCTAssertFalse(tabs.contains(.category(.files)))
    }

    func testGeneralExistsEvenWithNoFeaturesAtAll() {
        // Launch at Login has to remain reachable regardless.
        XCTAssertEqual(TrayTab.tabs(for: []), [.general])
    }

    func testEveryTabHasATitleAndSymbol() {
        for tab in TrayTab.tabs(for: FeatureCategory.allCases) {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.symbolName.isEmpty)
        }
    }

    func testTabsMatchTheSidebarsCategories() {
        // The tray and the window's sidebar are two presentations of one list; if they can drift,
        // a feature can appear in one and not the other.
        let defaults = UserDefaults(suiteName: "traytab.\(UUID())")!
        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)

        let tabCategories = state.trayTabs.compactMap { tab -> FeatureCategory? in
            if case .category(let category) = tab { return category }
            return nil
        }
        XCTAssertEqual(tabCategories, state.populatedCategories)
    }

    // MARK: - Round-tripping the stored id

    func testIdentifiersRoundTrip() {
        for tab in TrayTab.tabs(for: FeatureCategory.allCases) {
            XCTAssertEqual(TrayTab(id: tab.id), tab)
        }
    }

    func testAnUnknownIdentifierDoesNotResolve() {
        XCTAssertNil(TrayTab(id: "nonsense"))
        XCTAssertNil(TrayTab(id: ""))
    }

    // MARK: - Resolving a remembered selection

    func testARememberedTabIsRestored() {
        let available = TrayTab.tabs(for: [.keyboard, .files])
        XCTAssertEqual(TrayTab.resolve(storedID: "files", available: available), .category(.files))
    }

    func testATabThatNoLongerExistsFallsBackToTheFirst() {
        // Otherwise a category emptied by a future change would open the panel on nothing.
        let available = TrayTab.tabs(for: [.keyboard])
        XCTAssertEqual(TrayTab.resolve(storedID: "files", available: available), .category(.keyboard))
    }

    func testNoRememberedTabOpensOnTheFirst() {
        let available = TrayTab.tabs(for: [.windows, .files])
        XCTAssertEqual(TrayTab.resolve(storedID: nil, available: available), .category(.windows))
        XCTAssertEqual(TrayTab.resolve(storedID: "garbage", available: available), .category(.windows))
    }

    func testResolvingAgainstNothingStillYieldsATab() {
        XCTAssertEqual(TrayTab.resolve(storedID: nil, available: []), .general)
    }

    // MARK: - Persistence and publish behaviour

    func testSelectionPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "traytab.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        state.selectedTrayTabID = TrayTab.category(.files).id

        let reloaded = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        XCTAssertEqual(reloaded.selectedTrayTabID, "files")
    }

    func testSelectingTheSameTabPublishesNothing() {
        // Same regression AppStateTests pins for the other user-writable properties: SwiftUI writes
        // back through two-way bindings routinely, and republishing on a same-value write is what
        // pinned a CPU core earlier in this project.
        let defaults = UserDefaults(suiteName: "traytab.\(UUID())")!
        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        state.selectedTrayTabID = "files"

        var notifications = 0
        let token = state.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        state.selectedTrayTabID = "files"
        state.selectedTrayTabID = "files"

        XCTAssertEqual(notifications, 0)
    }

    func testChangingTabPublishesExactlyOnce() {
        let defaults = UserDefaults(suiteName: "traytab.\(UUID())")!
        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        state.selectedTrayTabID = "files"

        var notifications = 0
        let token = state.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        state.selectedTrayTabID = "keyboard"

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(state.selectedTrayTabID, "keyboard")
    }
}
