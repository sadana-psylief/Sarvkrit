import CoreGraphics
import Foundation

/// Which rectangle the aiming overlay opens with when you record an area.
///
/// **There is always a rectangle.** Dragging one out of an empty screen is fine for a screenshot,
/// which happens in a second and is thrown away if it is wrong; a recording is aimed once and then
/// lived with for ten minutes, so it wants to open as something you adjust rather than something
/// you draw. Last time's rect is the best guess available, and a centred widescreen box is the
/// answer when there is no last time.
enum RecordingArea {

    /// Fraction of the display the default box covers across. Wide enough to be the obvious
    /// subject of the recording, narrow enough that all eight handles are clear of the edges.
    private static let defaultWidthFraction: CGFloat = 0.6

    /// The rect to seed the overlay with, in global AppKit points.
    ///
    /// `displays` are the frames of the displays being aimed over. A remembered rect that touches
    /// none of them is discarded rather than passed on: `SelectionView.settle` refuses a rect
    /// outside its own display, so a rect left behind on an unplugged monitor would open the
    /// overlay with nothing at all — the exact state this is here to avoid.
    static func seed(remembered: CGRect?, displays: [CGRect]) -> CGRect? {
        if let remembered, displays.contains(where: { $0.intersects(remembered) }) {
            return remembered
        }
        guard let display = displays.first else { return nil }
        return `default`(on: display)
    }

    /// A centred 16:9 box — the shape everything here is eventually exported into.
    static func `default`(on display: CGRect) -> CGRect {
        var width = display.width * defaultWidthFraction
        var height = width * 9 / 16
        // A display taller than it is wide, or an unusually short one, would otherwise put two
        // handles off the edge where they cannot be grabbed.
        if height > display.height * defaultWidthFraction {
            height = display.height * defaultWidthFraction
            width = height * 16 / 9
        }
        return CGRect(x: display.midX - width / 2, y: display.midY - height / 2,
                      width: width, height: height).integral
    }
}
