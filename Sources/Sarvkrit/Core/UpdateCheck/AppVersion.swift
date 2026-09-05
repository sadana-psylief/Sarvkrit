import Foundation

/// A release version, compared the way version numbers actually order.
///
/// String comparison gets this wrong in a way that only shows up later: `"1.10" < "1.9"`
/// lexicographically, so the tenth patch release of a line would silently read as older than the
/// ninth and nobody would ever be told to update. `String.compare(options: .numeric)` happens to
/// get that pair right, but it has no defined answer for `1.0` against `1.0.0` and no way to
/// refuse input it can't understand. Both cases are live here: `MARKETING_VERSION` is `1.1` today
/// and the next tag is `v1.1.0`.
///
/// The grammar is `scripts/release.sh`'s own — `^[0-9]+\.[0-9]+(\.[0-9]+)?$` — plus the `v` that
/// the git tag carries. Anything else returns nil rather than a guess, and a nil version means
/// the app says nothing at all. Being silent is the right failure: telling someone an update
/// exists when we can't actually read the version is worse than telling them nothing.
struct AppVersion: Comparable, CustomStringConvertible {
    /// Normalised to at least two components. Trailing zeros are kept rather than stripped —
    /// `padded(to:)` at comparison time is what makes `1.0` and `1.0.0` equal, and doing it there
    /// rather than here keeps `description` faithful to what was parsed.
    let components: [Int]

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tags are `v1.0`; MARKETING_VERSION is `1.0`. Accept both, from either side.
        let stripped = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        guard !stripped.isEmpty else { return nil }

        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 4 else { return nil }

        var parsed: [Int] = []
        for part in parts {
            // `Int(...)` alone would accept "+1" and "-1"; a version component is digits only.
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            parsed.append(value)
        }
        self.components = parsed
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: width).lexicographicallyPrecedes(rhs.padded(to: width))
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: width) == rhs.padded(to: width)
    }

    /// The running app's own version, from `CFBundleShortVersionString`.
    ///
    /// Deliberately not `CFBundleVersion`: `release.sh` sets both to the same dotted string, so
    /// they agree today, but only the short string is *defined* to be the marketing version.
    static func current(bundle: Bundle = .main) -> AppVersion? {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(AppVersion.init)
    }
}
