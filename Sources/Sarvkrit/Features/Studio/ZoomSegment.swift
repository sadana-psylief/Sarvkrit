import CoreGraphics
import Foundation

/// One stretch of the recording that is shown magnified.
///
/// **Stored in source time**, like every other track, and resolved for rendering through
/// `Timeline.sourceTime(forOutput:)`. That is what makes trimming the first two seconds off a
/// recording leave the zooms attached to the moments they were built for, rather than sliding
/// them all two seconds early.
struct ZoomSegment: Codable, Equatable, Identifiable {

    /// What the frame is centred on while the zoom holds.
    enum Anchor: Equatable {
        /// Track a heavily damped version of the pointer. For an activity that moves.
        case followCursor
        /// Hold still, at a point normalised 0…1 across the frame.
        ///
        /// Normalised so the anchor survives a change of export resolution — the same project
        /// exported at 1080p and 4K must frame the same thing.
        case fixed(CGPoint)
    }

    var id = UUID()
    /// Source time, seconds.
    var start: TimeInterval
    var end: TimeInterval
    var level: Double
    var anchor: Anchor
    /// Seconds of *output* time spent arriving. Output rather than source, because a clip sped up
    /// to 4× would otherwise compress a 0.6 s zoom-in into 0.15 s and turn it into a jump cut.
    var easeIn: TimeInterval = 0.6
    /// Shorter than `easeIn`: you can leave faster than you arrive without it feeling abrupt.
    var easeOut: TimeInterval = 0.5
    var ease: ZoomEase = .smooth
    /// Whether `ZoomPlanner` made this one.
    ///
    /// **This flag is what lets "Re-detect zooms" be pressed twice.** Regeneration replaces the
    /// automatic segments and leaves hand-made ones alone; without the distinction the button
    /// destroys the user's own work every time it is used.
    var isAutomatic: Bool = true
    var isDisabled: Bool = false

    static let levelRange: ClosedRange<Double> = 1...4
    /// Below this a segment cannot be grabbed with a mouse.
    static let minimumDuration: TimeInterval = 0.1

    var duration: TimeInterval { max(0, end - start) }

    func clamped() -> ZoomSegment {
        var copy = self
        copy.level = min(max(level, Self.levelRange.lowerBound), Self.levelRange.upperBound)
        return copy
    }
}

/// Hand-written rather than synthesised, so an anchor written by a newer build decodes to
/// something drawable instead of throwing and taking the whole project with it.
extension ZoomSegment.Anchor: Codable {
    private enum CodingKeys: String, CodingKey { case type, x, y }
    private enum Kind: String, Codable { case followCursor, fixed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? container.decode(Kind.self, forKey: .type)) ?? .followCursor
        switch kind {
        case .followCursor:
            self = .followCursor
        case .fixed:
            let x = (try? container.decode(CGFloat.self, forKey: .x)) ?? 0.5
            let y = (try? container.decode(CGFloat.self, forKey: .y)) ?? 0.5
            self = .fixed(CGPoint(x: x, y: y))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .followCursor:
            try container.encode(Kind.followCursor, forKey: .type)
        case .fixed(let point):
            try container.encode(Kind.fixed, forKey: .type)
            try container.encode(point.x, forKey: .x)
            try container.encode(point.y, forKey: .y)
        }
    }
}
