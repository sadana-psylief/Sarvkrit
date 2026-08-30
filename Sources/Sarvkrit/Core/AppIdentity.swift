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

    /// Posted by a duplicate launch to ask the instance that's already running to come forward.
    static let showWindowNotification = Notification.Name("\(bundleID).showWindow")
}
