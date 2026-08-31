import XCTest
@testable import Sarvkrit

/// `sync()` reconciles what the user switched on, what permission allows, and what is actually
/// running. It used to do that by cycling **every** feature on every toggle, which was expensive
/// enough to be felt system-wide: between them the real features fork `pmset`, enumerate
/// `/Applications`, walk the Trash and sweep every watched folder — synchronously, on the thread
/// the event tap runs on.
///
/// These pin the diffing behaviour that replaced it, because getting it wrong means a feature that
/// silently never starts.
final class AppStateSyncTests: XCTestCase {

    /// Counts its own lifecycle calls. Needs no permission, so it is never blocked.
    private final class CountingFeature: Feature {
        let id: String
        let category = FeatureCategory.files
        let title = "Counting"
        let summary = "Counts activations"
        let details = "Counts activations"
        let symbolName = "number"
        let requirements: Set<Requirement> = []

        private(set) var activations = 0
        private(set) var deactivations = 0

        init(id: String) { self.id = id }

        func activate() { activations += 1 }
        func deactivate() { deactivations += 1 }
    }

    private func makeState(_ features: [Feature]) -> AppState {
        AppState(
            features: features,
            store: FeatureStore(defaults: UserDefaults(suiteName: "sync.\(UUID())")!),
            permissions: PermissionsManager(),
            defaults: UserDefaults(suiteName: "sync.\(UUID())")!
        )
    }

    func testEnablingAFeatureActivatesItExactlyOnce() {
        let feature = CountingFeature(id: "a")
        let state = makeState([feature])

        state.setEnabled(feature, true)
        XCTAssertEqual(feature.activations, 1)
    }

    func testDisablingAFeatureDeactivatesIt() {
        let feature = CountingFeature(id: "a")
        let state = makeState([feature])

        state.setEnabled(feature, true)
        state.setEnabled(feature, false)
        XCTAssertEqual(feature.deactivations, 1)
    }

    func testTogglingOneFeatureLeavesTheOthersAlone() {
        // The whole point of the change. Previously every toggle deactivated and reactivated all
        // of them, so switching on Trash Cleanup would re-fork `pmset` for Keep Awake and rescan
        // /Applications for App Sweep.
        let a = CountingFeature(id: "a")
        let b = CountingFeature(id: "b")
        let state = makeState([a, b])

        state.setEnabled(a, true)
        let bActivations = b.activations
        let bDeactivations = b.deactivations

        state.setEnabled(b, true)
        XCTAssertEqual(a.activations, 1, "a should not have been restarted")
        XCTAssertEqual(a.deactivations, 0, "a should not have been stopped")

        state.setEnabled(a, false)
        XCTAssertEqual(b.activations, bActivations + 1, "b started once, when it was enabled")
        XCTAssertEqual(b.deactivations, bDeactivations, "b should not have been stopped")
    }

    func testAnAlreadyRunningFeatureIsNotRestartedByAnUnrelatedResync() {
        let feature = CountingFeature(id: "a")
        let state = makeState([feature])
        state.setEnabled(feature, true)

        state.resyncEventTap()
        state.resyncEventTap()

        XCTAssertEqual(feature.activations, 1, "a resync must not cycle a running feature")
        XCTAssertEqual(feature.deactivations, 0)
    }

    func testAFeatureLeftOffIsNeverActivated() {
        let feature = CountingFeature(id: "a")
        let state = makeState([feature])
        state.resyncEventTap()
        XCTAssertEqual(feature.activations, 0)
    }

    func testAFeatureDisabledWhileOffIsNotDeactivatedAgain() {
        // Deactivating something that was never running is where the old blanket loop did its
        // most pointless work.
        let feature = CountingFeature(id: "a")
        let state = makeState([feature])

        state.setEnabled(feature, true)
        state.setEnabled(feature, false)
        state.resyncEventTap()

        XCTAssertEqual(feature.deactivations, 1, "stopped once, not on every later sync")
    }

    func testEnablingThenDisablingRepeatedlyStaysBalanced() {
        let feature = CountingFeature(id: "a")
        let state = makeState([feature])

        for _ in 0..<3 {
            state.setEnabled(feature, true)
            state.setEnabled(feature, false)
        }
        XCTAssertEqual(feature.activations, 3)
        XCTAssertEqual(feature.deactivations, 3)
    }
}
