import CoreGraphics
import Foundation

/// What the All-In-One picker had selected last time.
///
/// The point of remembering is the retake: take a shot, notice it was one pixel off, press the
/// shortcut and the same mode and size are already there.
struct CaptureModeMemory: Equatable {
    var mode: CaptureMode
    /// Pixels, or nil when the last selection was freehand.
    var pixelSize: CGSize?
    var aspectLocked: Bool

    static let fallback = CaptureModeMemory(mode: .area, pixelSize: nil, aspectLocked: false)

    // MARK: - Persistence

    private enum Key {
        static let mode = "screenshot.lastMode"
        static let width = "screenshot.lastWidth"
        static let height = "screenshot.lastHeight"
        static let aspect = "screenshot.lastAspectLocked"
    }

    /// A persisted mode that no longer exists falls back rather than crashing.
    ///
    /// It can happen for real: a mode removed in a later version leaves its raw value in a
    /// UserDefaults that outlives the build that wrote it.
    static func load(from defaults: UserDefaults) -> CaptureModeMemory {
        let mode = defaults.string(forKey: Key.mode)
            .flatMap(CaptureMode.init(rawValue:)) ?? fallback.mode
        let width = defaults.object(forKey: Key.width) as? Double
        let height = defaults.object(forKey: Key.height) as? Double
        // Both or neither: half a remembered size is not a size.
        let size: CGSize? = {
            guard let width, let height, width > 0, height > 0 else { return nil }
            return CGSize(width: width, height: height)
        }()
        return CaptureModeMemory(mode: mode, pixelSize: size,
                                 aspectLocked: defaults.bool(forKey: Key.aspect))
    }

    func save(to defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: Key.mode)
        if let pixelSize {
            defaults.set(Double(pixelSize.width), forKey: Key.width)
            defaults.set(Double(pixelSize.height), forKey: Key.height)
        } else {
            defaults.removeObject(forKey: Key.width)
            defaults.removeObject(forKey: Key.height)
        }
        defaults.set(aspectLocked, forKey: Key.aspect)
    }
}

/// The self-timer countdown.
///
/// Pure so cancel-mid-countdown and a clock that jumps are tests rather than things you sit
/// through.
enum Countdown {
    enum State: Equatable {
        case counting(secondsLeft: Int)
        case fired
    }

    static func state(now: Date, startedAt: Date, duration: TimeInterval) -> State {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed < duration else { return .fired }
        // Ceil, so a 3-second timer reads "3" for its first second rather than flashing 2
        // immediately — the number shown is how many seconds are *left*, not how many have gone.
        let left = Int((duration - elapsed).rounded(.up))
        // A clock that jumps backwards must not show more than the timer was set for.
        return .counting(secondsLeft: min(max(left, 1), Int(duration.rounded(.up))))
    }
}
