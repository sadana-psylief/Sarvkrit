import Foundation

/// Per-app volumes, remembered by bundle ID.
///
/// Bundle ID rather than pid, because a pid is meaningless the moment the app restarts — the point
/// of persistence is that Slack stays at 40% next week, not until lunchtime.
///
/// Pure and injectable, so the awkward parts — clamping, what counts as "set", the fact that most
/// apps have no level at all — are a test table.
struct MixerLevels {
    static let minimum: Float = 0
    /// The ceiling on boost: 200%.
    ///
    /// Not higher, and the limit is the material rather than the arithmetic. Most audio is mastered
    /// with a few dB of headroom, so doubling it is the range where a quiet video becomes usable
    /// without the soft clipper doing much work. Past that the clipper is shaping most of the
    /// waveform most of the time, and the result is louder in the way a distorted radio is louder.
    static let maximum: Float = 2

    static let range: ClosedRange<Float> = minimum...maximum

    /// Everything the user has ever set a level for.
    private(set) var levels: [String: Float]

    private let defaults: UserDefaults
    private static let key = "sound.mixerLevels"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        levels = stored.mapValues { Float($0) }
    }

    /// The level for an app. **Full volume when nothing has been set** — an app the user has never
    /// touched must never be quieter *or louder* than it would have been without this feature.
    func level(for bundleID: String) -> Float {
        levels[bundleID] ?? 1
    }

    /// Whether the user has deliberately set this app's level, as opposed to it merely defaulting
    /// to full. The pane uses it to list what has been changed, so nothing is quietly attenuated
    /// somewhere the user can't find it.
    func hasCustomLevel(for bundleID: String) -> Bool {
        levels[bundleID] != nil
    }

    mutating func setLevel(_ level: Float, for bundleID: String) {
        let clamped = min(Self.maximum, max(Self.minimum, level))
        // Full volume is the absence of a setting, not a setting of 1 — otherwise the "apps you
        // have changed" list fills up with apps you set back to normal.
        //
        // This now tests for *exactly* unity rather than "1 or more". When the ceiling was 1 the
        // two were the same thing; with boost they are not, and the old test would have thrown
        // away every boost the moment it was set — silently, since the app would simply play at
        // normal volume.
        if clamped == 1 {
            guard levels[bundleID] != nil else { return }
            levels.removeValue(forKey: bundleID)
        } else {
            guard levels[bundleID] != clamped else { return }
            levels[bundleID] = clamped
        }
        save()
    }

    mutating func reset(_ bundleID: String) {
        guard levels[bundleID] != nil else { return }
        levels.removeValue(forKey: bundleID)
        save()
    }

    mutating func resetAll() {
        guard !levels.isEmpty else { return }
        levels.removeAll()
        save()
    }

    private func save() {
        defaults.set(levels.mapValues { Double($0) }, forKey: Self.key)
    }
}
