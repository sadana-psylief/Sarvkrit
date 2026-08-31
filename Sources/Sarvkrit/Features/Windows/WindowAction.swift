import Foundation

/// Everything a window can be asked to do.
///
/// Grouped the way the settings pane presents them, so the list and the UI can't drift apart.
enum WindowAction: String, Codable, CaseIterable, Identifiable {
    // Halves
    case leftHalf, rightHalf, centerHalf, topHalf, bottomHalf
    // Corners
    case topLeft, topRight, bottomLeft, bottomRight
    // Size
    case maximize, almostMaximize, maximizeHeight, makeSmaller, makeLarger, center, restore
    // Thirds
    case firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds
    // Fourths
    case firstFourth, secondFourth, thirdFourth, lastFourth
    case firstThreeFourths, centerThreeFourths, lastThreeFourths
    // Sixths
    case topLeftSixth, topCenterSixth, topRightSixth
    case bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    // Nudge
    case moveLeft, moveRight, moveUp, moveDown
    // Displays
    case nextDisplay, previousDisplay

    var id: String { rawValue }

    /// Grouped once, rather than by filtering all 41 actions per group on every render. The
    /// settings pane asked for eight groups and re-scanned the full list for each of them —
    /// including the collapsed ones, whose contents were never shown.
    static let grouped: [Group: [WindowAction]] = Dictionary(grouping: allCases, by: \.group)

    /// The actions a snap zone may be assigned. A display move needs a second screen and Restore
    /// has no meaning for a drop, so neither belongs in the menu.
    static let assignableToZone: [WindowAction] =
        allCases.filter { !$0.isDisplayMove && $0 != .restore }

    enum Group: String, CaseIterable, Identifiable {
        case halves, corners, size, thirds, fourths, sixths, move, displays
        var id: String { rawValue }
        var title: String {
            switch self {
            case .halves: return "Halves"
            case .corners: return "Corners"
            case .size: return "Size"
            case .thirds: return "Thirds"
            case .fourths: return "Fourths"
            case .sixths: return "Sixths"
            case .move: return "Move"
            case .displays: return "Displays"
            }
        }
    }

    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf: return .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .corners
        case .maximize, .almostMaximize, .maximizeHeight, .makeSmaller, .makeLarger, .center, .restore:
            return .size
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds:
            return .thirds
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
             .firstThreeFourths, .centerThreeFourths, .lastThreeFourths:
            return .fourths
        case .topLeftSixth, .topCenterSixth, .topRightSixth,
             .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            return .sixths
        case .moveLeft, .moveRight, .moveUp, .moveDown: return .move
        case .nextDisplay, .previousDisplay: return .displays
        }
    }

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .centerHalf: return "Center Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .maximizeHeight: return "Maximize Height"
        case .makeSmaller: return "Make Smaller"
        case .makeLarger: return "Make Larger"
        case .center: return "Center"
        case .restore: return "Restore"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .centerTwoThirds: return "Center Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .firstFourth: return "First Fourth"
        case .secondFourth: return "Second Fourth"
        case .thirdFourth: return "Third Fourth"
        case .lastFourth: return "Last Fourth"
        case .firstThreeFourths: return "First Three Fourths"
        case .centerThreeFourths: return "Center Three Fourths"
        case .lastThreeFourths: return "Last Three Fourths"
        case .topLeftSixth: return "Top Left Sixth"
        case .topCenterSixth: return "Top Center Sixth"
        case .topRightSixth: return "Top Right Sixth"
        case .bottomLeftSixth: return "Bottom Left Sixth"
        case .bottomCenterSixth: return "Bottom Center Sixth"
        case .bottomRightSixth: return "Bottom Right Sixth"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        }
    }

    /// Actions that need the window's existing frame rather than only the screen — sizing,
    /// nudging, and the ultrawide cycling.
    var isRelative: Bool {
        switch self {
        case .makeSmaller, .makeLarger, .maximizeHeight, .center,
             .moveLeft, .moveRight, .moveUp, .moveDown:
            return true
        default:
            return false
        }
    }

    /// Handled by the manipulator rather than the geometry — they change which screen the window
    /// is on, so there's no target rect on the current one.
    var isDisplayMove: Bool { self == .nextDisplay || self == .previousDisplay }
}
