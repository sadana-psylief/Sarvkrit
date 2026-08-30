import Foundation

/// Expands rename/subfolder patterns like `{date:yyyy-MM}/{name}-{counter}.{ext}`.
///
/// Pure input → output, so the entire token grammar is table-testable without touching disk. The
/// same expander serves both `rename` and `sortIntoSubfolder`, which is why a pattern may contain
/// path separators.
enum RenamePattern {
    /// Everything a token can draw on.
    struct Context {
        var file: FileSnapshot
        /// Capture groups from a `matchesRegex` condition, 1-based via `{match:1}`.
        var regexCaptures: [String] = []
        /// Supplied by the action runner when resolving a name collision.
        var counter: Int = 1
        var now: Date = Date()
    }

    /// Unknown tokens are left **verbatim** rather than dropped. A typo'd `{nmae}` should be
    /// visible in the result — a silently empty filename is far harder to diagnose.
    static func expand(_ pattern: String, context: Context) -> String {
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

    /// Which tokens the editor can offer, and what each means.
    static let documentedTokens: [(token: String, description: String)] = [
        ("{name}", "Filename without extension"),
        ("{ext}", "File extension"),
        ("{fullname}", "Filename including extension"),
        ("{counter}", "Number that increments to avoid collisions"),
        ("{date:FORMAT}", "File's modification date, e.g. {date:yyyy-MM-dd}"),
        ("{now:FORMAT}", "Today's date, e.g. {now:yyyy}"),
        ("{kind}", "Image, Video, Document, …"),
        ("{match:N}", "Capture group N from a regex condition"),
    ]

    private static func value(for token: String, context: Context) -> String? {
        if let range = token.range(of: ":") {
            let name = String(token[token.startIndex..<range.lowerBound]).lowercased()
            let argument = String(token[range.upperBound...])
            return parameterized(name, argument: argument, context: context)
        }

        switch token.lowercased() {
        case "name": return context.file.name
        case "ext": return context.file.fileExtension
        case "fullname": return context.file.fullName
        case "counter": return String(context.counter)
        case "kind": return context.file.kind.title
        default: return nil
        }
    }

    private static func parameterized(
        _ name: String,
        argument: String,
        context: Context
    ) -> String? {
        switch name {
        case "date": return format(context.file.dateModified, argument)
        case "now": return format(context.now, argument)
        case "match":
            // 1-based to match how people talk about capture groups.
            guard let index = Int(argument), index >= 1, index <= context.regexCaptures.count else {
                return nil
            }
            return context.regexCaptures[index - 1]
        default:
            return nil
        }
    }

    private static func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        // Fixed locale and calendar: a rule that files into "2026-08" must not become "٢٠٢٦-٠٨"
        // because of the user's region, or the folder structure fragments.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = template
        return formatter.string(from: date)
    }

    /// Strips characters that can't appear in a filename, so an expanded pattern can't produce an
    /// unwritable name or escape its directory.
    static func sanitizeComponent(_ component: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\0")
        let cleaned = component.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // "." and ".." would resolve to a directory rather than a name.
        return (trimmed.isEmpty || trimmed == "." || trimmed == "..") ? "untitled" : trimmed
    }
}
