import CoreGraphics
import Foundation

/// The nine regions of a screen edge that a dragged window can be dropped into.
///
/// Pure arithmetic, deliberately: this is consulted while the pointer is moving, and a hit-test
/// that had to ask Accessibility anything would show up as drag lag.
enum SnapZone: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: return "Top Left Corner"
        case .top: return "Top Edge"
        case .topRight: return "Top Right Corner"
        case .left: return "Left Edge"
        case .center: return "Center"
        case .right: return "Right Edge"
        case .bottomLeft: return "Bottom Left Corner"
        case .bottom: return "Bottom Edge"
        case .bottomRight: return "Bottom Right Corner"
        }
    }
}

enum SnapZoneLayout {
    /// How far into the screen an edge reaches. Generous enough to hit without aiming, small
    /// enough that a window dragged across the screen doesn't pass through three zones.
    static let edgeThickness: CGFloat = 24
    /// Corners are longer than the edges are thick, so aiming at a corner doesn't land on the
    /// edge beside it.
    static let cornerLength: CGFloat = 120
    /// The centre zone is a small target in the middle rather than "everything not an edge",
    /// so an ordinary drag across the screen triggers nothing at all.
    static let centerFraction: CGFloat = 0.12

    /// Which zone a pointer is in, or nil for the great majority of the screen where dropping
    /// should do nothing.
    ///
    /// Both arguments must be in the **same** coordinate space. The caller converts; mixing
    /// `CGEvent.location` (top-left origin) with an `NSScreen` frame (bottom-left) is the bug this
    /// separation exists to make visible.
    static func zone(at point: CGPoint, in screen: CGRect, flipped: Bool = false) -> SnapZone? {
        guard screen.contains(point) else { return nil }

        let nearLeft = point.x - screen.minX <= edgeThickness
        let nearRight = screen.maxX - point.x <= edgeThickness
        let nearMinY = point.y - screen.minY <= edgeThickness
        let nearMaxY = screen.maxY - point.y <= edgeThickness

        // "Top" means top of the display. In a flipped (top-left origin) space that is min-Y;
        // in Cocoa's bottom-left space it is max-Y.
        let nearTop = flipped ? nearMinY : nearMaxY
        let nearBottom = flipped ? nearMaxY : nearMinY

        let inLeftCorner = point.x - screen.minX <= cornerLength
        let inRightCorner = screen.maxX - point.x <= cornerLength
        let cornerTop = flipped
            ? point.y - screen.minY <= cornerLength
            : screen.maxY - point.y <= cornerLength
        let cornerBottom = flipped
            ? screen.maxY - point.y <= cornerLength
            : point.y - screen.minY <= cornerLength

        // Corners win over edges: a pointer in the top-left corner means the corner, not the top
        // edge it also touches. A corner is claimed from either of its two edges — coming down the
        // left side or in along the top both land there.
        if (nearTop && inLeftCorner) || (nearLeft && cornerTop) { return .topLeft }
        if (nearTop && inRightCorner) || (nearRight && cornerTop) { return .topRight }
        if (nearBottom && inLeftCorner) || (nearLeft && cornerBottom) { return .bottomLeft }
        if (nearBottom && inRightCorner) || (nearRight && cornerBottom) { return .bottomRight }

        if nearTop { return .top }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        if nearRight { return .right }

        // The centre target, well away from the edges.
        let width = screen.width * centerFraction
        let height = screen.height * centerFraction
        let middle = CGRect(x: screen.midX - width / 2, y: screen.midY - height / 2,
                            width: width, height: height)
        return middle.contains(point) ? .center : nil
    }

    /// Everything a drop needs, decided from the pointer alone: which screen it is over and which
    /// zone of that screen.
    ///
    /// Pure, and taking screen frames rather than `NSScreen`, because this is the one place where a
    /// multi-display mistake is both easy and invisible on a single-display Mac. Two distinct
    /// errors live here — testing the pointer against the wrong screen, and deciding "ultrawide"
    /// from whether *any* ultrawide is attached rather than from the screen being dropped onto.
    ///
    /// - Parameters:
    ///   - point: pointer position in Accessibility space (origin top-left of the primary display).
    ///   - screenFrames: screen frames in Cocoa space.
    static func resolve(
        at point: CGPoint, screenFrames: [CGRect], primaryHeight: CGFloat
    ) -> (zone: SnapZone, screen: CGRect)? {
        for frame in screenFrames {
            let axFrame = ScreenCoordinates.toAccessibility(frame, primaryHeight: primaryHeight)
            guard axFrame.contains(point) else { continue }
            guard let zone = zone(at: point, in: axFrame, flipped: true) else { return nil }
            return (zone, frame)
        }
        return nil
    }

    /// Whether the mode applies to *this* screen. The per-display rule in one place, so the drag
    /// path and the keyboard path can't drift apart.
    static func usesUltrawideLayout(screen: CGRect, settingEnabled: Bool) -> Bool {
        settingEnabled && WindowLayout.isUltrawide(screen)
    }

    /// What each zone does by default.
    static let defaultActions: [SnapZone: WindowAction] = [
        .topLeft: .topLeft, .top: .maximize, .topRight: .topRight,
        .left: .leftHalf, .center: .center, .right: .rightHalf,
        .bottomLeft: .bottomLeft, .bottom: .bottomHalf, .bottomRight: .bottomRight,
    ]

    /// On an ultrawide, the side edges give thirds — and, crucially, the **concrete** third rather
    /// than `leftHalf`, whose ultrawide path cycles based on the window's current frame. A cycling
    /// action would let the footprint preview and the actual drop disagree.
    static let ultrawideActions: [SnapZone: WindowAction] = [
        .topLeft: .topLeftSixth, .top: .maximize, .topRight: .topRightSixth,
        .left: .firstThird, .center: .centerThird, .right: .lastThird,
        .bottomLeft: .bottomLeftSixth, .bottom: .bottomHalf, .bottomRight: .bottomRightSixth,
    ]

    static func defaultAction(for zone: SnapZone, ultrawide: Bool) -> WindowAction {
        let table = ultrawide ? ultrawideActions : defaultActions
        return table[zone] ?? .maximize
    }
}
