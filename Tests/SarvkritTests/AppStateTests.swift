import Combine
import XCTest
@testable import Sarvkrit

/// These exist because of a real hang: `@Published` notifies on every write, including a write
/// of the value the property already holds. SwiftUI writes back through two-way bindings during
/// ordinary update passes, so a same-value write became notify → invalidate → update → write
/// back → notify, and the app pinned a CPU core at 100% until it was killed.
///
/// The contract below — a same-value write publishes nothing — is what keeps that from returning.
@MainActor
final class AppStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        suiteName = "ai.psylief.sarvkrit.appstate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        cancellables.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeState() -> AppState {
        AppState(
            features: FeatureRegistry.makeAll(),
            store: FeatureStore(defaults: defaults),
            permissions: PermissionsManager(),
            defaults: defaults
        )
    }

    private func countNotifications(from state: AppState, during body: () -> Void) -> Int {
        var count = 0
        state.objectWillChange
            .sink { _ in count += 1 }
            .store(in: &cancellables)
        body()
        return count
    }

    // MARK: - The regression

    func testWritingTheSameValueNotifiesNobody() {
        let state = makeState()
        let current = state.showMenuBarIcon
        let notifications = countNotifications(from: state) {
            state.showMenuBarIcon = current
            state.showMenuBarIcon = current
            state.showMenuBarIcon = current
        }
        XCTAssertEqual(notifications, 0, "same-value writes must be inert — this is the render loop")
    }

    func testOnboardingFlagSameValueNotifiesNobody() {
        let state = makeState()
        let current = state.hasCompletedOnboarding
        XCTAssertEqual(countNotifications(from: state) { state.hasCompletedOnboarding = current }, 0)
    }

    func testLaunchAtLoginSameValueNotifiesNobody() {
        // Also proves the setter returns *before* touching SMAppService: if the guard were
        // missing, this test would perform an XPC round trip to the login item daemon.
        let state = makeState()
        let current = state.launchAtLogin
        XCTAssertEqual(countNotifications(from: state) { state.launchAtLogin = current }, 0)
    }

    // MARK: - Real changes still propagate

    func testChangingAValueNotifiesExactlyOnce() {
        let state = makeState()
        let flipped = !state.showMenuBarIcon
        let notifications = countNotifications(from: state) { state.showMenuBarIcon = flipped }
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(state.showMenuBarIcon, flipped)
    }

    func testChangingOnboardingFlagNotifiesExactlyOnce() {
        let state = makeState()
        let flipped = !state.hasCompletedOnboarding
        XCTAssertEqual(countNotifications(from: state) { state.hasCompletedOnboarding = flipped }, 1)
        XCTAssertEqual(state.hasCompletedOnboarding, flipped)
    }

    func testValuesPersistToTheInjectedDefaults() {
        let state = makeState()
        state.showMenuBarIcon = false
        state.hasCompletedOnboarding = true

        let reloaded = makeState()
        XCTAssertFalse(reloaded.showMenuBarIcon)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
    }

    // MARK: - Motion

    func testReduceMotionSuppressesAnimation() {
        XCTAssertNil(Theme.Motion.resolved(reduceMotion: true))
        XCTAssertNotNil(Theme.Motion.resolved(reduceMotion: false))
    }

    // MARK: - Feature toggles

    func testTogglingAFeatureNotifiesOnceNotTwice() {
        // sync() used to assign blockedFeatureIDs unconditionally *and* send objectWillChange,
        // on top of the forwarded store notification — so one toggle published repeatedly.
        //
        // Uses a feature with no requirements on purpose. An Accessibility-dependent one would
        // also move the blocked set — which legitimately publishes — making the count depend on
        // whether the machine running the tests happens to have granted Accessibility.
        let state = makeState()
        guard let feature = state.features.first(where: { $0.requirements.isEmpty }) else {
            return XCTFail("expected a feature with no requirements")
        }

        let notifications = countNotifications(from: state) {
            state.setEnabled(feature, true)
        }
        XCTAssertEqual(notifications, 1, "one user action should produce one notification")
        XCTAssertTrue(state.isEnabled(feature))
    }

    // MARK: - Toggle bindings
    //
    // These exist because of a shipped bug: `binding(for:)` cached one shared `Binding` per
    // feature, so the tray row and the window's detail pane — separate SwiftUI view trees — were
    // handed the same object, and a toggle read as off again after reopening the tray.

    func testSeparateBindingsForTheSameFeatureAgree() {
        // Two call sites, as the tray and the detail pane are. A write through one must be visible
        // through the other; the shared cache was quietly relying on this and getting it wrong.
        let state = makeState()
        guard let feature = state.features.first(where: { $0.requirements.isEmpty }) else {
            return XCTFail("expected a feature with no requirements")
        }

        let fromTray = state.binding(for: feature)
        let fromDetail = state.binding(for: feature)

        XCTAssertFalse(fromTray.wrappedValue)
        XCTAssertFalse(fromDetail.wrappedValue)

        fromTray.wrappedValue = true

        XCTAssertTrue(fromDetail.wrappedValue, "a second binding read a stale value")
        XCTAssertTrue(state.binding(for: feature).wrappedValue, "a later binding read a stale value")
        XCTAssertTrue(state.isEnabled(feature))
    }

    func testBindingsAreDistinctObjectsPerCall() {
        // The fix itself: each call site gets its own binding rather than a shared, long-lived one.
        let state = makeState()
        guard let feature = state.features.first else { return XCTFail("no features") }

        let first = state.binding(for: feature)
        let second = state.binding(for: feature)
        first.wrappedValue = true
        second.wrappedValue = false

        XCTAssertFalse(state.isEnabled(feature), "the last write should win, through either binding")
    }

    func testBindingRoundTripsThroughOffAndOnAgain() {
        let state = makeState()
        guard let feature = state.features.first(where: { $0.requirements.isEmpty }) else {
            return XCTFail("expected a feature with no requirements")
        }

        state.binding(for: feature).wrappedValue = true
        XCTAssertTrue(state.binding(for: feature).wrappedValue)

        state.binding(for: feature).wrappedValue = false
        XCTAssertFalse(state.binding(for: feature).wrappedValue)

        state.binding(for: feature).wrappedValue = true
        XCTAssertTrue(state.binding(for: feature).wrappedValue)
    }

    func testBindingSurvivesReloadFromTheSameDefaults() {
        // What "come back to the app" looks like across a relaunch.
        let state = makeState()
        guard let feature = state.features.first(where: { $0.requirements.isEmpty }) else {
            return XCTFail("expected a feature with no requirements")
        }
        state.binding(for: feature).wrappedValue = true

        let reloaded = makeState()
        guard let same = reloaded.feature(withID: feature.id) else { return XCTFail("feature lost") }
        XCTAssertTrue(reloaded.binding(for: same).wrappedValue)
    }

    func testTogglingAFeatureToItsCurrentValueIsInert() {
        let state = makeState()
        guard let feature = state.features.first else { return XCTFail("no features registered") }
        XCTAssertEqual(countNotifications(from: state) { state.setEnabled(feature, false) }, 0)
    }
}
