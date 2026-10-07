import Foundation

/// The line protocol between Sarvkrit and its root fan helper.
///
/// Compiled into both, so there is one parser rather than two that agree until they don't.
///
/// **Deliberately not JSON, or a plist, or anything with a library behind it.** One end of this
/// conversation runs as root, and a root process should not be running a general-purpose
/// structured-format parser over bytes off a socket. This is thirty lines that accept four
/// commands and refuse everything else — including anything the app should never have sent, since
/// "the app is the only thing that should be connected" is not the same as "the app is the only
/// thing that can be".
enum FanWire {
    enum Command: Equatable {
        /// A percentage of each fan's own range. The helper re-clamps and maps it through each
        /// fan's `Mn`/`Mx` itself, so an out-of-range RPM is not expressible from here at all.
        case set(percent: Int)
        /// Hand the fans back to macOS.
        case auto
        case ping
        case quit
    }

    /// An unbounded line is an unbounded allocation in a process running as root.
    static let maximumLineLength = 64

    static func encode(_ command: Command) -> String {
        switch command {
        case let .set(percent): return "SET \(percent)\n"
        case .auto: return "AUTO\n"
        case .ping: return "PING\n"
        case .quit: return "QUIT\n"
        }
    }

    static func parse(_ line: String) -> Command? {
        // Length first, before anything looks at the contents.
        let bytes = Array(line.utf8)
        guard bytes.count <= maximumLineLength else { return nil }

        // One trailing newline is the terminator; any other control byte is smuggling.
        var body = bytes
        if body.last == 0x0A { body.removeLast() }
        guard body.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }

        let text = String(decoding: body, as: UTF8.self)
        switch text {
        case "AUTO": return .auto
        case "PING": return .ping
        case "QUIT": return .quit
        default: break
        }

        // Exactly two fields, no more: a parser that shrugs at trailing bytes is one that can be
        // talked into ignoring the part that mattered.
        let fields = text.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "SET" else { return nil }
        // `Int(_:)` rejects "70.5", "seventy", "" and anything that would overflow.
        guard let percent = Int(fields[1]), (0...100).contains(percent) else { return nil }
        return .set(percent: percent)
    }
}
