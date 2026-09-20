import CoreGraphics
import Foundation

/// How much the recorded pointer path is tidied before it is drawn.
///
/// Raw values are persisted in the project.
enum CursorSmoothing: String, Codable, CaseIterable, Equatable {
    /// The raw path. **Genuinely off**, not "a bit less" — a drawing app, or a demo of precise
    /// dragging, is made worse by any smoothing at all, and the setting has to mean what it says.
    case off
    case light
    case standard
    case heavy

    var title: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .standard: return "Standard"
        case .heavy: return "Heavy"
        }
    }

    /// Width of the smoothing kernel, in samples.
    fileprivate var sigma: Double {
        switch self {
        case .off: return 0
        case .light: return 0.6
        case .standard: return 1.2
        case .heavy: return 2.4
        }
    }
}

/// Turning the recorded pointer path into one that looks like it has weight.
///
/// Pure, over an array of samples — no AV types, no drawing. Everything here is *offline*
/// post-processing, which is worth stating because it changes what the right algorithm is: a live
/// filter can only look backwards and therefore always lags, but we hold the entire path before we
/// draw a single frame, so a **zero-phase symmetric filter** is available and is strictly better.
/// The realtime answer would smooth the jitter and arrive late; this one does not arrive late.
enum CursorPath {

    /// How near a click the smoother is suspended, in seconds.
    ///
    /// **The tension this whole type exists to resolve.** Smoothing removes hand jitter that is
    /// invisible at 1× and obvious at 2.5×; smoothing is also lag. A cursor that arrives after the
    /// click it made looks like the app mis-clicked, which is far worse than any amount of jitter
    /// — so around a click the raw position wins outright and blends back out.
    static let clickSnapWindow: TimeInterval = 0.12

    // MARK: - Smoothing

    static func smoothed(_ samples: [CursorSample],
                         smoothing: CursorSmoothing,
                         snappingTo clickTimes: [TimeInterval] = []) -> [CursorSample] {
        guard smoothing != .off, samples.count > 2 else { return samples }

        let kernel = gaussian(sigma: smoothing.sigma)
        var result = samples

        for index in samples.indices {
            var sumX = 0.0, sumY = 0.0, sumWeight = 0.0
            for (offset, weight) in kernel {
                let point = reflected(samples, around: index, offset: offset)
                sumX += Double(point.x) * weight
                sumY += Double(point.y) * weight
                sumWeight += weight
            }
            var point = CGPoint(x: sumX / sumWeight, y: sumY / sumWeight)

            if let snap = snapWeight(at: samples[index].t, clickTimes: clickTimes), snap > 0 {
                let raw = samples[index].point
                point = CGPoint(x: raw.x * CGFloat(snap) + point.x * CGFloat(1 - snap),
                                y: raw.y * CGFloat(snap) + point.y * CGFloat(1 - snap))
            }
            result[index].point = point
        }
        return result
    }

    private static func gaussian(sigma: Double) -> [(offset: Int, weight: Double)] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        return (-radius...radius).map { offset in
            (offset, exp(-Double(offset * offset) / (2 * sigma * sigma)))
        }
    }

    /// Odd reflection past either end: `p[-k] = 2·p[0] − p[k]`.
    ///
    /// Chosen over repeating the edge sample because it is **exact for a straight path** — the
    /// reflection continues the line rather than flattening it — so a pointer moving steadily
    /// across the screen is not dragged off course in its first and last few frames, which is
    /// precisely where a viewer's eye is when a clip begins.
    private static func reflected(_ samples: [CursorSample], around index: Int,
                                  offset: Int) -> CGPoint {
        let target = index + offset
        if target >= 0 && target < samples.count { return samples[target].point }
        if target < 0 {
            let mirrored = samples[min(-target, samples.count - 1)].point
            let anchor = samples[0].point
            return CGPoint(x: 2 * anchor.x - mirrored.x, y: 2 * anchor.y - mirrored.y)
        }
        let last = samples.count - 1
        let mirrored = samples[max(0, 2 * last - target)].point
        let anchor = samples[last].point
        return CGPoint(x: 2 * anchor.x - mirrored.x, y: 2 * anchor.y - mirrored.y)
    }

    /// 1 exactly on a click, easing to 0 at the edge of the window.
    private static func snapWeight(at t: TimeInterval, clickTimes: [TimeInterval]) -> Double? {
        var best: Double?
        for click in clickTimes {
            let distance = abs(t - click)
            guard distance < clickSnapWindow else { continue }
            let unit = 1 - distance / clickSnapWindow
            // Smoothstep, so the blend has no visible corner where it starts and stops.
            let weight = unit * unit * (3 - 2 * unit)
            best = max(best ?? 0, weight)
        }
        return best
    }

    // MARK: - Shakes

    struct ShakeTuning: Equatable {
        /// Direction reversals needed inside `window` before a span counts as a shake.
        var reversals: Int = 4
        var window: TimeInterval = 0.35
        /// A shake stays roughly in one place; a genuine fast scribble does not.
        var radius: CGFloat = 260

        init() {}
    }

    /// Removes the zigzag macOS's shake-to-locate gesture leaves in the path.
    ///
    /// The pointer's *size* never reaches us — a recognised cursor is redrawn from vector paths,
    /// so the system's enlargement is not in the recording. The **path** does reach us, and left
    /// alone it makes `ZoomPlanner` read a burst of activity where nothing happened while the
    /// smoother chases a target moving 2,000 px a second.
    static func removingShakes(_ samples: [CursorSample],
                               tuning: ShakeTuning = ShakeTuning()) -> [CursorSample] {
        guard samples.count > 4 else { return samples }

        var spans: [ClosedRange<Int>] = []
        var index = 1
        while index < samples.count - 1 {
            guard let end = shakeEnd(from: index, in: samples, tuning: tuning) else {
                index += 1
                continue
            }
            spans.append(index...end)
            index = end + 1
        }
        guard !spans.isEmpty else { return samples }

        // Straight-line replacement rather than heavier smoothing: a shake carries no information
        // about where the user meant to be, so there is nothing in it worth preserving.
        var result = samples
        for span in spans {
            let from = samples[max(0, span.lowerBound - 1)].point
            let to = samples[min(samples.count - 1, span.upperBound + 1)].point
            let steps = span.count + 1
            for (step, position) in span.enumerated() {
                let fraction = CGFloat(step + 1) / CGFloat(steps)
                result[position].point = CGPoint(x: from.x + (to.x - from.x) * fraction,
                                                 y: from.y + (to.y - from.y) * fraction)
            }
        }
        return result
    }

    /// The last index of a shake beginning at `start`, or nil if there is not one.
    private static func shakeEnd(from start: Int, in samples: [CursorSample],
                                 tuning: ShakeTuning) -> Int? {
        var reversals = 0
        var lastSign = 0
        var minX = samples[start].point.x, maxX = minX
        var minY = samples[start].point.y, maxY = minY
        var end: Int?

        var index = start
        while index < samples.count - 1, samples[index].t - samples[start].t <= tuning.window {
            let delta = samples[index + 1].point.x - samples[index].point.x
            let sign = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
            if sign != 0 {
                if lastSign != 0 && sign != lastSign { reversals += 1 }
                lastSign = sign
            }
            let point = samples[index + 1].point
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)

            if reversals >= tuning.reversals,
               maxX - minX <= tuning.radius, maxY - minY <= tuning.radius {
                end = index + 1
            }
            index += 1
        }
        return end
    }

    // MARK: - Looping

    /// Eases the pointer back to where it started over the last `seconds` of the recording.
    ///
    /// For a clip meant to loop — a demo GIF, a landing-page hero — a cursor that ends far from
    /// where it began makes the seam obvious. A render-time transform only: the events are
    /// untouched, so this can be switched off again.
    static func looped(_ samples: [CursorSample], over seconds: TimeInterval) -> [CursorSample] {
        guard seconds > 0, samples.count > 1,
              let first = samples.first, let last = samples.last else { return samples }
        let tailStart = last.t - seconds
        guard tailStart > first.t else { return samples }

        var result = samples
        for index in samples.indices where samples[index].t >= tailStart {
            let progress = (samples[index].t - tailStart) / seconds
            let eased = CGFloat(ZoomEase.smooth.value(progress))
            let point = samples[index].point
            result[index].point = CGPoint(x: point.x + (first.point.x - point.x) * eased,
                                          y: point.y + (first.point.y - point.y) * eased)
        }
        return result
    }
}
