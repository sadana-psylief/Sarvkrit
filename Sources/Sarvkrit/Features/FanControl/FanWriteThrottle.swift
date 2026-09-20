import Foundation

/// Decides whether a command is worth sending.
///
/// The loop runs every two seconds for as long as the feature is on, and most ticks decide exactly
/// what the last one did. Writing regardless would be thousands of pointless round trips an hour
/// to firmware on a serialised coprocessor.
///
/// The asymmetry is deliberate: **taking hold of a fan and letting go of one are never delayed.**
/// Those are the safety transitions, and a rate limit in front of the hard ceiling would be a bug
/// with a plausible-looking excuse.
struct FanWriteThrottle {
    var minimumInterval: TimeInterval = 2
    /// Below this, a speed change is not worth a write. A fan cannot meaningfully distinguish one
    /// percent of its range anyway.
    var percentEpsilon: Double = 2

    func shouldWrite(_ command: FanCommand,
                     lastWritten: FanCommand?,
                     lastWriteAt: Date?,
                     now: Date) -> Bool {
        guard let lastWritten, let lastWriteAt else { return true }

        switch (command, lastWritten) {
        case let (.hold(new), .hold(old)):
            guard abs(new - old) >= percentEpsilon else { return false }
            return now.timeIntervalSince(lastWriteAt) >= minimumInterval
        case (.release, .release):
            // Still released. The reason may have changed — cooled off rather than over the
            // ceiling — but the instruction to the fan is identical, so there is nothing to send.
            return false
        default:
            // Hold to release, or release to hold. Always, and now.
            return true
        }
    }
}
