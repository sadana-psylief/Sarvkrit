import Foundation

/// The emoji people actually put on a screenshot, and the short list of ones they used last.
///
/// **Why not just the system character palette.** The emoji tool used to call
/// `orderFrontCharacterPalette` and return — which opens a picker whose selection goes to the
/// first responder as *typed text*, and a canvas that is not a text field receives nothing. So the
/// tool opened a window and then did nothing at all. A picker that hands back a string is the only
/// version of this that can place a mark.
///
/// The catalogue is curated rather than exhaustive for the same reason a colour well shows eight
/// swatches and not a colour wheel: annotating a screenshot uses about forty of these, and
/// scrolling three thousand to find ✅ is slower than the thing being annotated.
enum EmojiCatalogue {

    struct Group: Identifiable, Equatable {
        let id: String
        let title: String
        let emoji: [String]
    }

    static let groups: [Group] = [
        Group(id: "marks", title: "Marks", emoji: [
            "✅", "❌", "⚠️", "❗️", "❓", "🚫", "✔️", "➖", "⭐️", "🔥", "💯", "🎯",
        ]),
        Group(id: "pointers", title: "Pointers", emoji: [
            "👉", "👈", "👆", "👇", "👍", "👎", "👀", "🖐", "✋", "🤙", "☝️", "🫵",
        ]),
        Group(id: "faces", title: "Faces", emoji: [
            "🙂", "😀", "😅", "😍", "🤔", "😐", "🙃", "😢", "😡", "🤯", "🥳", "😴",
        ]),
        Group(id: "status", title: "Status", emoji: [
            "🐛", "🚧", "🔒", "🔑", "⏱", "📌", "💡", "🧪", "🚀", "🩹", "📎", "🔍",
        ]),
    ]

    static let all: [String] = groups.flatMap(\.emoji)

    /// The one a fresh editor starts on.
    static let `default` = "👍"

    /// How many recents to keep. One row of the grid — a second row of things you touched once
    /// pushes the catalogue itself off screen, which is the opposite of the point.
    static let recentLimit = 12

    /// Moves `emoji` to the front, without letting it appear twice.
    ///
    /// Pure so the ordering rule is a test rather than something to verify by clicking twelve
    /// emoji and looking at a popover.
    static func recents(_ existing: [String], adding emoji: String) -> [String] {
        var updated = existing.filter { $0 != emoji }
        updated.insert(emoji, at: 0)
        return Array(updated.prefix(recentLimit))
    }
}

/// The recents list, persisted.
///
/// Its own tiny type rather than a `UserDefaults` read scattered through the view, so the editor
/// can be constructed in a test without touching the user's defaults.
@MainActor
final class EmojiRecents: ObservableObject {
    static let shared = EmojiRecents()

    private static let key = "screenshot.editor.recentEmoji"
    private let defaults: UserDefaults

    @Published private(set) var emoji: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.emoji = defaults.stringArray(forKey: Self.key) ?? []
    }

    func record(_ value: String) {
        emoji = EmojiCatalogue.recents(emoji, adding: value)
        defaults.set(emoji, forKey: Self.key)
    }
}
