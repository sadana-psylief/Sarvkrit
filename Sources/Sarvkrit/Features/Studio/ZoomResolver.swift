import CoreGraphics
import Foundation

/// How the screen layer is framed at one instant.
struct ZoomTransform: Equatable {
    /// 1 means the whole recording.
    var scale: Double = 1
    /// Normalised 0…1, and always already clamped so the visible rectangle is inside the frame.
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Whether the frame is travelling. The renderer blurs only while this is true, so a static
    /// zoomed shot costs nothing.
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
        guard frameSize.width > 0, frameSize.height > 0,
              let segment = segments.first(where: {
                  !$0.isDisabled && t >= $0.start && t < $0.end
              })
        else { return .identity }

        let (progress, moving) = envelope(for: segment, at: t, clipSource: clipSource)
        let scale = segment.ease.interpolate(from: 1, to: segment.level, progress: progress)

        let anchor = target(for: segment, cursor: cursor, frameSize: frameSize)
        return ZoomTransform(scale: scale,
                             center: clamp(anchor, scale: scale),
                             isMoving: moving)
    }

    /// 0 at the edges of the segment, 1 while it holds — with the in and out ramps sized by the
    /// segment's own ease durations, and squeezed if the segment is too short to fit both.
    private static func envelope(for segment: ZoomSegment,
                                 at t: TimeInterval,
                                 clipSource: Range<TimeInterval>?)
        -> (progress: Double, isMoving: Bool) {
        // Clamped to the material actually on screen. See `transform`.
        let start = max(segment.start, clipSource?.lowerBound ?? -.greatestFiniteMagnitude)
        let end = min(segment.end, clipSource?.upperBound ?? .greatestFiniteMagnitude)
        let wasCutInto = start > segment.start

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
            return (1, false)
        }
        if easeIn > 0, elapsed < easeIn {
            return (elapsed / easeIn, true)
        }
        if easeOut > 0, remaining < easeOut {
            return (remaining / easeOut, true)
        }
        return (1, false)
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
