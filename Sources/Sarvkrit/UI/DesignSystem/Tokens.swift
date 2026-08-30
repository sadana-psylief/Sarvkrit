import SwiftUI

/// The only numbers any view is allowed to invent.
///
/// The design rule for Sarvkrit is: never hand-roll a control AppKit already provides. Stock
/// `Toggle`, `Form`, `NavigationSplitView` and semantic colors are what make dark mode,
/// Increase Contrast, Reduce Transparency and VoiceOver work without a line of extra code.
/// These tokens cover only the spacing and shape choices that stock controls don't make for us.
enum Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24

        static let dropdownInset: CGFloat = 12
        static let windowInset: CGFloat = 20
    }

    enum Radius {
        /// Matches the rounding of Tahoe's grouped form cards.
        static let card: CGFloat = 10
        static let module: CGFloat = 10
        static let iconTile: CGFloat = 7
    }

    /// The row grid. Alignment in the dropdown is structural, not maintained: every toggle row is
    /// the same height, the icon occupies a fixed leading column, and the switch a fixed trailing
    /// one — so switches line up because they cannot do anything else.
    enum Metrics {
        static let toggleRowHeight: CGFloat = 52
        static let menuRowHeight: CGFloat = 30
        static let iconColumn: CGFloat = 26
        static let switchColumn: CGFloat = 40
        static let rowInset: CGFloat = 12
        static let tabHeight: CGFloat = 44
        static let tabIcon: CGFloat = 15
        static let tabRadius: CGFloat = 8
        /// Separators start after the icon column, the way grouped lists inset them.
        static let separatorInset: CGFloat = rowInset + iconColumn + Space.md
    }

    enum Size {
        static let dropdownWidth: CGFloat = 320
        static let iconTile: CGFloat = 28
        static let windowMin = CGSize(width: 680, height: 440)
        static let windowDefault = CGSize(width: 720, height: 480)
    }

    /// One curve for the whole app. Motion exists to explain what changed — a system utility
    /// that animates for its own sake feels slow.
    enum Motion {
        static let standard: Animation = .easeInOut(duration: 0.15)

        /// Pure, so the Reduce Motion contract is unit-testable rather than only observable by eye.
        static func resolved(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : standard
        }
    }
}

/// Applies `Theme.Motion` while honouring Reduce Motion.
///
/// This has to be a view modifier rather than a static: `\.accessibilityReduceMotion` is an
/// environment value, readable only inside a `View`. The previous version reached for
/// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` from a computed property, which put
/// an AppKit query inside every row's `body` — and never updated when the setting changed.
private struct StandardMotion<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(Theme.Motion.resolved(reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// Animate this view's changes to `value` with the app's one motion token.
    func standardMotion<V: Equatable>(value: V) -> some View {
        modifier(StandardMotion(value: value))
    }
}
