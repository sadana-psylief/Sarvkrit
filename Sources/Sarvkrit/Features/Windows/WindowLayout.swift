import CoreGraphics
import Foundation

/// Where a window should end up.
///
/// Entirely pure — a screen rect in, a window rect out — so all 41 actions are a test table rather
/// than something you check by dragging windows around and squinting.
enum WindowLayout {

    /// How close two frames must be to count as "the same layout".
    ///
    /// Not zero on purpose. Terminal and other apps quantize their size to whole character cells,
    /// so the frame you set is never quite the frame you read back. Exact comparison would make
    /// ultrawide cycling misfire on precisely those apps.
    static let tolerance: CGFloat = 8

    /// Aspect ratio at or above which a display counts as ultrawide. 21:9 is 2.33 and 32:9 is 3.55;
    /// 2.1 catches both while leaving 16:9 (1.78) and 16:10 (1.6) well clear.
    static let ultrawideAspectThreshold: CGFloat = 2.1

    struct Context {
        /// The target screen's `visibleFrame` — not `frame`, so maximize respects the menu bar
        /// and the Dock.
        var visibleFrame: CGRect
        /// The window's current frame, needed by sizing, nudging and cycling.
        var currentFrame: CGRect
        /// The setting is on **and** this screen is actually wide enough to warrant it.
        var isUltrawide: Bool = false
        /// Fraction of the screen that `maximize` fills in ultrawide mode.
        var ultrawideMaxWidthFraction: CGFloat = 2.0 / 3.0
        /// How far a nudge moves the window.
        var step: CGFloat = 40
    }

    static func isUltrawide(_ screen: CGRect) -> Bool {
        guard screen.height > 0 else { return false }
        return screen.width / screen.height >= ultrawideAspectThreshold
    }

    /// The target frame, or nil for actions the geometry doesn't own (display moves, and restore,
    /// which needs a remembered frame rather than a computed one).
    static func rect(for action: WindowAction, in context: Context) -> CGRect? {
        let f = context.visibleFrame

        switch action {
        // MARK: Halves — retargeted to thirds on an ultrawide, with repeat-press cycling
        case .leftHalf:
            return context.isUltrawide ? cycledLeft(context) : columns(f, from: 0, to: 1, of: 2)
        case .rightHalf:
            return context.isUltrawide ? cycledRight(context) : columns(f, from: 1, to: 2, of: 2)
        case .centerHalf:
            return columns(f, from: 0.5, to: 1.5, of: 2)
        case .topHalf:
            return rows(f, from: 0, to: 1, of: 2)
        case .bottomHalf:
            return rows(f, from: 1, to: 2, of: 2)

        // MARK: Corners
        case .topLeft:      return quadrant(f, left: true, top: true)
        case .topRight:     return quadrant(f, left: false, top: true)
        case .bottomLeft:   return quadrant(f, left: true, top: false)
        case .bottomRight:  return quadrant(f, left: false, top: false)

        // MARK: Size
        case .maximize:
            // On an ultrawide, filling the display is something almost nobody wants.
            guard context.isUltrawide else { return f }
            return centred(width: f.width * context.ultrawideMaxWidthFraction, height: f.height, in: f)
        case .almostMaximize:
            return centred(width: f.width * 0.9, height: f.height * 0.9, in: f)
        case .maximizeHeight:
            return CGRect(x: context.currentFrame.minX, y: f.minY,
                          width: context.currentFrame.width, height: f.height)
        case .makeSmaller:
            return resized(context, by: -0.1)
        case .makeLarger:
            return resized(context, by: 0.1)
        case .center:
            return centred(width: context.currentFrame.width,
                           height: context.currentFrame.height, in: f)
        case .restore:
            // Owned by the restore cache, not by geometry.
            return nil

        // MARK: Thirds
        case .firstThird:       return columns(f, from: 0, to: 1, of: 3)
        case .centerThird:      return columns(f, from: 1, to: 2, of: 3)
        case .lastThird:        return columns(f, from: 2, to: 3, of: 3)
        case .firstTwoThirds:   return columns(f, from: 0, to: 2, of: 3)
        case .centerTwoThirds:  return columns(f, from: 0.5, to: 2.5, of: 3)
        case .lastTwoThirds:    return columns(f, from: 1, to: 3, of: 3)

        // MARK: Fourths
        case .firstFourth:          return columns(f, from: 0, to: 1, of: 4)
        case .secondFourth:         return columns(f, from: 1, to: 2, of: 4)
        case .thirdFourth:          return columns(f, from: 2, to: 3, of: 4)
        case .lastFourth:           return columns(f, from: 3, to: 4, of: 4)
        case .firstThreeFourths:    return columns(f, from: 0, to: 3, of: 4)
        case .centerThreeFourths:   return columns(f, from: 0.5, to: 3.5, of: 4)
        case .lastThreeFourths:     return columns(f, from: 1, to: 4, of: 4)

        // MARK: Sixths — a 3×2 grid
        case .topLeftSixth:      return sixth(f, column: 0, top: true)
        case .topCenterSixth:    return sixth(f, column: 1, top: true)
        case .topRightSixth:     return sixth(f, column: 2, top: true)
        case .bottomLeftSixth:   return sixth(f, column: 0, top: false)
        case .bottomCenterSixth: return sixth(f, column: 1, top: false)
        case .bottomRightSixth:  return sixth(f, column: 2, top: false)

        // MARK: Nudge
        case .moveLeft:  return nudged(context, dx: -context.step, dy: 0)
        case .moveRight: return nudged(context, dx: context.step, dy: 0)
        case .moveUp:    return nudged(context, dx: 0, dy: context.step)
        case .moveDown:  return nudged(context, dx: 0, dy: -context.step)

        case .nextDisplay, .previousDisplay:
            return nil
        }
    }

    // MARK: - Ultrawide cycling

    /// third → half → two-thirds → back to third. Taking the current frame as input keeps this
    /// pure: no memory of the last keypress is needed.
    static func cycledLeft(_ context: Context) -> CGRect {
        let f = context.visibleFrame
        let third = columns(f, from: 0, to: 1, of: 3)
        let half = columns(f, from: 0, to: 1, of: 2)
        let twoThirds = columns(f, from: 0, to: 2, of: 3)

        if matches(context.currentFrame, third) { return half }
        if matches(context.currentFrame, half) { return twoThirds }
        return third
    }

    static func cycledRight(_ context: Context) -> CGRect {
        let f = context.visibleFrame
        let third = columns(f, from: 2, to: 3, of: 3)
        let half = columns(f, from: 1, to: 2, of: 2)
        let twoThirds = columns(f, from: 1, to: 3, of: 3)

        if matches(context.currentFrame, third) { return half }
        if matches(context.currentFrame, half) { return twoThirds }
        return third
    }

    static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Building blocks

    /// A vertical slice. Fractional bounds allow the centred variants.
    private static func columns(_ f: CGRect, from: CGFloat, to: CGFloat, of total: CGFloat) -> CGRect {
        let unit = f.width / total
        return CGRect(x: f.minX + unit * from, y: f.minY, width: unit * (to - from), height: f.height)
    }

    /// A horizontal slice, measured from the **top** so `from: 0` is the top row regardless of the
    /// bottom-left coordinate space.
    private static func rows(_ f: CGRect, from: CGFloat, to: CGFloat, of total: CGFloat) -> CGRect {
        let unit = f.height / total
        return CGRect(x: f.minX, y: f.maxY - unit * to, width: f.width, height: unit * (to - from))
    }

    private static func quadrant(_ f: CGRect, left: Bool, top: Bool) -> CGRect {
        CGRect(
            x: left ? f.minX : f.midX,
            y: top ? f.midY : f.minY,
            width: f.width / 2,
            height: f.height / 2
        )
    }

    private static func sixth(_ f: CGRect, column: CGFloat, top: Bool) -> CGRect {
        let width = f.width / 3
        let height = f.height / 2
        return CGRect(
            x: f.minX + width * column,
            y: top ? f.midY : f.minY,
            width: width,
            height: height
        )
    }

    private static func centred(width: CGFloat, height: CGFloat, in f: CGRect) -> CGRect {
        CGRect(x: f.midX - width / 2, y: f.midY - height / 2, width: width, height: height)
    }

    /// Grows or shrinks about the centre, clamped so a window can't vanish or outgrow the screen.
    private static func resized(_ context: Context, by fraction: CGFloat) -> CGRect {
        let f = context.visibleFrame
        let current = context.currentFrame
        let width = min(max(current.width * (1 + fraction), 200), f.width)
        let height = min(max(current.height * (1 + fraction), 150), f.height)
        return clamped(centred(width: width, height: height, in: current), to: f)
    }

    private static func nudged(_ context: Context, dx: CGFloat, dy: CGFloat) -> CGRect {
        clamped(context.currentFrame.offsetBy(dx: dx, dy: dy), to: context.visibleFrame)
    }

    /// Keeps a rect inside the screen — a nudge should stop at the edge rather than walking a
    /// window off it.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.minX, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.minY, bounds.minY), bounds.maxY - result.height)
        return result
    }
}
