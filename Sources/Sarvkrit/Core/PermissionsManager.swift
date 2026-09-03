import ApplicationServices
import AppKit
import Combine
import CoreGraphics
import Foundation

/// Tracks the TCC grants the app can actually ask about.
///
/// There is no notification for either of them — the only way to know is to poll
/// `AXIsProcessTrusted` and `CGPreflightScreenCaptureAccess`. The poll does double duty: it flips
/// the checkmarks in the UI *and* fires `onGrantsChanged` so `AppState` can retry activating
/// features. `CGEvent.tapCreate` fails outright while untrusted, so without that retry, granting
/// permission appears to do nothing until relaunch.
///
/// **One timer, both grants.** A second timer would double the wakeups on an app that is idle
/// almost all the time, for no benefit — the two are read together in a single `refresh()`.
///
/// **`init` must never prompt.** `CGPreflightScreenCaptureAccess()` is silent and safe here;
/// `CGRequestScreenCaptureAccess()` shows a system dialog and is not. `FeatureCategoryTests`
/// constructs a `PermissionsManager` inside the app-hosted test bundle, and a dialog there would
/// hang the run. Requesting is always an explicit call from a button.
final class PermissionsManager: ObservableObject {
    @Published private(set) var isTrusted: Bool
    @Published private(set) var canCaptureScreen: Bool

    /// Called on the main thread whenever any queryable grant changes, in either direction.
    var onGrantsChanged: (() -> Void)?

    private var timer: Timer?
    private var scheduledInterval: TimeInterval?

    /// A missing grant means a banner or the onboarding screen is on display waiting for the
    /// checkmark to flip, so poll briskly. Once everything is granted, nothing is waiting — but
    /// keep polling slowly rather than stopping, because permission can be revoked at any time and
    /// an accessory app rarely becomes active, so there'd be no other moment to notice.
    private var desiredInterval: TimeInterval { (isTrusted && canCaptureScreen) ? 5.0 : 1.0 }

    init() {
        self.isTrusted = AXIsProcessTrusted()
        self.canCaptureScreen = CGPreflightScreenCaptureAccess()
    }

    func startMonitoring() {
        scheduleTimer()
    }

    private func scheduleTimer() {
        let interval = desiredInterval
        guard scheduledInterval != interval else { return }
        timer?.invalidate()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // .common so polling continues while a menu is open — the dropdown is exactly where
        // the user watches for the checkmark to flip.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        self.scheduledInterval = interval
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        scheduledInterval = nil
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        let capture = CGPreflightScreenCaptureAccess()
        guard trusted != isTrusted || capture != canCaptureScreen else { return }
        isTrusted = trusted
        canCaptureScreen = capture
        onGrantsChanged?()
        // A grant changed, so the right cadence changed with it.
        scheduleTimer()
    }

    /// Shows macOS's own "grant access" alert. It only appears once per app per install;
    /// afterwards this is a no-op, which is why `openSystemSettings()` is always offered
    /// alongside it.
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
    }

    /// Shows the Screen Recording alert. Like the Accessibility one it appears once per app per
    /// install, and it **returns false even when the user then grants it** — the answer describes
    /// this process, which cannot be given the grant retroactively. Treat the return value as
    /// "can I capture right now", never as "did the user say yes".
    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    func openSystemSettings() {
        openSystemSettings(for: .accessibility)
    }

    func openSystemSettings(for requirement: Requirement) {
        NSWorkspace.shared.open(requirement.settingsURL)
    }

    /// Whether a requirement is satisfied.
    ///
    /// **Only meaningful for requirements the system lets us ask about.** Audio capture has no such
    /// API, so this reports it as met and the feature that needs it detects denial by noticing it
    /// heard nothing — gating on an answer we cannot obtain would disable the feature permanently.
    func isGranted(_ requirement: Requirement) -> Bool {
        switch requirement {
        case .accessibility: return isTrusted
        case .screenRecording: return canCaptureScreen
        case .audioCapture: return true
        }
    }
}
