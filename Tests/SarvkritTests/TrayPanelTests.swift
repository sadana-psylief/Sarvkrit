import Combine
import SwiftUI
import XCTest
@testable import Sarvkrit

/// The strip's composition rules. Successor to `TrayTabTests`, which pinned the same contracts back
/// when a tab was a `FeatureCategory`: General last, an empty group never gets a tab, a remembered
/// selection is restored, a vanished one falls back, and a same-value write publishes nothing.
final class TrayPanelTests: XCTestCase {

    private func makeState(features: [Feature], defaults: UserDefaults) -> AppState {
        AppState(
            features: features,
            store: FeatureStore(defaults: UserDefaults(suiteName: "traypanel.\(UUID())")!),
            permissions: PermissionsManager(),
            defaults: defaults
        )
    }

    private func panel(_ id: String, title: String? = nil, symbol: String = "circle") -> TrayPanel {
        TrayPanel(id: id, title: title ?? id.capitalized, symbolName: symbol) { EmptyView() }
    }

    private var features: TrayPanel { panel(TrayPanel.featuresID, title: "Features") }
    private var general: TrayPanel { panel(TrayPanel.generalID, title: "General") }

    // MARK: - Composition

    func testGeneralIsAlwaysLast() {
        let strip = TrayPanel.strip(
            contributed: [panel("keep-awake"), panel("system")],
            features: features, general: general)
        XCTAssertEqual(strip.map(\.id), ["keep-awake", "system", "features", "general"])
    }

    func testFeaturesAndGeneralExistWithNothingSwitchedOn() {
        // Turning something back on has to remain reachable from the menu, whatever is off.
        let strip = TrayPanel.strip(contributed: [], features: features, general: general)
        XCTAssertEqual(strip.map(\.id), ["features", "general"])
    }

    func testEveryPanelHasATitleAndSymbol() {
        // The tabs are icons only, so a missing title is a tab no VoiceOver user can identify.
        let strip = TrayPanel.strip(
            contributed: [panel("system"), panel("sound")],
            features: features, general: general)
        for panel in strip {
            XCTAssertFalse(panel.title.isEmpty, panel.id)
            XCTAssertFalse(panel.symbolName.isEmpty, panel.id)
        }
    }

    // MARK: - Merging

    func testPanelsSharingAnIdBecomeOneTab() {
        // The five Sound features are one screen. Two tabs both called "Sound" would leak the fact
        // that Sarvkrit models them separately into the menu.
        let merged = TrayPanel.merged([
            panel("sound", title: "Sound"),
            panel("system"),
            panel("sound", title: "Sound"),
        ])
        XCTAssertEqual(merged.map(\.id), ["sound", "system"])
    }

    func testAMergedPanelKeepsTheFirstContributorsNameAndSymbol() {
        // Otherwise the panel would be named by whichever feature happened to be switched on last.
        let merged = TrayPanel.merged([
            panel("sound", title: "Sound", symbol: "slider.horizontal.3"),
            panel("sound", title: "Microphone", symbol: "mic"),
        ])
        XCTAssertEqual(merged.first?.title, "Sound")
        XCTAssertEqual(merged.first?.symbolName, "slider.horizontal.3")
    }

    func testAMergedPanelStaysWhereItsFirstContributorWas() {
        // A panel that moved along the strip when you switched a second feature on would be worse
        // than one that never moved at all: the tab you were aiming for would slide out from under
        // the pointer.
        let merged = TrayPanel.merged([
            panel("sound"), panel("system"), panel("sound"),
        ])
        XCTAssertEqual(merged.map(\.id), ["sound", "system"])
    }

    func testMergingLeavesDistinctPanelsAlone() {
        let ids = ["keep-awake", "sound", "system", "network"]
        XCTAssertEqual(TrayPanel.merged(ids.map { panel($0) }).map(\.id), ids)
    }

    // MARK: - Resolving a remembered selection

    func testARememberedPanelIsRestored() {
        let strip = TrayPanel.strip(
            contributed: [panel("keep-awake"), panel("system")],
            features: features, general: general)
        XCTAssertEqual(TrayPanel.resolve(storedID: "system", available: strip), "system")
    }

    func testAPanelThatNoLongerExistsFallsBackToTheFirst() {
        // Switching System Monitor off while standing on its panel is the ordinary way to reach
        // this, not an edge case.
        let strip = TrayPanel.strip(
            contributed: [panel("keep-awake")], features: features, general: general)
        XCTAssertEqual(TrayPanel.resolve(storedID: "system", available: strip), "keep-awake")
    }

    func testNoRememberedPanelOpensOnTheFirst() {
        let strip = TrayPanel.strip(
            contributed: [panel("system")], features: features, general: general)
        XCTAssertEqual(TrayPanel.resolve(storedID: nil, available: strip), "system")
        XCTAssertEqual(TrayPanel.resolve(storedID: "garbage", available: strip), "system")
    }

    func testResolvingAgainstNothingStillYieldsAPanel() {
        XCTAssertEqual(TrayPanel.resolve(storedID: nil, available: []), TrayPanel.generalID)
        XCTAssertEqual(TrayPanel.resolve(storedID: "system", available: []), TrayPanel.generalID)
    }

    // MARK: - What the registry actually contributes

    func testASwitchedOffFeatureContributesNoPanel() {
        let defaults = UserDefaults(suiteName: "traypanel.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        MainActor.assumeIsolated {
            let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
            let monitor = state.features.first { $0 is SystemMonitorFeature }!

            state.setEnabled(monitor, false)
            XCTAssertFalse(state.contributedTrayPanels.contains { $0.id == "system" })

            state.setEnabled(monitor, true)
            XCTAssertTrue(state.contributedTrayPanels.contains { $0.id == "system" })
        }
    }

    func testKeepAwakeKeepsItsPanelWhileSwitchedOff() {
        // The exception, and the reason `panelIsItsOwnSwitch` exists: the switch is the feature, so
        // hiding the panel would put "keep my Mac awake" behind a detour through Features.
        let defaults = UserDefaults(suiteName: "traypanel.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        MainActor.assumeIsolated {
            let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
            let keepAwake = state.features.first { $0 is KeepAwakeFeature }!

            state.setEnabled(keepAwake, false)
            XCTAssertTrue(state.contributedTrayPanels.contains { $0.id == "keep-awake" })
        }
    }

    func testKeepAwakeIsTheOnlyFeatureThatDoesThat() {
        // A second one would mean a panel that draws nothing, which is what the flag exists to
        // prevent. If this ever fails deliberately, the reason belongs in the new feature's header.
        let owned = FeatureRegistry.makeAll().filter(\.panelIsItsOwnSwitch).map(\.id)
        XCTAssertEqual(owned, ["keep-awake"])
    }

    // MARK: - Persistence and publish behaviour

    func testSelectionPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: "traypanel.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        state.selectedTrayTabID = "system"

        let reloaded = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        XCTAssertEqual(reloaded.selectedTrayTabID, "system")
    }

    func testSelectingTheSamePanelPublishesNothing() {
        // Same regression AppStateTests pins for the other user-writable properties: SwiftUI writes
        // back through two-way bindings routinely, and republishing on a same-value write is what
        // pinned a CPU core earlier in this project.
        let defaults = UserDefaults(suiteName: "traypanel.\(UUID())")!
        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        state.selectedTrayTabID = "system"

        var notifications = 0
        let token = state.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        state.selectedTrayTabID = "system"
        state.selectedTrayTabID = "system"

        XCTAssertEqual(notifications, 0)
    }

    func testChangingPanelPublishesExactlyOnce() {
        let defaults = UserDefaults(suiteName: "traypanel.\(UUID())")!
        let state = makeState(features: FeatureRegistry.makeAll(), defaults: defaults)
        state.selectedTrayTabID = "system"

        var notifications = 0
        let token = state.objectWillChange.sink { _ in notifications += 1 }
        defer { token.cancel() }

        state.selectedTrayTabID = "sound"

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(state.selectedTrayTabID, "sound")
    }
}
