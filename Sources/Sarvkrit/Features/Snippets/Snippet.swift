import Foundation

/// One abbreviation and what it expands to.
struct Snippet: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    /// What the user types. Compared case-sensitively — `;addr` and `;ADDR` are different triggers,
    /// because a snippet is a deliberate token rather than a word being autocorrected.
    var trigger: String
    /// What replaces it. May contain `{token}`s — see `SnippetPattern`.
    var expansion: String
    var style: Style = .prefix
    var isEnabled: Bool = true

    /// When a trigger is considered complete.
    enum Style: String, Codable, CaseIterable, Identifiable {
        /// Fires the instant the trigger matches. Safe because the trigger starts with a marker no
        /// ordinary word does — `;addr`.
        case prefix
        /// Waits for a word boundary — space, tab, return, punctuation. Needed when the trigger is
        /// a bare word, where firing immediately would break "addr" inside "address".
        case wordBoundary

        var id: String { rawValue }

        var title: String {
            switch self {
            case .prefix: return "Expand immediately"
            case .wordBoundary: return "Expand after a space"
            }
        }

        var explanation: String {
            switch self {
            case .prefix:
                return "Fires as soon as the trigger is typed. Best for triggers that start with a "
                     + "marker like ; or : — nothing else will match them by accident."
            case .wordBoundary:
                return "Waits for a space, tab, return or punctuation. Use this for triggers that "
                     + "are ordinary words, so typing them inside a longer word doesn't expand."
            }
        }
    }

    /// A trigger that could never fire, so the editor can say so instead of saving a dead row.
    var validationProblem: String? {
        if trigger.isEmpty { return "Give the snippet a trigger to type." }
        if expansion.isEmpty { return "Give the snippet something to expand to." }
        if trigger.contains(where: \.isNewline) { return "A trigger can't contain a line break." }
        if trigger.contains(" ") && style == .wordBoundary {
            return "A trigger with a space can't expand on a space. Use “Expand immediately”."
        }
        // Expanding to something containing the trigger would re-match on the next keystroke.
        if style == .prefix, expansion.hasPrefix(trigger) {
            return "The expansion starts with the trigger, which would expand again."
        }
        return nil
    }
}
