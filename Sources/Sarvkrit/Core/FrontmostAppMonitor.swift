import AppKit
import Foundation

/// Keeps the frontmost app's bundle identifier available without asking for it.
///
/// `NSWorkspace.shared.frontmostApplication` is not free, and features consult it from inside the
/// event tap — i.e. once per keystroke, on the main thread, for every key pressed anywhere on the
/// Mac. The value only changes when the user switches apps, so it is cached from the notification
/// instead and the hot path becomes a property read.
final class FrontmostAppMonitor {
    static let shared = FrontmostAppMonitor()

    /// Read from the event tap callback on the main thread; written by the notification, which
    /// also arrives on the main thread.
    private(set) var bundleID: String?

    private var observer: NSObjectProtocol?
    private var startCount = 0

    /// Reference-counted so several features can depend on it without one's `deactivate()`
    /// blinding the others.
    func start() {
        startCount += 1
        guard observer == nil else { return }

        // Seed immediately: without this the cache reads nil until the user's next app switch,
        // which would silently disable anything gated on the frontmost app.
        bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.bundleID = app?.bundleIdentifier
        }
    }

    func stop() {
        startCount = max(0, startCount - 1)
        guard startCount == 0, let observer else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        self.observer = nil
        bundleID = nil
    }
}
