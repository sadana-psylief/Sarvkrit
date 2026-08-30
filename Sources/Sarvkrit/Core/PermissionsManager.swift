import ApplicationServices
import AppKit
import Combine
import Foundation

/// Tracks the Accessibility (TCC) grant.
///
/// There is no notification for this — the only way to know is to poll `AXIsProcessTrusted`.
/// The poll does double duty: it flips the checkmark in the UI *and* fires `onTrustChanged`
/// so `AppState` can retry activating features. `CGEvent.tapCreate` fails outright while
/// untrusted, so without that retry, granting permission appears to do nothing until relaunch.
final class PermissionsManager: ObservableObject {
    @Published private(set) var isTrusted: Bool

    /// Called on the main thread whenever trust flips, in either direction.
    var onTrustChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var scheduledInterval: TimeInterval?

    /// Untrusted means a banner or the onboarding screen is on display waiting for the checkmark
    /// to flip, so poll briskly. Once granted, nothing is waiting — but keep polling slowly rather
    /// than stopping, because permission can be revoked at any time and an accessory app rarely
    /// becomes active, so there'd be no other moment to notice.
    private var desiredInterval: TimeInterval { isTrusted ? 5.0 : 1.0 }

    init() {
        self.isTrusted = AXIsProcessTrusted()
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
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        onTrustChanged?(trusted)
        // Trust changed, so the right cadence changed with it.
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

    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
