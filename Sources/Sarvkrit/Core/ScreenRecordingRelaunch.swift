import AppKit
import Foundation

/// Getting the app restarted after a Screen Recording grant.
///
/// **Why this exists at all.** Accessibility flips live: `AXIsProcessTrusted()` starts returning
/// true and `AppState.sync()` retries activation, so the user grants it and everything lights up.
/// Screen Recording does not work that way. `CGRequestScreenCaptureAccess()` adds the app to the
/// list and returns false, and *this process* keeps being refused — ScreenCaptureKit reports zero
/// displays, or hands back black images. There is no API to re-ask. The only way through is a
/// restart, so the app has to offer one instead of showing a spinner that never resolves.
///
/// **The detection is indirect on purpose.** macOS gives no "you were granted this after you
/// launched" signal. What it gives is a contradiction: the preflight says granted, and a capture
/// comes back with nothing in it. That pair means the grant landed after launch.
enum ScreenRecordingRelaunch {

    /// Whether a failed capture looks like a grant this process can't use yet.
    ///
    /// Pure, so the rule is a test rather than something you reproduce by revoking a real TCC
    /// grant. Deliberately narrow: a capture that returns *some* displays is working, and a
    /// preflight that says no is an ordinary ungranted state the banner already covers.
    static func looksLikeStaleGrant(preflightGranted: Bool, capturedDisplayCount: Int) -> Bool {
        preflightGranted && capturedDisplayCount == 0
    }

    /// Quits and comes back.
    ///
    /// **`open -a Sarvkrit` from inside Sarvkrit does not work.** `LSMultipleInstancesProhibited`
    /// plus `SingleInstance.swift` means LaunchServices reactivates the copy that is already
    /// running rather than starting a new one — so the relaunch would be a no-op and the user
    /// would be told to restart an app that refuses to. Handing the job to a detached shell that
    /// waits for this process to die is the way around it.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The sleep outlives us: by the time it fires there is no running copy for LaunchServices
        // to reactivate, so `open` genuinely starts one.
        task.arguments = ["-c", "sleep 1; open -a \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
