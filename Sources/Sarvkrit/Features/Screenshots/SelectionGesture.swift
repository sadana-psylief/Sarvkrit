import CoreGraphics
import Foundation

/// The area-selection drag, as a value type.
///
/// Extracted from the view for the reason the rest of this codebase extracts geometry: a drag is
/// a state machine with a surprising number of ways to end — a click with no movement, Escape
/// halfway, a nudge after the mouse is up, a drag that leaves the display — and none of those are
/// things to verify by dragging on a screen and looking.
///
/// Coordinates are global AppKit points throughout. Converting to pixels is `CaptureGeometry`'s
/// job and happens once, at the end.
struct SelectionGesture: Equatable {

    enum Phase: Equatable {
        case idle
        /// The mouse is down and the rect is being drawn.
        case dragging(anchor: CGPoint, current: CGPoint)
        /// The mouse is up and a rect exists, which arrows can still adjust.
        case settled(CGRect)
        case cancelled
    }

    private(set) var phase: Phase = .idle

    /// The display the drag started on. A selection never leaves it — one bitmap, one scale, and
    /// none of the mixed-Retina stitching problems that come with straddling two.
    let display: DisplaySnapshotGeometry

    /// Locked width ÷ height, or nil for free-form.
    var aspectRatio: CGFloat?
    /// Grow from the anchor in both directions (the ⌥ modifier).
    var resizesFromCenter = false

    /// A drag shorter than this in both axes is a click, not a selection.
    ///
    /// Without it, clicking to dismiss the overlay produces a 0×0 or 1×1 capture instead — which
    /// looks like the app crashed rather than like nothing happened.
    static let minimumDragDistance: CGFloat = 4

    init(display: DisplaySnapshotGeometry) {
        self.display = display
    }

    // MARK: - Input

    mutating func began(at point: CGPoint) {
        phase = .dragging(anchor: point, current: point)
    }

    mutating func moved(to point: CGPoint) {
        guard case .dragging(let anchor, _) = phase else { return }
        phase = .dragging(anchor: anchor, current: point)
    }

    /// - Returns: the selected rect, or nil when the gesture produced nothing.
    @discardableResult
    mutating func ended() -> CGRect? {
        guard case .dragging(let anchor, let current) = phase else { return nil }
        let raw = CaptureGeometry.selectionRect(from: anchor, to: current,
                                                aspectRatio: aspectRatio,
                                                fromCenter: resizesFromCenter)
        guard raw.width >= Self.minimumDragDistance || raw.height >= Self.minimumDragDistance else {
            phase = .idle
            return nil
        }
        let rect = CaptureGeometry.clamp(raw, to: display)
        // A drag that began inside the display but ended entirely outside it clamps to nothing.
        guard rect.width >= 1, rect.height >= 1 else {
            phase = .idle
            return nil
        }
        phase = .settled(rect)
        return rect
    }

    mutating func cancel() {
        phase = .cancelled
    }

    /// Resizes a settled selection by one of its handles.
    ///
    /// **The reason a settled rect is adjustable at all:** getting a selection right in one drag
    /// is rare, and without handles the only recourse is to start the whole capture again. Arrow
    /// keys move it but cannot resize it.
    mutating func resize(handle: SelectionHandles.Handle, to point: CGPoint,
                         constrainAspect: Bool) {
        guard case .settled(let rect) = phase else { return }
        let resized = SelectionHandles.resize(rect, handle: handle, to: point,
                                              constrainAspect: constrainAspect,
                                              minimumSide: 8)
        phase = .settled(CaptureGeometry.clamp(resized, to: display))
    }

    /// Restores a settled selection, for reopening the overlay on the last one.
    mutating func settle(_ rect: CGRect) {
        phase = .settled(CaptureGeometry.clamp(rect, to: display))
    }

    /// The rect once the drag is over, if there is one.
    var settledRect: CGRect? {
        if case .settled(let rect) = phase { return rect }
        return nil
    }

    /// Arrow-key adjustment after the mouse is up. Stays inside the display.
    mutating func nudge(by delta: CGSize) {
        guard case .settled(let rect) = phase else { return }
        phase = .settled(placing(rect, atOrigin: CGPoint(x: rect.minX + delta.width,
                                                         y: rect.minY + delta.height)))
    }

    /// Drags a settled selection to a new position by its inside.
    ///
    /// **Absolute, not incremental.** Dragging past the edge of the display and back has to bring
    /// the selection back with the pointer; accumulating clamped deltas instead leaves it pinned
    /// to the edge while the pointer walks away from it.
    mutating func move(originTo origin: CGPoint) {
        guard case .settled(let rect) = phase else { return }
        phase = .settled(placing(rect, atOrigin: origin))
    }

    /// Clamping the *origin* rather than intersecting keeps the size: intersecting at an edge
    /// would shrink the selection instead of stopping it, which feels like a bug.
    private func placing(_ rect: CGRect, atOrigin origin: CGPoint) -> CGRect {
        CGRect(x: min(max(origin.x, display.frame.minX), display.frame.maxX - rect.width),
               y: min(max(origin.y, display.frame.minY), display.frame.maxY - rect.height),
               width: rect.width, height: rect.height)
    }

    /// Replaces the selection with an exact pixel size, centred where it already is.
    mutating func setPixelSize(_ size: CGSize) {
        let centre: CGPoint
        switch phase {
        case .settled(let rect): centre = CGPoint(x: rect.midX, y: rect.midY)
        case .dragging(let anchor, _): centre = anchor
        default: centre = CGPoint(x: display.frame.midX, y: display.frame.midY)
        }
        let rect = CaptureGeometry.rect(withPixelSize: size, centeredOn: centre, in: display)
        phase = .settled(CaptureGeometry.clamp(rect, to: display))
    }

    // MARK: - Output

    /// The rect to draw right now, whichever phase we're in.
    var currentRect: CGRect? {
        switch phase {
        case .idle, .cancelled:
            return nil
        case .dragging(let anchor, let current):
            return CaptureGeometry.clamp(
                CaptureGeometry.selectionRect(from: anchor, to: current,
                                              aspectRatio: aspectRatio,
                                              fromCenter: resizesFromCenter),
                to: display)
        case .settled(let rect):
            return rect
        }
    }

    /// What the readout shows, in pixels.
    var pixelSize: CGSize? {
        currentRect.map { CaptureGeometry.pixelSize(of: $0, in: display) }
    }

    var isCancelled: Bool { phase == .cancelled }

    var isActive: Bool {
        if case .dragging = phase { return true }
        return false
    }
}
