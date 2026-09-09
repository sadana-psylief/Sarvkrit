import Foundation

/// How black the frame should be, at a moment in the finished video.
///
/// **One curtain for three features.** A fade up from black at the start, a fade down at the end,
/// and a dip to black at a cut are all the same wash at different times, so they are one piece of
/// arithmetic rather than three.
///
/// **Dip-to-black rather than crossfade, and that is a deliberate limit.** A crossfade needs the
/// outgoing *and* incoming frames at once, which means a second decoder in the player and buffering
/// in the exporter. A dip needs the one frame it already has, and it is honest about being a cut.
enum FadeCurtain {

    struct Dip: Equatable {
        /// Output time of the cut this dip is centred on.
        var at: TimeInterval
        /// Total length, half either side of the cut.
        var length: TimeInterval
    }

    /// 0 for no wash, 1 for solid black.
    static func alpha(atOutput t: TimeInterval, duration: TimeInterval,
                      fadeIn: TimeInterval, fadeOut: TimeInterval,
                      dips: [Dip] = []) -> Double {
        var darkest: Double = 0

        if fadeIn > 0, t < fadeIn {
            darkest = max(darkest, 1 - max(0, t) / fadeIn)
        }
        if fadeOut > 0, t > duration - fadeOut, duration > 0 {
            darkest = max(darkest, 1 - max(0, duration - t) / fadeOut)
        }
        for dip in dips where dip.length > 0 {
            let half = dip.length / 2
            let distance = abs(t - dip.at)
            guard distance < half else { continue }
            // Fully black at the cut itself, clear at either end of the dip.
            darkest = max(darkest, 1 - distance / half)
        }
        return min(1, max(0, darkest))
    }

    /// Where the dips fall, given the running order.
    ///
    /// A dip belongs to the clip that *starts* at the cut, which is the same convention
    /// `Timeline.sourceTime(forOutput:)` uses for the boundary itself. The first clip cannot have
    /// one: there is no cut before the beginning, and a fade in is the setting for that.
    static func dips(in timeline: Timeline) -> [Dip] {
        var result: [Dip] = []
        var elapsed: TimeInterval = 0
        for (index, clip) in timeline.clips.enumerated() {
            if index > 0, clip.dipToBlack > 0 {
                result.append(Dip(at: elapsed, length: clip.dipToBlack))
            }
            elapsed += clip.outputDuration
        }
        return result
    }
}
