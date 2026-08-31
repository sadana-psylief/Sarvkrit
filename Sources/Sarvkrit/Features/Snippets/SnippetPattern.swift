import Foundation

/// Expands `{token}`s in a snippet's replacement text.
///
/// A sibling of `RenamePattern`, not a reuse of it: that type's `Context` is built around a file on
/// disk, which a snippet has no notion of. What is deliberately shared is the **grammar** — the same
/// `{name}` and `{name:argument}` shape, and the same rule that an unknown token is left verbatim —
/// so the app teaches one token language rather than two that almost match.
///
/// Pure input → output, so the whole grammar is table-testable.
enum SnippetPattern {
    struct Context {
        var now: Date = Date()
        /// Locale for the *output*, not for interpreting the format string.
        ///
        /// This is where snippets deliberately differ from `RenamePattern`, which pins
        /// `en_US_POSIX` so a folder named `2026-08` can't fragment into `٢٠٢٦-٠٨` across regions.
        /// A snippet is text a person is about to send to another person, so `{date:EEEE}` should
        /// give them their own month and day names. Injectable so tests stay deterministic.
        var locale: Locale = .current
        var calendar: Calendar = .current
    }

    /// Unknown tokens are left **verbatim** rather than dropped — a typo'd `{dat:yyyy}` should be
    /// visible in what got typed, because silently expanding to nothing is far harder to diagnose.
    static func expand(_ pattern: String, context: Context = Context()) -> String {
        var result = ""
        var remainder = Substring(pattern)

        while let open = remainder.firstIndex(of: "{") {
            result += remainder[remainder.startIndex..<open]
            let afterOpen = remainder.index(after: open)

            guard let close = remainder[afterOpen...].firstIndex(of: "}") else {
                // Unbalanced brace: emit the rest as literal text.
                result += remainder[open...]
                return result
            }

            let token = String(remainder[afterOpen..<close])
            result += value(for: token, context: context) ?? "{\(token)}"
            remainder = remainder[remainder.index(after: close)...]
        }

        result += remainder
        return result
    }

    /// Whether expanding this pattern depends on when it runs — the editor uses it to decide
    /// whether the preview needs to say "as of now".
    static func isDynamic(_ pattern: String) -> Bool {
        expand(pattern, context: Context(now: Date(timeIntervalSince1970: 0)))
            != expand(pattern, context: Context(now: Date(timeIntervalSince1970: 86_400)))
    }

    /// What the editor offers, and what each means.
    static let documentedTokens: [(token: String, description: String)] = [
        ("{date}", "Today, e.g. 31 August 2026"),
        ("{date:FORMAT}", "Today in a format you choose, e.g. {date:yyyy-MM-dd}"),
        ("{time}", "The current time, e.g. 13:45"),
        ("{now:FORMAT}", "Date and time in a format you choose, e.g. {now:HH:mm}"),
    ]

    private static func value(for token: String, context: Context) -> String? {
        if let range = token.range(of: ":") {
            let name = String(token[token.startIndex..<range.lowerBound]).lowercased()
            let argument = String(token[range.upperBound...])
            switch name {
            case "date", "now": return format(context.now, argument, context)
            default: return nil
            }
        }

        switch token.lowercased() {
        case "date": return styled(context.now, date: .long, time: .none, context)
        case "time": return styled(context.now, date: .none, time: .short, context)
        case "now": return styled(context.now, date: .long, time: .short, context)
        default: return nil
        }
    }

    private static func format(_ date: Date, _ template: String, _ context: Context) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.dateFormat = template
        return formatter.string(from: date)
    }

    /// The bare `{date}` / `{time}` forms use the system's own styles, so they read the way dates
    /// do everywhere else on the user's Mac rather than in a format we picked.
    private static func styled(
        _ date: Date,
        date dateStyle: DateFormatter.Style,
        time timeStyle: DateFormatter.Style,
        _ context: Context
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = context.locale
        formatter.calendar = context.calendar
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }
}
