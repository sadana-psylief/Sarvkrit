import Foundation

/// Whether Music launching itself was the user's doing.
///
/// The whole difficulty of this feature is that a launch looks identical either way: the same
/// notification arrives whether Apple Music was opened from the Dock or barged in because a pair of
/// headphones connected. Quitting every launch would make the app impossible to use deliberately,
/// which the user explicitly does not want.
///
/// The tell is **what just happened to the audio hardware**. Music appearing within a second or two
/// of a device connecting was almost certainly triggered by it; Music appearing out of a quiet
/// stretch was almost certainly a person. Pure, so the window and its edges are a test table rather
/// than a number tuned by plugging headphones in over and over.
enum MusicLaunchDecision {

    /// How close a device change has to be to count as the cause.
    ///
    /// Short on purpose. macOS launches Music promptly on connect, so a longer window buys almost
    /// nothing and steadily raises the chance of swallowing a launch the user meant — which is the
    /// error that actually annoys, since the app then seems broken.
    static let window: TimeInterval = 3

    enum Verdict: Equatable {
        case allow
        case block
    }

    /// - Parameters:
    ///   - launchedAt: when the app appeared.
    ///   - lastDeviceChange: when an audio device last connected or disconnected, if ever.
    static func verdict(
        launchedAt: Date,
        lastDeviceChange: Date?,
        window: TimeInterval = MusicLaunchDecision.window
    ) -> Verdict {
        guard let lastDeviceChange else { return .allow }

        let elapsed = launchedAt.timeIntervalSince(lastDeviceChange)
        // A launch *before* the device change can't have been caused by it. Negative elapsed time
        // happens when the two arrive close together and out of order, which they do.
        guard elapsed >= 0, elapsed <= window else { return .allow }
        return .block
    }

    /// Apple Music, and the iTunes it replaced — a Mac old enough to have been upgraded in place
    /// still has the older bundle identifier.
    static let musicBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.apple.iTunes",
    ]

    static func isMusic(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return musicBundleIDs.contains(bundleID)
    }
}
