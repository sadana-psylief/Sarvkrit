import Foundation

/// The app's identity, in one place.
///
/// The bundle ID is what macOS keys the Accessibility grant, `UserDefaults`, and the login item
/// registration to, so it ends up woven through logging, queue labels and cross-process
/// notification names. Hardcoding it in each of those drifts the moment it changes — as it just
/// did — so everything reads it from here instead.
enum AppIdentity {
    /// Read from the running bundle rather than hardcoded, so it can never disagree with what
    /// macOS actually thinks the app is. The literal is only a fallback for unit test hosts.
    static let bundleID = Bundle.main.bundleIdentifier ?? "ai.psylief.sarvkrit"

    static let logSubsystem = bundleID

    /// Whether this process is an XCTest host, set by XCTest in the environment.
    ///
    /// Not a convenience. Two things this app does are **global side effects on the user's Mac** —
    /// posting keyboard events and writing the pasteboard — and a unit test that reaches either one
    /// does not fail loudly; it types into whatever app the user happens to be looking at. That
    /// happened: every snippet test uses `expansion: "X"`, `SnippetFeatureTests` drove the real
    /// feature, and the expansion path posted genuine backspaces and a capital X into the
    /// foreground app on every test run. It read as the app randomly typing an X out of nowhere.
    ///
    /// Dependency injection is the real fix and is applied at those call sites. This is the backstop
    /// for the next test that forgets, because the failure mode is invisible from inside the suite.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// Posted by a duplicate launch to ask the instance that's already running to come forward.
    static let showWindowNotification = Notification.Name("\(bundleID).showWindow")
}
