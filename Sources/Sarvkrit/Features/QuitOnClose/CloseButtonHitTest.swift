import ApplicationServices
import Foundation

/// Decision logic for Quit on Close, separated from the AX plumbing so it can be tested
/// without a live window on screen.
enum CloseButtonHitTest {
    /// Quitting Finder takes the desktop and every file operation with it. Excluding
    /// Sarvkrit itself keeps the app from closing its own window into a quit.
    /// A user-editable list is a later enhancement.
    static let excludedBundleIDs: Set<String> = [
        "com.apple.finder",
    ]

    struct Target: Equatable {
        var role: String?
        var subrole: String?
        var bundleID: String?
        /// Only real, windowed apps. Terminating a background agent because it happened to
        /// own a stray panel would be hostile.
        var isRegularApp: Bool
    }

    static func isCloseButton(_ target: Target, ownBundleID: String) -> Bool {
        guard target.role == (kAXButtonRole as String),
              target.subrole == (kAXCloseButtonSubrole as String),
              target.isRegularApp,
              let bundleID = target.bundleID,
              bundleID != ownBundleID,
              !excludedBundleIDs.contains(bundleID)
        else { return false }
        return true
    }

    /// `windowCount` is nil when the app couldn't be asked — it quit on its own, or stopped
    /// answering. That is explicitly *not* "zero windows": terminating on a failed query
    /// would kill apps for being briefly busy.
    static func shouldTerminate(windowCount: Int?) -> Bool {
        windowCount == 0
    }
}
