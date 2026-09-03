import AppKit
import SwiftUI

/// The look of everything that floats over a capture.
///
/// **Deliberately dark in both appearances, unlike the rest of the app.** Sarvkrit's settings
/// follow the system theme because they sit among other windows; capture chrome sits on top of
/// *the user's screen*, which is arbitrary content. A surface that turned white in light mode
/// would fight whatever is behind it and read as part of the page being captured rather than as a
/// tool over it. Every screen-capture tool worth copying makes the same choice.
///
/// These are the only numbers the capture UI is allowed to invent, the same rule `Theme` sets for
/// the settings surfaces.
enum CaptureChrome {

    enum Metrics {
        /// Radius of the floating bars. Measured at 0.26 × height — noticeably **not** a capsule,
        /// which is the first thing that goes wrong when you eyeball this shape.
        static let barRadius: CGFloat = 16
        static let barPadding: CGFloat = 6
        /// Gap between two adjacent bars, e.g. the mode bar and the size bar.
        static let barGap: CGFloat = 16

        /// One mode cell: icon over label. Measured 67 × 50 with a 10pt gap; taken slightly
        /// larger here because our longest label ("Fullscreen") needs the room.
        static let cellWidth: CGFloat = 72
        static let cellHeight: CGFloat = 54
        static let cellGap: CGFloat = 10
        static let cellRadius: CGFloat = 10

        static let iconSize: CGFloat = 20
        static let dividerHeight: CGFloat = 40
        static let fieldRadius: CGFloat = 6

        /// The post-capture thumbnail.
        static let thumbnailWidth: CGFloat = 220
        static let thumbnailRadius: CGFloat = 12
        /// Inset from the screen corner it is anchored to.
        static let thumbnailInset: CGFloat = 20
        static let thumbnailGap: CGFloat = 10
    }

    enum Colours {
        /// Measured as #272727 at about 90% over a HUD blur — considerably more opaque than a
        /// translucent panel looks like it should be. At 55% the bar washed out over bright
        /// content and the labels stopped being readable.
        static let surface = Color(red: 0.153, green: 0.153, blue: 0.153).opacity(0.9)
        /// A light hairline just inside, and a dark one just outside. The outer ring is what
        /// separates the bar from a light wallpaper; without it the shape dissolves.
        static let borderInner = Color.white.opacity(0.08)
        static let borderOuter = Color.black.opacity(0.7)

        /// Hover and selection share a fill — what marks the selection is the label going to full
        /// white. Two different fills read as two different kinds of state.
        static let cellHover = Color.white.opacity(0.05)
        static let cellSelected = Color.white.opacity(0.05)

        static let label = Color.white.opacity(0.8)
        static let labelStrong = Color.white
        static let icon = Color.white
        static let divider = Color.white.opacity(0.05)
        /// An inset field, e.g. a dimension box.
        static let field = Color(red: 0.118, green: 0.118, blue: 0.122)

        /// Everything outside the selection while choosing an area.
        static let selectionDim = Color.black.opacity(0.5)
    }

    enum Text {
        static let label = Font.system(size: 13, weight: .regular)
        static let value = Font.system(size: 14, weight: .regular).monospacedDigit()
        static let caption = Font.system(size: 12, weight: .regular)
    }

    /// The shared background for a floating bar: a real blur, a dark wash over it, and a hairline.
    struct Bar<Content: View>: View {
        var radius: CGFloat = Metrics.barRadius
        @ViewBuilder var content: Content

        var body: some View {
            content
                // Order matters: the dark wash sits *over* the blur, not under it. The other way
                // round the blur tints everything behind, which on bright content leaves the bar
                // washed out and unreadable.
                .background(Colours.surface)
                .background(VisualEffectBackground())
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .inset(by: 0.5)
                        .strokeBorder(Colours.borderInner, lineWidth: 1)
                )
                // The dark ring sits *outside* the shape. On a pale wallpaper the light hairline
                // alone disappears and the bar loses its edge entirely.
                .overlay(
                    RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                        .inset(by: -1)
                        .strokeBorder(Colours.borderOuter, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
    }
}

/// An `NSVisualEffectView` behind SwiftUI content.
///
/// SwiftUI's `.regularMaterial` adapts to the system appearance; this stays dark on purpose, for
/// the reason `CaptureChrome` records.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .vibrantDark)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
