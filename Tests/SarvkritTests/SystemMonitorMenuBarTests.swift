import XCTest
@testable import Sarvkrit

/// Whether the monitor's own menu bar item is in the menu bar.
///
/// A pure rule for the same reason `MenuBarIconState.current` is one, plus a sharper one specific
/// to this item. `SarvkritApp.body` re-evaluates when `AppState` publishes and at no other time, so
/// this decision may depend *only* on state `AppState` publishes. Anything owned by the feature —
/// which publishes through its own `objectWillChange` — would be invisible to the App body, and the
/// item would appear or vanish on some unrelated later redraw. That is the nested-observation bug
/// `MenuBarLabel` carries a comment about, and it is unfixable by holding the feature in the App
/// body: that would re-evaluate every scene on every sample.
final class SystemMonitorMenuBarTests: XCTestCase {

    func testTheItemAppearsWhenTheFeatureIsOnAndTheAppIconIsShown() {
        XCTAssertTrue(SystemMonitorMenuBar.isInserted(showsAppIcon: true, featureIsEnabled: true))
    }

    func testAFeatureThatIsOffHasNoItem() {
        XCTAssertFalse(SystemMonitorMenuBar.isInserted(showsAppIcon: true, featureIsEnabled: false))
    }

    func testHidingTheAppIconHidesTheMonitorItemToo() {
        // "Show Menu Bar Icon" means the app's presence in the menu bar. A monitor item that
        // survived it would defeat the setting for anyone who turned it off to declutter.
        XCTAssertFalse(SystemMonitorMenuBar.isInserted(showsAppIcon: false, featureIsEnabled: true))
    }

    func testBothOffIsStillNoItem() {
        XCTAssertFalse(SystemMonitorMenuBar.isInserted(showsAppIcon: false, featureIsEnabled: false))
    }
}
