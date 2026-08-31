import AppKit
import Foundation
import os

/// Keeps exactly one Sarvkrit in the menu bar.
///
/// macOS declines to relaunch an app that's already running, but that check is keyed to the
/// app's **path**, not its bundle ID. Two copies of Sarvkrit in different folders are, as far as
/// LaunchServices is concerned, two different apps — so both start, and both insert their own
/// status item. `LSMultipleInstancesProhibited` in Info.plist closes the same-path case; this
/// closes the rest.
enum SingleInstance {
    /// Split out from the side-effecting call below because the failure mode here is silent and
    /// total: count yourself as a rival and the app terminates on every single launch.
    ///
    /// `isTestHost` is not a convenience. The unit tests are hosted *inside* Sarvkrit.app, so
    /// the test runner executes this same startup path — and if the real app happened to be
    /// running, the guard would exit(0) the test host and the whole suite would fail to launch
    /// with a bare "Could not launch SarvkritTests". Only real user launches get to yield.
    static func shouldYield(otherInstancePIDs: [pid_t], ownPID: pid_t, isTestHost: Bool = false) -> Bool {
        guard !isTestHost else { return false }
        return otherInstancePIDs.contains { $0 != ownPID }
    }

    /// Set by XCTest in the host process's environment. Lives on `AppIdentity` because posting
    /// events and writing the pasteboard need the same guard.
    static var isRunningTests: Bool { AppIdentity.isRunningTests }

    /// If another Sarvkrit is already running, ask it to show its window and bow out.
    ///
    /// Called from `SarvkritApp.init()` — before any scene is installed — so the duplicate never
    /// creates a status item and the user never sees a second icon appear and vanish. At that
    /// point `AppState.shared` is still untouched (it's lazy), so there is no event tap and no
    /// permission timer to unwind.
    @MainActor
    static func yieldIfAlreadyRunning() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .map(\.processIdentifier)

        guard shouldYield(otherInstancePIDs: pids, ownPID: ownPID, isTestHost: isRunningTests)
        else { return }

        // deliverImmediately, because exit(0) is the next line. Distributed notifications are
        // queued and coalesced by default, and a queued one dies with the process — leaving the
        // user with a launch that did visibly nothing, which is worse than the duplicate icon
        // this whole path exists to prevent.
        // Logged with the winner's path: "I launched it and nothing happened" is otherwise
        // impossible to diagnose, and a leftover build in DerivedData is a real way to hit it.
        let winner = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppIdentity.bundleID)
            .first { $0.processIdentifier != ownPID }?
            .bundleURL?.path ?? "unknown location"
        Logger(subsystem: AppIdentity.logSubsystem, category: "SingleInstance")
            .notice("another Sarvkrit is already running from \(winner, privacy: .public) — yielding to it")

        DistributedNotificationCenter.default().postNotificationName(
            AppIdentity.showWindowNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }
}
