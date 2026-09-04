import CoreGraphics
import Foundation

/// Where the action bar sits relative to the selection the user just drew.
///
/// Pure, because "the bar is off the bottom of the screen when you select near the Dock" is not a
/// thing to discover by dragging rectangles at the edge of a display — the same reason
/// `QuickAccessPlacement` is pure.
///
/// **Below and centred is the default, and it is chosen rather than inherited.** Above would sit
/// where the eye already is — on the thing being photographed — and to the side would move as the
/// selection is resized horizontally, which is the axis people adjust most.
enum SelectionBarPlacement {

    /// Gap between the selection's edge and the bar.
    static let gap: CGFloat = 12
    /// How close to the display's edge the bar may come.
    static let margin: CGFloat = 8

    enum Position: Equatable {
        case below
        case above
        /// Neither side has room — the selection is nearly the whole display — so the bar goes
        /// inside it, at the bottom. Overlapping the shot is better than being unreachable.
        case inside
    }

    struct Result: Equatable {
        var origin: CGPoint
        var position: Position
    }

    /// - Parameters:
    ///   - selection: the settled rect, in global AppKit points (bottom-left origin).
    ///   - barSize: the bar's size in points.
    ///   - display: the frame of the display the selection is on.
    static func place(selection: CGRect, barSize: CGSize, display: CGRect) -> Result {
        let position: Position
        if selection.minY - gap - barSize.height >= display.minY + margin {
            position = .below
        } else if selection.maxY + gap + barSize.height <= display.maxY - margin {
            position = .above
        } else {
            position = .inside
        }

        let y: CGFloat
        switch position {
        case .below: y = selection.minY - gap - barSize.height
        case .above: y = selection.maxY + gap
        case .inside: y = selection.minY + gap
        }

        // Centred on the selection, then pulled back inside the display. Clamping the centre
        // rather than the edge keeps the bar pointing at its selection for as long as it can.
        let centred = selection.midX - barSize.width / 2
        let lowest = display.minX + margin
        let highest = display.maxX - margin - barSize.width
        let x = highest >= lowest ? min(max(centred, lowest), highest) : lowest

        return Result(origin: CGPoint(x: x, y: y), position: position)
    }
}
