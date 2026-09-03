import Foundation

/// Whether the monitor's own menu bar item is inserted.
///
/// Pure for the same reason `MenuBarIconState.current` is, plus one specific to this item:
/// `SarvkritApp.body` re-evaluates when `AppState` publishes and at no other time, so this decision
/// may depend only on state `AppState` publishes. A setting owned by the feature would publish
/// through the feature's own `objectWillChange`, be invisible to the App body, and make the item
/// appear or vanish on some unrelated later redraw — the nested-observation bug `MenuBarLabel`
/// carries a comment about. Holding the feature in the App body would fix the observation and cost
/// a re-evaluation of every scene on every sample, which is worse.
///
/// Hence there is no "show in menu bar" switch: the item is present exactly when the feature is on
/// and the app is showing a menu bar icon at all.
enum SystemMonitorMenuBar {
    static func isInserted(showsAppIcon: Bool, featureIsEnabled: Bool) -> Bool {
        // "Show Menu Bar Icon" means the app's presence in the menu bar; an item that survived it
        // would defeat the setting for anyone who switched it off to declutter.
        showsAppIcon && featureIsEnabled
    }
}
