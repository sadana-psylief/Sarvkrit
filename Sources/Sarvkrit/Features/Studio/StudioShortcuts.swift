import AppKit
import Foundation

/// What the editor can do from the keyboard, as a value.
///
/// **⌘/ used to be routed to `break`** — recognised, deliberately silent, and so the one
/// discoverability hatch the editor had was nailed shut. Adding a zoom by hand has worked all along,
/// behind an unlabelled magnifying glass and the `Z` key, and was still reported as missing. That is
/// a fair report: a shortcut nobody can find does not exist.
///
/// Kept as data rather than as text in a view so `StudioShortcutsTests` can check every entry
/// against `StudioKeyRouting` and fail when the two drift.
enum StudioShortcuts {

    struct Entry: Identifiable {
        var id: String { title }
        var title: String
        /// What to print for the key, e.g. "Space", "⌘B", "1–9".
        var keyLabel: String
        /// The characters `StudioKeyRouting` matches on, for the test that keeps this honest.
        var characters: String
        var modifiers: NSEvent.ModifierFlags = []
        /// Listed, but not built. Better said out loud than silently omitted.
        var isUnavailable = false
        var note: String?
    }

    struct Group: Identifiable {
        var id: String { name }
        var name: String
        var entries: [Entry]
    }

    static let groups: [Group] = [
        Group(name: "Playing", entries: [
            Entry(title: "Play or Pause", keyLabel: "Space", characters: " "),
            Entry(title: "Nudge One Frame", keyLabel: ", / .", characters: ","),
            Entry(title: "Play Forwards, Faster", keyLabel: "L", characters: "l"),
            Entry(title: "Play Backwards", keyLabel: "J", characters: "j"),
            Entry(title: "Stop", keyLabel: "K", characters: "k"),
            Entry(title: "Loop Playback", keyLabel: "⌘L", characters: "l",
                  modifiers: .command),
        ]),
        Group(name: "Adding Things", entries: [
            Entry(title: "Add a Zoom Here", keyLabel: "Z", characters: "z",
                  note: "Right-click the timeline for clicks, highlights and the camera"),
            Entry(title: "Set the Zoom's Strength", keyLabel: "1–9", characters: "2"),
            Entry(title: "Split the Clip Here", keyLabel: "⌘B", characters: "b",
                  modifiers: .command),
            Entry(title: "Delete What's Selected", keyLabel: "⌫", characters: "\u{7F}"),
            Entry(title: "Delete and Close the Gap", keyLabel: "X", characters: "x"),
        ]),
        Group(name: "The Project", entries: [
            Entry(title: "Undo", keyLabel: "⌘Z", characters: "z", modifiers: .command),
            Entry(title: "Redo", keyLabel: "⇧⌘Z", characters: "z",
                  modifiers: [.command, .shift]),
            Entry(title: "Save", keyLabel: "⌘S", characters: "s", modifiers: .command),
            Entry(title: "Export", keyLabel: "⌘E", characters: "e", modifiers: .command),
            Entry(title: "Copy This Frame", keyLabel: "⌘C", characters: "c",
                  modifiers: .command),
            Entry(title: "Undo Every Edit", keyLabel: "⌘⌫", characters: "\u{7F}",
                  modifiers: .command),
            Entry(title: "Close", keyLabel: "⌘W", characters: "w", modifiers: .command),
        ]),
        Group(name: "Not Built Yet", entries: [
            Entry(title: "Set the In Point", keyLabel: "I", characters: "i",
                  isUnavailable: true,
                  note: "Trim by splitting with ⌘B and deleting instead"),
            Entry(title: "Set the Out Point", keyLabel: "O", characters: "o",
                  isUnavailable: true, note: nil),
        ]),
    ]

    static var all: [Entry] { groups.flatMap(\.entries) }
}
