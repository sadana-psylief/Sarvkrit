import Foundation

/// Naming a saved capture.
///
/// Pure, because the two rules that matter are both invisible until they bite: a name that
/// contains a path separator quietly writes somewhere else, and two captures in the same second
/// overwrite each other.
enum CaptureFilename {

    /// Tokens a pattern may use. Kept small on purpose — a template language is not the point.
    static let tokens = ["{date}", "{time}", "{mode}", "{n}"]
    static let defaultPattern = "Screenshot {date} at {time}"

    /// Builds a file name (without extension) from a pattern.
    ///
    /// - Parameter counter: appended by `{n}`, and also used to break ties when the pattern
    ///   doesn't include one — see `unique(...)`.
    static func make(pattern: String,
                     mode: CaptureMode,
                     date: Date,
                     counter: Int = 0,
                     calendar: Calendar = .current,
                     timeZone: TimeZone = .current) -> String {
        var formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")

        formatter.dateFormat = "yyyy-MM-dd"
        let dateText = formatter.string(from: date)
        // Dots rather than colons: a colon is a path separator to the Finder, which silently
        // renders "10:30:00" as a folder-looking name in the sidebar and breaks scripts.
        formatter.dateFormat = "HH.mm.ss"
        let timeText = formatter.string(from: date)

        var name = pattern
            .replacingOccurrences(of: "{date}", with: dateText)
            .replacingOccurrences(of: "{time}", with: timeText)
            .replacingOccurrences(of: "{mode}", with: mode.title)
            .replacingOccurrences(of: "{n}", with: String(counter))

        name = sanitised(name)
        // An empty pattern, or one that was nothing but illegal characters, would write a
        // dotfile called ".png".
        return name.isEmpty ? "Screenshot" : name
    }

    /// Strips anything that can't safely be a file name.
    ///
    /// **The `/` case is the one that matters.** A name containing a separator doesn't fail — it
    /// writes to a different directory, or silently fails to write at all. Dots and dashes are
    /// then trimmed from both ends, which does two jobs: a leading dot would make the file
    /// invisible in the Finder, and a name that was *nothing but* separators collapses to empty
    /// so the caller can fall back rather than producing a file called "---.png".
    static func sanitised(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\0")
        let replaced = name.components(separatedBy: illegal).joined(separator: "-")
        // Collapse runs, so "a///b" is "a-b" rather than "a---b".
        let collapsed = replaced
            .components(separatedBy: "-")
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".- \t\n"))
    }

    /// A name that isn't taken yet, suffixed " 2", " 3" and so on.
    ///
    /// Two captures in the same second are ordinary — a burst of ⌃⇧A — and the default pattern is
    /// only accurate to the second, so without this the second one silently replaces the first.
    static func unique(base: String,
                       extension ext: String,
                       in directory: URL,
                       exists: (URL) -> Bool) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var suffix = 2
        while exists(candidate) {
            candidate = directory.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
            // A directory with thousands of same-named files is pathological; stop rather than
            // spin, and let the write overwrite.
            if suffix > 1_000 { break }
        }
        return candidate
    }
}
