import AppKit
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
        /// Hover and selection fills behind something smaller than a card — a menu row, a tab.
        static let control: CGFloat = 6
        /// Anything fully rounded: status pills, meter bars. Large rather than computed, because
        /// `RoundedRectangle` clamps to half the smaller side and a capsule is what that gives.
        static let pill: CGFloat = 999
    }

    /// The type scale.
    ///
    /// These are not new sizes — they are the seven the app had already settled on across some
    /// fifty call sites, given names so a panel row and a settings row agree by construction
    /// rather than by coincidence. Weights stay at the call site: the same size is regular in a
    /// caption and semibold in a header, and folding that in would need a token per pairing.
    enum Typography {
        /// Tracked uppercase section labels — `SectionHeader`.
        static let section: CGFloat = 10
        /// Secondary text under a title, and anything tertiary.
        static let caption: CGFloat = 11
        /// The default for a row's own text.
        static let body: CGFloat = 12
        /// A row title, and the app name in the panel header.
        static let title: CGFloat = 13
        /// A live number sitting beside a meter. Large enough to read at a glance from the menu
        /// bar, small enough that a row stays one line.
        static let metric: CGFloat = 15
        /// A tile's headline number — a temperature, a wattage.
        static let stat: CGFloat = 20
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
        static let tabIcon: CGFloat = 15
        static let tabRadius: CGFloat = 8
        /// Separators start after the icon column, the way grouped lists inset them.
        static let separatorInset: CGFloat = rowInset + iconColumn + Space.md

        /// An icon-only tab. Square, because there is no longer a label to set the width, and 34
        /// so the 15pt glyph keeps a comfortable margin without the strip dominating the panel.
        static let tabSquare: CGFloat = 34
        /// A row inside a panel card: taller than a menu row because it carries a meter or a
        /// slider, shorter than a toggle row because it has no caption line to reserve.
        static let panelRowHeight: CGFloat = 34
        /// The track of a `MeterBar`. Thin enough to read as a measure rather than a control —
        /// nothing here is draggable.
        static let meterHeight: CGFloat = 6
    }

    enum Size {
        /// The panel's width, and no longer a function of the tab count.
        ///
        /// It used to be. Tabs carried a label, so each new one squeezed every other, and this
        /// constant grew 320 → 360 → 420 → 480 chasing a legible width for the longest word. Tabs
        /// are icons now: they are a fixed 34pt square each, and nine of them occupy 330pt of any
        /// width at all. So this is chosen for the *content* instead — 420 is what a two-column
        /// `SplitStat` and a 110pt app name beside a slider both want, and adding a tenth panel
        /// will not change it.
        static let dropdownWidth: CGFloat = 420
        /// How tall a panel's content may grow before it scrolls inside itself.
        ///
        /// The Features panel lists every feature in the app — eighteen rows and seven headers,
        /// well over a thousand points — and the menu bar panel is anchored under the icon, so a
        /// panel taller than the screen has nowhere to go. Everything else stays well under this
        /// and never sees a scroller.
        static let panelMaxContentHeight: CGFloat = 420
        static let iconTile: CGFloat = 28
        static let windowMin = CGSize(width: 680, height: 440)
        static let windowDefault = CGSize(width: 720, height: 480)
    }

    /// One curve for the whole app. Motion exists to explain what changed — a system utility
    /// that animates for its own sake feels slow.
    enum Motion {
        /// The same curve as a scalar, for the one place motion is not a SwiftUI animation:
        /// `MenuBarWindowAnchor` animates an `NSWindow` frame through `NSAnimationContext`, which
        /// takes a duration and a `CAMediaTimingFunction`. `standard` is derived from it so the
        /// AppKit and SwiftUI halves of "one curve for the whole app" cannot drift apart.
        static let standardDuration: TimeInterval = 0.15

        static let standard: Animation = .easeInOut(duration: standardDuration)

        /// Longer than `standard`, and the one motion in the app that earns it.
        ///
        /// The tray panel's height changes by up to 195pt between panels. At 0.15s that is
        /// ~1200pt/s, which does not read as movement — it reads as a jump that happens to be
        /// blurry, and the handful of frames a display can fit into 150ms at that speed land far
        /// enough apart to look like stepping. Everything else this token family covers moves a
        /// row height or a colour, where 0.15s is right.
        static let panelResizeDuration: TimeInterval = 0.25

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
    /// Hand cursor over anything that responds to a click.
    ///
    /// Nothing in this app used to change the cursor at all, so custom `.buttonStyle(.plain)`
    /// controls — tray tabs, menu rows, section headers — gave no sign they were clickable.
    ///
    /// `.pointerStyle` is macOS 15+ and the deployment target is 14.0, hence the gate. The
    /// fallback uses `set()` rather than `push()`/`pop()` deliberately: a missed exit event would
    /// leave an unbalanced cursor stack, and a hand cursor stuck over the whole screen is worse
    /// than never having one.
    @ViewBuilder
    func clickableCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
        }
    }

    /// Animate this view's changes to `value` with the app's one motion token.
    func standardMotion<V: Equatable>(value: V) -> some View {
        modifier(StandardMotion(value: value))
    }
}
