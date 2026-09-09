import CoreGraphics
import Foundation

/// How the camera is framed when it is a picture-in-picture.
struct CameraSettings: Codable, Equatable {

    enum Shape: String, Codable, CaseIterable, Equatable {
        case circle, squircle, rectangle

        var title: String {
            switch self {
            case .circle: return "Circle"
            case .squircle: return "Squircle"
            case .rectangle: return "Rectangle"
            }
        }
    }

    /// What happens to the camera while the frame is zoomed in.
    enum ZoomSizing: String, Codable, CaseIterable, Equatable {
        /// A zoom exists to show something, and the camera covering it defeats the zoom.
        ///
        /// **No longer the default, and the argument against it is stronger.** A camera that
        /// quietly changes size every time the auto-zoom fires reads as a glitch — you notice your
        /// own face breathing in and out and cannot tell why. Holding still is the calmer default;
        /// this stays for anyone who prefers the trade.
        case shrink
        case hold
        case grow

        var title: String {
            switch self {
            case .shrink: return "Get smaller"
            case .hold: return "Stay the same"
            case .grow: return "Get larger"
            }
        }

        fileprivate var exponent: Double {
            switch self {
            case .shrink: return -0.2
            case .hold: return 0
            case .grow: return 0.15
            }
        }
    }

    var shape: Shape = .squircle
    /// Of the shorter side. The reference's PiP is a continuous-curve squircle and the difference
    /// from a circular corner is visible at this size.
    var cornerRadiusFraction: Double = 0.26
    /// Of the canvas height.
    var sizeFraction: Double = 0.22
    var aspect: Double = 1
    var corner: CaptureBackground.Alignment = .bottomLeading
    /// Of the canvas, measured from its edge — not from the project's padding, or raising the
    /// padding would appear to move the camera.
    var marginFraction: Double = 0.03
    var shadow: CaptureBackground.Shadow? = CaptureBackground.Shadow()
    /// Front cameras look wrong un-mirrored.
    var mirrored = true
    /// **Fixed by default.** See `ZoomSizing.shrink` for the argument this reverses.
    var sizeDuringZoom: ZoomSizing = .hold
    var fadeSeconds: TimeInterval = 0.35
    var removesBackground = false

    init() {}
}

/// One stretch with a particular camera layout.
///
/// **A track rather than a setting**, because the shape of a good demo is full-frame camera for a
/// short intro, picture-in-picture for the walkthrough, and hidden over a dense diagram. A single
/// "camera position" cannot express any of that.
struct CameraSegment: Codable, Equatable, Identifiable {
    enum Layout: String, Codable, CaseIterable, Equatable {
        case pip, fullFrame, hidden

        var title: String {
            switch self {
            case .pip: return "Picture in picture"
            case .fullFrame: return "Full frame"
            case .hidden: return "Hidden"
            }
        }
    }

    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var layout: Layout
    var transition: TimeInterval = 0.45
}

/// Where the camera is, right now.
struct CameraState: Equatable {
    var rect: CGRect
    var cornerRadius: CGFloat
    var opacity: Double
}

/// Resolving the camera track into one rectangle.
///
/// Position, size and corner radius all animate together on a single curve, so a full-frame camera
/// *becomes* the picture-in-picture rather than cutting to it.
enum CameraLayoutResolver {

    /// - Parameter clipSource: the source range of the clip this frame came from. The blend is
    ///   clamped to it for the same reason the zoom envelope is — after a cut, source time is not
    ///   monotonic in output time, so a blend measured from the segment's own end is still running
    ///   when the picture jumps and the camera snaps mid-move.
    /// - Parameter cameraStart: when the camera track begins, in source time. It is a couple of
    ///   seconds after the screen, because that is how long a capture session takes to come up —
    ///   so the bubble is faded in over `settings.fadeSeconds` from there rather than arriving in
    ///   one frame. `fadeSeconds` existed and was offered in the inspector, and nothing rendered
    ///   it.
    static func state(at t: TimeInterval,
                      segments: [CameraSegment],
                      settings: CameraSettings,
                      canvas: CGSize,
                      zoom: Double,
                      clipSource: Range<TimeInterval>? = nil,
                      cameraStart: TimeInterval = 0) -> CameraState? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }

        let pip = pipRect(settings: settings, canvas: canvas, zoom: zoom)
        let full = CGRect(origin: .zero, size: canvas)

        let arriving = arrival(at: t, start: cameraStart, fade: settings.fadeSeconds,
                               clipStart: clipSource?.lowerBound)

        guard let segment = segments.first(where: { t >= $0.start && t < $0.end }) else {
            return CameraState(rect: pip, cornerRadius: radius(for: pip, settings: settings),
                               opacity: arriving)
        }

        let target: CGRect
        let opacity: Double
        switch segment.layout {
        case .pip: target = pip; opacity = arriving
        case .fullFrame: target = full; opacity = arriving
        case .hidden: return nil
        }

        // Blended towards the neighbouring layout across the transition, at both ends, so the
        // change reads as one movement rather than as two cuts.
        let blend = blendFraction(at: t, segment: segment, clipSource: clipSource)
        guard blend < 1 else {
            return CameraState(rect: target, cornerRadius: radius(for: target, settings: settings),
                               opacity: opacity)
        }
        let eased = CGFloat(ZoomEase.smooth.value(blend))
        let rect = interpolate(from: pip, to: target, fraction: eased)
        return CameraState(rect: rect, cornerRadius: radius(for: rect, settings: settings),
                           opacity: opacity)
    }

    /// How far in the camera is, having only just started.
    ///
    /// **The fade softens an arrival, and there is no arrival if the camera was already running
    /// when the visible material begins.** The trimmed lead-in puts this exactly on the seam: a
    /// project whose first clip starts at the capture offset opens at `t == cameraStart`, which is
    /// the first frame of the fade — so the very frame the user looks at first would carry no
    /// camera, and trimming would have moved the hole rather than closed it. Anything past a
    /// split is the same case.
    private static func arrival(at t: TimeInterval, start: TimeInterval,
                                fade: TimeInterval,
                                clipStart: TimeInterval? = nil) -> Double {
        guard fade > 0, (clipStart ?? 0) < start else { return 1 }
        return min(1, max(0, (t - start) / fade))
    }

    /// 1 while the segment holds, ramping from 0 at each edge.
    private static func blendFraction(at t: TimeInterval, segment: CameraSegment,
                                      clipSource: Range<TimeInterval>?) -> Double {
        guard segment.transition > 0 else { return 1 }
        let start = max(segment.start, clipSource?.lowerBound ?? -.greatestFiniteMagnitude)
        let end = min(segment.end, clipSource?.upperBound ?? .greatestFiniteMagnitude)
        let intoStart = t - start
        let toEnd = end - t
        return min(1, min(intoStart, toEnd) / segment.transition)
    }

    private static func interpolate(from: CGRect, to: CGRect, fraction: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * fraction,
               y: from.minY + (to.minY - from.minY) * fraction,
               width: from.width + (to.width - from.width) * fraction,
               height: from.height + (to.height - from.height) * fraction)
    }

    private static func pipRect(settings: CameraSettings, canvas: CGSize,
                                zoom: Double) -> CGRect {
        let scale = pow(max(zoom, 1), settings.sizeDuringZoom.exponent)
        let height = canvas.height * CGFloat(settings.sizeFraction * scale)
        let width = height * CGFloat(max(settings.aspect, 0.1))
        let margin = CGSize(width: canvas.width * CGFloat(settings.marginFraction),
                            height: canvas.height * CGFloat(settings.marginFraction))

        let unit = settings.corner.unitPoint
        let free = CGSize(width: max(0, canvas.width - width - margin.width * 2),
                          height: max(0, canvas.height - height - margin.height * 2))
        return CGRect(x: margin.width + free.width * unit.x,
                      y: margin.height + free.height * unit.y,
                      width: width, height: height)
    }

    /// From the *shorter* side, so a non-square camera does not end up with lozenge ends.
    private static func radius(for rect: CGRect, settings: CameraSettings) -> CGFloat {
        let shorter = min(rect.width, rect.height)
        switch settings.shape {
        case .circle: return shorter / 2
        case .rectangle: return 0
        case .squircle: return min(shorter / 2, shorter * CGFloat(settings.cornerRadiusFraction))
        }
    }
}
