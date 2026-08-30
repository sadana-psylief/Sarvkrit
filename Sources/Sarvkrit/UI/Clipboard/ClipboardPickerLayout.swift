import CoreGraphics
import Foundation

/// How tall the picker should be for what it's showing.
///
/// Pure, so the thing that's normally only checkable by eye gets real tests — including that a
/// 200-entry history doesn't ask for a 2,000pt panel.
enum ClipboardPickerLayout {
    static let width: CGFloat = 380
    static let searchFieldHeight: CGFloat = 38
    /// The hairline under the search field.
    static let dividerHeight: CGFloat = 1
    static let listVerticalPadding: CGFloat = 6

    /// Enough for the search field plus the "Nothing copied yet" line.
    static let minimumHeight: CGFloat = 130
    /// Past this the list scrolls. A panel taller than this stops feeling like a popover.
    static let maximumHeight: CGFloat = 460

    // MARK: - Row metrics

    /// A single line of text needs nothing like the 40pt it used to get — that height existed to
    /// accommodate a subtitle line which, for most entries, was empty.
    static let singleLineRowHeight: CGFloat = 30
    static let twoLineRowHeight: CGFloat = 44
    /// One column for every kind of leading element — app icon, thumbnail or fallback symbol — so
    /// the text's left edge doesn't shift depending on whether the source app resolved.
    static let iconColumnWidth: CGFloat = 18

    static func rowHeight(for item: ClipboardItem, settings: ClipboardSettings) -> CGFloat {
        if case .image = item.kind {
            return max(singleLineRowHeight, CGFloat(settings.imageRowHeight) + 10)
        }
        return hasSubtitle(item, settings: settings) ? twoLineRowHeight : singleLineRowHeight
    }

    /// Whether there is anything to put on a second line. Rendering an empty `Text` still consumes
    /// a line, which is what pushed every title up off-centre.
    static func hasSubtitle(_ item: ClipboardItem, settings: ClipboardSettings) -> Bool {
        if item.copyCount > 1 { return true }
        if !settings.showAppIcons, item.sourceBundleID != nil { return true }
        switch item.kind {
        case .image, .files, .largeText: return true
        case .text, .richText: return false
        }
    }

    // MARK: - Panel

    static func panelHeight(for items: [ClipboardItem], settings: ClipboardSettings) -> CGFloat {
        let rows = items.reduce(CGFloat(0)) { $0 + rowHeight(for: $1, settings: settings) }
        let content = searchFieldHeight + dividerHeight + rows + listVerticalPadding * 2
        return min(max(content, minimumHeight), maximumHeight)
    }

    static func panelSize(for items: [ClipboardItem], settings: ClipboardSettings) -> CGSize {
        CGSize(width: width, height: panelHeight(for: items, settings: settings))
    }
}
