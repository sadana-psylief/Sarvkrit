import CoreGraphics
import Foundation

/// Deciding where and when to zoom, from the event log alone.
///
/// **Taste as a pure function.** No video, no AV types, no main actor — the same shape
/// `AutoBalance` uses for "which background suits this screenshot", and for the same reason: the
/// judgement is the hard part, it needs iterating on, and it should be adjustable without touching
/// a line of anything that draws.
///
/// The rule the whole thing serves: **a zoom that ends before the eye has arrived is worse than no
/// zoom at all.** Most of the thresholds below exist to enforce that one idea.
enum ZoomPlanner {

    /// Every number the planner's judgement rests on, in one place with its reason.
    struct Tuning: Equatable {
        /// Clicks closer together than this in time join the same activity.
        var clusterInterval: TimeInterval = 1.5
        /// …and closer together than this in space. Chained, so a drag across the screen is one
        /// activity rather than a dozen.
        var clusterRadius: CGFloat = 200
        /// You look before you click.
        var leadIn: TimeInterval = 1.2
        /// …and at what happened after.
        var leadOut: TimeInterval = 0.8
        /// Shorter than this and the zoom is over before it registers.
        var minimumActivity: TimeInterval = 1.0
        /// Two activities closer than this are one zoom rather than two.
        ///
        /// **This used to be the guard against nausea and could not keep the promise.** Zooming
        /// out and straight back in is the worst thing this feature can do, but `maximumActivity`
        /// refuses the merge whenever the pair would overrun and then trims the second activity to
        /// start exactly where the first ends — manufacturing the very thing the merge was
        /// avoiding. The two rules were in direct conflict and the cap won.
        ///
        /// `ZoomResolver.joinGap` is what keeps the promise now: neighbouring segments resolve as
        /// one continuous move from one level to the next, so an abutting pair reads as a single
        /// adjustment. This is left as a framing choice — whether two nearby bursts deserve one
        /// shot or two — rather than as a defence.
        var mergeGap: TimeInterval = 0.8
        /// How much of the frame the activity should occupy once zoomed.
        var targetCoverage: Double = 0.6

        /// **The ceiling used to be 2.5 and almost everything reached it.** Two reasons to bring
        /// it down.
        ///
        /// A point-like activity — one click, or a typing run — has no extent to fit, so the
        /// coverage arithmetic below asks for an enormous number and takes whatever the maximum
        /// is. The maximum was doing the job of a default, which is how a recording ends up with
        /// four zooms at exactly the same level.
        ///
        /// And 2.5× is more magnification than the source can pay for. A 3024-wide recording
        /// cropped to 2.5× shows 1210 pixels; exported at its own native width those 1210 are
        /// stretched back over 3024, so the close-up is visibly softer than the shot around it.
        /// 2× keeps the crop nearer the output resolution, and matters more now that an export can
        /// be full size rather than always 1080p.
        ///
        /// Hand-made zooms are unaffected: `ZoomSegment.levelRange` still allows up to 4×, so
        /// anyone who wants a harder close-up can set one.
        var levelRange: ClosedRange<Double> = 1.2...2.0
        /// An activity that moves less than this fraction of the frame is pinned rather than
        /// followed — following something that barely moves reads as drift.
        var followThreshold: Double = 0.15
        /// At most one zoom per this many seconds. A click-heavy demo must not become a zoom storm.
        var minimumSpacing: TimeInterval = 4.0
        /// **The cap that stops a zoom becoming a crop.**
        ///
        /// Merging is what keeps a busy stretch from flickering, but merged far enough it produces
        /// one segment across the whole recording — which is not a zoom, it is a permanent change
        /// of framing, and it is what a real twelve-second demo of twenty-eight clicks produced
        /// before this existed.
        var maximumActivity: TimeInterval = 7.0
        /// A level this close to the floor is not a close-up, it is a slow drift. Below it the
        /// segment is dropped: barely zooming for eleven seconds is worse than not zooming.
        var levelFloorMargin: Double = 0.15
        /// Keystrokes needed before typing counts as an activity in its own right.
        /// How slowly the pointer has to be moving to count as attending to something, in
        /// fractions of the frame's width per second.
        ///
        /// **Where somebody moved the mouse from is not what they are showing you.** The cursor
        /// track is the signal the planner needs to judge how wide a shot to take, but most of it
        /// is transit — a fling across the screen to reach a button. Counting that would drag the
        /// box out to the full width and cancel the zoom on almost every click. Below this the
        /// pointer is working; above it, it is travelling.
        var dwellSpeedFraction: Double = 0.35
        var typingRun: Int = 5
        /// …with no gap longer than this between them.
        var typingInterval: TimeInterval = 2.0

        init() {}

        /// The longest a *cluster* may run, so that once the lead-in and lead-out are added the
        /// finished segment still respects `maximumActivity`.
        ///
        /// Capping the cluster at `maximumActivity` directly looks right and is not: the padding
        /// is applied afterwards, so a seven-second cluster becomes a nine-second segment and the
        /// limit quietly means something other than what it says.
        var clusterBudget: TimeInterval { max(0.5, maximumActivity - leadIn - leadOut) }
    }

    /// A span of the recording where something was happening, and where on screen it happened.
    private struct Activity {
        var start: TimeInterval
        var end: TimeInterval
        var points: [CGPoint]
    }

    static func plan(events: EventLog,
                     frameSize: CGSize,
                     duration: TimeInterval,
                     tuning: Tuning = Tuning()) -> [ZoomSegment] {
        guard frameSize.width > 0, frameSize.height > 0, duration > 0 else { return [] }

        var activities = clickActivities(events, tuning) + typingActivities(events, tuning)
        activities.sort { $0.start < $1.start }

        activities = activities.map { padded($0, duration: duration, tuning: tuning) }
            .filter { $0.end - $0.start >= tuning.minimumActivity }

        activities = merged(activities, tuning: tuning)

        // Dropped rather than kept-but-weak. A zoom that barely magnifies still costs the viewer
        // a movement to follow, and pays nothing back.
        //
        // Judged on the *tight* box — was there a specific thing here — rather than on the shot
        // the pointer widened it to. Otherwise a slow sweep around a button deletes the zoom onto
        // the button, which is widening a shot into no shot at all.
        return activities
            .map { segment(for: $0, events: events, frameSize: frameSize, tuning: tuning) }
            .filter { $0.tightLevel > tuning.levelRange.lowerBound + tuning.levelFloorMargin }
            .map(\.segment)
    }

    // MARK: - Finding activities

    /// Chained clustering: a click joins the run if it is close to the *previous* click, not to the
    /// run's first. That is what makes a drag across the screen one activity — measuring from the
    /// start would break it into pieces at the radius boundary.
    private static func clickActivities(_ events: EventLog, _ tuning: Tuning) -> [Activity] {
        let presses = events.pressDowns.filter(\.isInside)
        guard !presses.isEmpty else { return [] }

        var activities: [Activity] = []
        var current = Activity(start: presses[0].t, end: presses[0].t, points: [presses[0].point])

        for press in presses.dropFirst() {
            let previous = current.points[current.points.count - 1]
            let apart = hypot(press.point.x - previous.x, press.point.y - previous.y)
            let wouldOverrun = press.t - current.start > tuning.clusterBudget
            if press.t - current.end <= tuning.clusterInterval,
               apart <= tuning.clusterRadius,
               !wouldOverrun {
                current.end = press.t
                current.points.append(press.point)
            } else {
                activities.append(current)
                current = Activity(start: press.t, end: press.t, points: [press.point])
            }
        }
        activities.append(current)
        return activities
    }

    /// Typing is activity too.
    ///
    /// Filling in a form or writing code produces no clicks at all, and a planner that only watches
    /// the mouse ignores the most common thing in a software demo. Anchored where the caret most
    /// likely is: the pointer, since that is where the user last put it.
    private static func typingActivities(_ events: EventLog, _ tuning: Tuning) -> [Activity] {
        guard events.keys.count >= tuning.typingRun else { return [] }

        var runs: [[KeyEvent]] = []
        var current: [KeyEvent] = [events.keys[0]]
        for key in events.keys.dropFirst() {
            if key.t - (current.last?.t ?? key.t) <= tuning.typingInterval {
                current.append(key)
            } else {
                runs.append(current)
                current = [key]
            }
        }
        runs.append(current)

        return runs.filter { $0.count >= tuning.typingRun }.map { run in
            let start = run[0].t
            let end = run[run.count - 1].t
            let point = events.cursorPoint(at: (start + end) / 2)
            return Activity(start: start, end: end, points: point.map { [$0] } ?? [])
        }
    }

    // MARK: - Shaping

    private static func padded(_ activity: Activity, duration: TimeInterval,
                               tuning: Tuning) -> Activity {
        var padded = activity
        padded.start = max(0, activity.start - tuning.leadIn)
        padded.end = min(duration, activity.end + tuning.leadOut)
        return padded
    }

    /// Two passes, and they enforce different rules.
    ///
    /// The first closes gaps shorter than `mergeGap` — an out-and-straight-back-in. The second is
    /// the density cap: even well-separated activities are merged if they *start* closer together
    /// than `minimumSpacing`, which is what keeps a busy demo from zooming every two seconds.
    private static func merged(_ activities: [Activity], tuning: Tuning) -> [Activity] {
        guard var previous = activities.first else { return [] }
        var result: [Activity] = []

        for activity in activities.dropFirst() {
            let touches = activity.start - previous.end < tuning.mergeGap
            let tooSoon = activity.start - previous.start < tuning.minimumSpacing
            // Whatever the other two say, a merge that would push the span past `maximumActivity`
            // is refused. Without this the rules compose into "merge everything".
            let wouldOverrun = max(previous.end, activity.end) - previous.start
                > tuning.maximumActivity

            if (touches || tooSoon) && !wouldOverrun {
                previous.end = max(previous.end, activity.end)
                previous.points.append(contentsOf: activity.points)
                continue
            }

            // **Refusing to merge is not enough on its own.** The lead-in and lead-out are added
            // before this runs, so two activities two seconds apart already overlap by the time
            // they get here — and leaving them overlapping is worse than merging, because the
            // renderer would pick one arbitrarily and the zoom would flicker between them.
            // So the later one starts where the earlier one ends.
            var trimmed = activity
            trimmed.start = max(trimmed.start, previous.end)
            guard trimmed.end - trimmed.start >= tuning.minimumActivity else { continue }

            result.append(previous)
            previous = trimmed
        }
        result.append(previous)
        return result
    }

    /// **Two boxes, because "is this worth zooming to" and "how wide a shot" are different
    /// questions.**
    ///
    /// The tight box is the clicks: it says whether there is a specific thing here at all, and it
    /// is what the drop filter in `plan` judges. The shot box adds wherever the pointer *rested*
    /// during the activity: it says how much has to stay in frame. Judging both from one box meant
    /// that widening a shot could delete it — measured against real recordings, feeding the cursor
    /// into a single box removed two zooms outright and changed no level by more than 0.03.
    ///
    /// Either way the rule is the same: zoom until the box fills `targetCoverage` of the frame and
    /// no further. A drag across half the screen gets almost nothing, because zooming into it
    /// would hide half of itself.
    private static func segment(for activity: Activity, events: EventLog, frameSize: CGSize,
                                tuning: Tuning) -> (segment: ZoomSegment, tightLevel: Double) {
        let tight = bounds(of: activity.points, frameSize: frameSize)
        let shot = bounds(of: activity.points
                            + dwellPoints(in: activity, events: events, frameSize: frameSize,
                                          tuning: tuning),
                          frameSize: frameSize)

        let travel = max(Double(shot.width) / Double(frameSize.width),
                         Double(shot.height) / Double(frameSize.height))
        let anchor: ZoomSegment.Anchor = travel > tuning.followThreshold
            ? .followCursor
            : .fixed(CGPoint(x: shot.midX / frameSize.width, y: shot.midY / frameSize.height))

        // **Widening must not turn the shot into a drift.** The floor of the range is where a zoom
        // stops being a close-up and becomes a slow movement the viewer follows for nothing — the
        // thing `testAWideActivityGetsNoZoomAtAll` exists to prevent. The pointer may open the
        // shot up, but only as far as still-a-zoom.
        let usable = tuning.levelRange.lowerBound + tuning.levelFloorMargin
        let shotLevel = max(level(fitting: shot, frameSize: frameSize, tuning: tuning), usable)

        let segment = ZoomSegment(start: activity.start, end: activity.end,
                                  level: shotLevel, anchor: anchor, isAutomatic: true)
        // The tight level travels alongside rather than on the segment: it is what the planner
        // used to decide, not something a saved project should carry.
        return (segment, level(fitting: tight, frameSize: frameSize, tuning: tuning))
    }

    /// The zoom that makes `box` fill `targetCoverage` of the frame, inside the allowed range.
    ///
    /// Guarded against zero: a single point would divide by nothing, and the answer wanted in that
    /// case — as close as the range allows — falls out of the clamp.
    private static func level(fitting box: CGRect, frameSize: CGSize, tuning: Tuning) -> Double {
        let byWidth = tuning.targetCoverage * Double(frameSize.width) / Double(max(box.width, 1))
        let byHeight = tuning.targetCoverage * Double(frameSize.height) / Double(max(box.height, 1))
        return min(max(min(byWidth, byHeight), tuning.levelRange.lowerBound),
                   tuning.levelRange.upperBound)
    }

    /// The cursor positions inside an activity where the pointer was attending rather than
    /// travelling.
    ///
    /// Speed is the whole distinction, and it is measured against the frame's own width so that a
    /// Retina capture and a small window mean the same thing by "fast". A sample the recorder
    /// marked as outside the recorded region is not evidence about anything on screen — the same
    /// rule the click path already applies with its own `isInside`.
    private static func dwellPoints(in activity: Activity, events: EventLog,
                                    frameSize: CGSize, tuning: Tuning) -> [CGPoint] {
        let samples = events.cursor.filter {
            $0.t >= activity.start && $0.t <= activity.end && $0.isInside
        }
        guard samples.count > 1 else { return samples.map(\.point) }

        let limit = tuning.dwellSpeedFraction * Double(frameSize.width)
        return samples.enumerated().compactMap { index, sample in
            // Forward difference, and backwards for the last one, so every sample has a speed.
            let other = index + 1 < samples.count ? samples[index + 1] : samples[index - 1]
            let seconds = abs(other.t - sample.t)
            guard seconds > 0.0001 else { return sample.point }
            let travelled = hypot(other.point.x - sample.point.x, other.point.y - sample.point.y)
            return Double(travelled) / seconds <= limit ? sample.point : nil
        }
    }

    private static func bounds(of points: [CGPoint], frameSize: CGSize) -> CGRect {
        guard let first = points.first else {
            return CGRect(x: frameSize.width / 2, y: frameSize.height / 2, width: 0, height: 0)
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
