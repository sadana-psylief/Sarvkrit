import CoreGraphics
import Foundation

/// The drag-to-snap state machine, with no knowledge of events, panels or Accessibility.
///
/// Extracted on purpose. The restore bug earlier in this feature survived review because it lived
/// in AX glue that could only be exercised against live windows; a drag is even harder to test by
/// hand, since reproducing "released over the top-left corner" means actually doing it.
struct SnapDragSession {

    enum State: Equatable {
        /// Nothing happening — the overwhelmingly common case, and the one the tap must recognise
        /// in the fewest possible instructions.
        case idle
        /// The pointer went down on a titlebar. Not yet a drag: a click that never moves must not
        /// show a footprint.
        case pressed
        /// Actually dragging, currently over this zone (nil when over no zone).
        case dragging(zone: SnapZone?)
    }

    enum Effect: Equatable {
        case showFootprint(SnapZone)
        case moveFootprint(SnapZone)
        case hideFootprint
        case snap(SnapZone)
    }

    /// How far the pointer must travel before a press counts as a drag. Without this, the smallest
    /// wobble during a click on a titlebar would flash a footprint.
    static let dragThreshold: CGFloat = 6

    private(set) var state: State = .idle
    private var origin: CGPoint = .zero

    /// - Returns: what the controller should do, if anything.
    mutating func pressed(at point: CGPoint) -> Effect? {
        state = .pressed
        origin = point
        return nil
    }

    mutating func moved(to point: CGPoint, zone: SnapZone?) -> Effect? {
        switch state {
        case .idle:
            // A drag we never armed — someone else's. Ignore it entirely.
            return nil

        case .pressed:
            guard hypot(point.x - origin.x, point.y - origin.y) >= Self.dragThreshold else {
                return nil
            }
            state = .dragging(zone: zone)
            return zone.map { .showFootprint($0) }

        case .dragging(let current):
            guard zone != current else { return nil }   // same zone: nothing to redraw
            state = .dragging(zone: zone)
            if let zone {
                return current == nil ? .showFootprint(zone) : .moveFootprint(zone)
            }
            return .hideFootprint
        }
    }

    mutating func released() -> Effect? {
        defer { state = .idle }
        guard case .dragging(let zone) = state, let zone else {
            // A click, or a drag that ended over no zone. Either way the window stays where the
            // user put it — but any footprint must still come down.
            return hideIfShowing()
        }
        return .snap(zone)
    }

    /// Escape, the feature being switched off, or the window vanishing mid-drag.
    mutating func cancelled() -> Effect? {
        defer { state = .idle }
        return hideIfShowing()
    }

    private func hideIfShowing() -> Effect? {
        if case .dragging(let zone) = state, zone != nil { return .hideFootprint }
        return nil
    }

    var isArmed: Bool { state != .idle }
}
