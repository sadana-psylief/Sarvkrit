import CoreGraphics
import Foundation

/// How the screen layer is framed at one instant.
struct ZoomTransform: Equatable {
    /// 1 means the whole recording.
    var scale: Double = 1
    /// Normalised 0…1, and always already clamped so the visible rectangle is inside the frame.
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Whether the frame is travelling.
    ///
    /// **Nothing reads this yet.** It claimed the renderer blurs while it is true, and the
    /// renderer does not — there is no motion blur in the compositor at all. Kept, because it is
    /// the honest answer to a question only the resolver can answer, and because a held join now
    /// depends on the distinction: the frame between two joined segments is standing still rather
    /// than moving. The claim is removed rather than the field.
    var isMoving = false

    static let identity = ZoomTransform()
}

/// Resolving the zoom track into the one transform a frame is drawn with.
///
/// Pure over the segments, and separate from anything that draws, so the whole of the framing
/// behaviour can be asserted without a pixel.
enum ZoomResolver {

    /// Fraction of the frame the pointer may wander inside before the view follows it.
    ///
    /// **Without a dead zone, following is drift.** A pointer that twitches while somebody talks
    /// would slide the whole picture, and over a five-minute demo that is what makes people feel
    /// seasick. Inside the zone the frame is perfectly still.
    static let deadZone: Double = 0.25

    /// How close two segments have to be to become one continuous move.
    ///
    /// **Under this, the frame holds; over it, it zooms out and back in.** Both answers are right
    /// for different gaps. A tenth of a second of identity between a 2.5× shot and a 1.4× one is
    /// the "weird animation" — the picture travelling somewhere neither zoom asked to go — but
    /// holding a close-up across three seconds of nothing happening is worse than the dip, because
    /// the shot never breathes. A second is about where a pause stops reading as a pause.
    static let joinGap: TimeInterval = 1.0

    /// - Parameter clipSource: the source range of the clip this frame came from, if the caller
    ///   knows it — which `Timeline.sourceTime(forOutput:)` always does, since it returns the clip
    ///   alongside the time.
    ///
    ///   **Source time is not monotonic in output time once the edit has a cut in it.** The frame
    ///   after a boundary can come from anywhere in the recording, so a ramp measured from the
    ///   segment's own end is still mid-flight when the picture jumps, and the zoom pops. Ramping
    ///   against the segment's *intersection with the clip* makes it ease out at the cut instead.
    static func transform(at t: TimeInterval,
                          segments: [ZoomSegment],
                          cursor: CGPoint?,
                          frameSize: CGSize,
                          clipSource: Range<TimeInterval>? = nil) -> ZoomTransform {
        guard frameSize.width > 0, frameSize.height > 0 else { return .identity }

        // **Sorted, because the neighbours are what this function is now about.** Segments reach
        // here in whatever order the project holds them, and `redetectZooms` concatenates
        // hand-made ones onto planned ones without merging, so array order is not time order.
        let live = segments.filter { !$0.isDisabled }.sorted { $0.start < $1.start }

        guard let index = live.firstIndex(where: { t >= $0.start && t < $0.end }) else {
            return held(at: t, in: live, cursor: cursor, frameSize: frameSize,
                        clipSource: clipSource)
        }
        let segment = live[index]

        // A neighbour close enough to make this one move continuous. Anything on the far side of a
        // cut is not a neighbour: the picture is about to jump to different material, and easing
        // between two levels across that is the pop the clip-boundary logic exists to prevent.
        let previous = index > 0 ? live[index - 1] : nil
        let next = index + 1 < live.count ? live[index + 1] : nil
        let joinedPrevious = previous.flatMap {
            joins($0, before: segment, clipSource: clipSource) ? $0 : nil
        }
        let joinedNext = next.flatMap {
            joins(segment, before: $0, clipSource: clipSource) ? $0 : nil
        }

        let phase = self.phase(for: segment, at: t, clipSource: clipSource,
                               holdsToEnd: joinedNext != nil)
        let own = target(for: segment, cursor: cursor, frameSize: frameSize)

        switch phase {
        case .easingIn(let progress):
            // **The level it is coming *from*, not the literal 1.** This was the bug: every ramp
            // was measured against identity, so a zoom following another one climbed back up from
            // nothing instead of moving straight to its own level.
            let from = joinedPrevious?.level ?? 1
            let scale = segment.ease.interpolate(from: from, to: segment.level, progress: progress)
            // The centre travels on the same curve. Without this the join is a smooth zoom with an
            // instant jump sideways inside it, which reads worse than the dip did.
            let entry = joinedPrevious.map { target(for: $0, cursor: cursor, frameSize: frameSize) }
            let centre = entry.map {
                interpolate(from: $0, to: own, fraction: segment.ease.value(progress))
            } ?? own
            return ZoomTransform(scale: scale, center: clamp(centre, scale: scale), isMoving: true)

        case .holding:
            return ZoomTransform(scale: segment.level,
                                 center: clamp(own, scale: segment.level),
                                 isMoving: false)

        case .easingOut(let progress):
            let scale = segment.ease.interpolate(from: 1, to: segment.level, progress: progress)
            return ZoomTransform(scale: scale, center: clamp(own, scale: scale), isMoving: true)
        }
    }

    /// The frame between two segments that are close enough to be one move: it holds where the
    /// first one left it rather than resolving to identity because no segment covers the moment.
    private static func held(at t: TimeInterval, in live: [ZoomSegment], cursor: CGPoint?,
                             frameSize: CGSize,
                             clipSource: Range<TimeInterval>?) -> ZoomTransform {
        guard let previous = live.last(where: { $0.end <= t }),
              let next = live.first(where: { $0.start > t }),
              joins(previous, before: next, clipSource: clipSource)
        else { return .identity }

        let anchor = target(for: previous, cursor: cursor, frameSize: frameSize)
        return ZoomTransform(scale: previous.level,
                             center: clamp(anchor, scale: previous.level),
                             isMoving: false)
    }

    /// Whether `earlier` and `later` are one continuous move rather than two shots.
    ///
    /// Both have to be inside the clip on screen. A segment on the far side of a cut is not a
    /// neighbour however close its timestamps are, because source time is not monotonic in output
    /// time once the edit has a cut in it.
    private static func joins(_ earlier: ZoomSegment, before later: ZoomSegment,
                              clipSource: Range<TimeInterval>?) -> Bool {
        guard later.start - earlier.end <= joinGap, later.start >= earlier.end else { return false }
        guard let clipSource else { return true }
        return earlier.end > clipSource.lowerBound && later.start < clipSource.upperBound
    }

    private static func interpolate(from: CGPoint, to: CGPoint, fraction: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * CGFloat(fraction),
                y: from.y + (to.y - from.y) * CGFloat(fraction))
    }

    /// Which part of its own life a segment is in at this moment.
    private enum Phase {
        /// Progress 0…1 through the in-ramp.
        case easingIn(Double)
        /// At its own level, standing still.
        case holding
        /// Progress 1…0 through the out-ramp, on its way back to identity.
        case easingOut(Double)
    }

    /// The ramps sized by the segment's own ease durations, squeezed if the segment is too short to
    /// fit both.
    ///
    /// - Parameter holdsToEnd: there is a neighbour immediately after this one, so **the out-ramp
    ///   is suppressed** and the segment carries its level to its own end. The transition happens
    ///   once, in the next segment's in-ramp, rather than twice — out to identity and back.
    private static func phase(for segment: ZoomSegment,
                              at t: TimeInterval,
                              clipSource: Range<TimeInterval>?,
                              holdsToEnd: Bool) -> Phase {
        // Clamped to the material actually on screen. See `transform`.
        let start = max(segment.start, clipSource?.lowerBound ?? -.greatestFiniteMagnitude)
        let end = min(segment.end, clipSource?.upperBound ?? .greatestFiniteMagnitude)
        let wasCutInto = start > segment.start
        let wasCutOffAt = end < segment.end

        let elapsed = t - start
        let remaining = end - t
        let duration = max(end - start, 0.0001)

        // A segment shorter than its own ramps would otherwise ease in past its end and never
        // reach its level. Sharing the available time keeps both ramps and simply shortens them.
        let total = segment.easeIn + segment.easeOut
        let squeeze = total > duration ? duration / total : 1
        let easeIn = segment.easeIn * squeeze
        let easeOut = segment.easeOut * squeeze

        // A zoom that begins on frame zero opens already zoomed rather than animating in from
        // nothing: if the first thing to show is a close-up, it should simply be there. The same
        // holds for a clip that begins partway through a zoom — ramping in just after a cut reads
        // as a mistake, where cutting straight to the close-up reads as an edit.
        if segment.start <= 0 || wasCutInto, elapsed < easeIn {
            return .holding
        }
        if easeIn > 0, elapsed < easeIn {
            return .easingIn(elapsed / easeIn)
        }
        // **A cut still wins.** `holdsToEnd` suppresses the out-ramp at a join, where the next
        // segment picks the movement up — but a segment truncated by a clip boundary is not at a
        // join, it is about to be interrupted, and it has to be back at identity before the
        // picture jumps.
        if easeOut > 0, remaining < easeOut, !holdsToEnd || wasCutOffAt {
            return .easingOut(remaining / easeOut)
        }
        return .holding
    }

    private static func target(for segment: ZoomSegment, cursor: CGPoint?,
                               frameSize: CGSize) -> CGPoint {
        switch segment.anchor {
        case .fixed(let point):
            return point
        case .followCursor:
            // Nothing to follow is not an error — the pointer may simply have been outside the
            // recorded region — and the middle is the only honest answer.
            guard let cursor else { return CGPoint(x: 0.5, y: 0.5) }
            let normalised = CGPoint(x: cursor.x / frameSize.width,
                                     y: cursor.y / frameSize.height)
            return settled(towards: normalised)
        }
    }

    /// Quantises the pointer to the dead zone: the frame moves only once the pointer has left the
    /// middle of it, and then lands on the position that puts it back in the middle.
    private static func settled(towards point: CGPoint) -> CGPoint {
        func axis(_ value: Double) -> Double {
            let offset = value - 0.5
            guard abs(offset) > deadZone / 2 else { return 0.5 }
            return 0.5 + (offset - (offset > 0 ? deadZone / 2 : -deadZone / 2))
        }
        return CGPoint(x: axis(point.x), y: axis(point.y))
    }

    /// Pulls the centre in so the visible rectangle never leaves the recording.
    ///
    /// **This is the one that must not be wrong.** A centre that drifts past the edge shows the
    /// background through the middle of the picture, which reads as a rendering fault rather than
    /// a framing choice — and at 1× it collapses to the only legal answer, which is why zooming
    /// out always lands exactly where the un-zoomed frame is.
    private static func clamp(_ center: CGPoint, scale: Double) -> CGPoint {
        let half = 0.5 / max(scale, 1)
        func axis(_ value: CGFloat) -> CGFloat {
            min(max(value, CGFloat(half)), CGFloat(1 - half))
        }
        return CGPoint(x: axis(center.x), y: axis(center.y))
    }

    /// The source rectangle, in recording pixels, that a transform is showing.
    static func sourceRect(for transform: ZoomTransform, frameSize: CGSize) -> CGRect {
        let width = frameSize.width / CGFloat(transform.scale)
        let height = frameSize.height / CGFloat(transform.scale)
        return CGRect(x: transform.center.x * frameSize.width - width / 2,
                      y: transform.center.y * frameSize.height - height / 2,
                      width: width, height: height)
    }
}
