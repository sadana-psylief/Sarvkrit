import CoreGraphics
import Foundation

/// How pressed keys are shown.
struct KeystrokeSettings: Codable, Equatable {
    /// Off until asked. Watching the keyboard is a decision, not a discovery.
    var isEnabled = false
    /// **The default: combinations only.** ⌘C and ⌃⇧R are what a demo needs to show; putting every
    /// letter somebody types on screen is a much larger promise about what is being recorded.
    var showsBareKeys = false
    var corner: CaptureBackground.Alignment = .bottomTrailing
    var sizeFraction: Double = 0.035
    var holdSeconds: TimeInterval = 1.6
    var fadeSeconds: TimeInterval = 0.25
    /// A wall of pills is worse than the last few.
    var maximumPills = 5

    init() {}
}

/// Turning the keystroke log into the pills on screen at one instant.
enum KeystrokeOverlay {

    struct Pill: Equatable, Identifiable {
        var id: String { "\(label)-\(firstPressed)" }
        var label: String
        var firstPressed: TimeInterval
        /// Repeats collapse into a count rather than stacking, which is noise rather than
        /// information.
        var repeatCount: Int
        var opacity: Double
    }

    static func pills(at t: TimeInterval, keys: [KeyEvent],
                      settings: KeystrokeSettings) -> [Pill] {
        let window = settings.holdSeconds + settings.fadeSeconds
        let live = keys.filter { key in
            guard key.t <= t, t - key.t <= window else { return false }
            return settings.showsBareKeys || key.isModifierCombination
        }
        guard !live.isEmpty else { return [] }

        var pills: [Pill] = []
        for key in live {
            // Collapsed against the previous pill only, so ⌘C ⌘V ⌘C reads as three presses rather
            // than being merged into two.
            if var last = pills.last, last.label == key.label {
                last.repeatCount += 1
                last.opacity = opacity(at: t, pressed: key.t, settings: settings)
                pills[pills.count - 1] = last
            } else {
                pills.append(Pill(label: key.label, firstPressed: key.t, repeatCount: 1,
                                  opacity: opacity(at: t, pressed: key.t, settings: settings)))
            }
        }
        return Array(pills.suffix(settings.maximumPills))
    }

    private static func opacity(at t: TimeInterval, pressed: TimeInterval,
                                settings: KeystrokeSettings) -> Double {
        let age = t - pressed
        guard age > settings.holdSeconds else { return 1 }
        guard settings.fadeSeconds > 0 else { return 0 }
        return max(0, 1 - (age - settings.holdSeconds) / settings.fadeSeconds)
    }
}
