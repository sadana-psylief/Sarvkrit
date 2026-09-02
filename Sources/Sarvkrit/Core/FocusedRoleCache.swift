import AppKit
import ApplicationServices
import Foundation

/// Whether a text field currently has focus — answered from a cache rather than by asking.
///
/// Exists because `CutPasteFeature` needs this to tell "⌘X while renaming a file" from "⌘X on a
/// selection of files", and it needs it **inside the event tap callback**. That callback runs on the
/// main run loop, so anything slow in it is not this app being slow: it is every keystroke on the
/// Mac being slow, in whatever app the user is actually typing in.
///
/// Asking directly cost up to half a second of that. `AX.focusedElementRole()` makes two AX calls,
/// each capped at `AX.messagingTimeout` (0.25s), and an AX query is served by the *target* process's
/// main run loop — so a busy Finder stalls us for as long as it likes, up to the cap. `AXHelpers`
/// says so in its own header: *"nothing in this file may be called from the event tap callback"*.
/// The tap has been observed going over the system's patience and being disabled for it.
///
/// So the value is kept up to date out of band instead, by the same trick `FrontmostAppMonitor`
/// uses: seed on app activation, then let a notification maintain it. The hot path becomes a
/// property read.
final class FocusedRoleCache {
    static let shared = FocusedRoleCache()

    /// nil means "not established yet" and is deliberately distinct from false.
    ///
    /// The two ways of being wrong are not equally bad. Guessing *false* during a rename turns the
    /// user's ⌘X into ⌘C, which fails to cut their text **and** puts the file on the pasteboard, so
    /// a later ⌘V moves it — a file operation they never asked for. Guessing *true* only makes ⌘X
    /// pass through untouched, so the feature does nothing for one keystroke. Callers should read
    /// this as `?? true` and take the harmless failure.
    private(set) var isTextFieldFocused: Bool?

    private let queue = DispatchQueue(
        label: "\(AppIdentity.bundleID).focused-role", qos: .userInitiated)

    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var startCount = 0

    /// Only the app whose text fields we need to distinguish. Observing every app would mean an
    /// AX observer against arbitrary processes for a question only Finder ever asks.
    private static let watchedBundleID = "com.apple.finder"

    /// Reference-counted, matching `FrontmostAppMonitor`, so one feature's `deactivate()` can't
    /// blind another's.
    func start() {
        startCount += 1
        guard workspaceObserver == nil else { return }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.frontmostChanged(to: app)
        }

        frontmostChanged(to: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        startCount = max(0, startCount - 1)
        guard startCount == 0 else { return }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        detachAXObserver()
        isTextFieldFocused = nil
    }

    // MARK: - Keeping it current

    private func frontmostChanged(to app: NSRunningApplication?) {
        detachAXObserver()

        guard app?.bundleIdentifier == Self.watchedBundleID, let pid = app?.processIdentifier else {
            // Outside Finder the answer can't matter: `CutPasteRewriter` requires Finder frontmost
            // before it looks at this at all.
            isTextFieldFocused = nil
            return
        }

        // Seeded here rather than lazily on first use. Focus is read *now*, hundreds of
        // milliseconds before the user can plausibly reach ⌘X, so the cache is warm by the time
        // it's consulted and the "unknown" window stays closed in practice.
        refresh()
        attachAXObserver(pid: pid)
    }

    /// Focus moves inside Finder without any app switching — clicking into a rename field is the
    /// whole case this feature exists for — so activation alone is not enough to stay correct.
    private func attachAXObserver(pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<FocusedRoleCache>.fromOpaque(refcon).takeUnretainedValue().refresh()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let result = AXObserverAddNotification(
            observer, AX.application(pid: pid),
            kAXFocusedUIElementChangedNotification as CFString, refcon)
        guard result == .success else { return }

        // Main run loop is right: the callback below does no work beyond kicking off an
        // off-thread read, and the value it produces is only ever read from the main thread.
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        observedPID = pid
    }

    private func detachAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        observedPID = nil
    }

    /// The one place that actually talks to AX — always off the main thread, so a wedged Finder
    /// costs a background queue nothing anyone can feel.
    private func refresh() {
        queue.async { [weak self] in
            let role = AX.focusedElementRole()
            let isTextField = role == (kAXTextFieldRole as String)
                || role == (kAXTextAreaRole as String)
            // Written on main so the tap callback, which also runs on main, never races it. That
            // makes the property safe with no lock — and a lock in the tap path would be its own
            // version of the problem this type exists to solve.
            DispatchQueue.main.async { self?.isTextFieldFocused = isTextField }
        }
    }
}
