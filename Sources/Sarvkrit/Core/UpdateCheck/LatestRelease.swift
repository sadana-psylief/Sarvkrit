import Foundation

/// The fields we use out of GitHub's `/releases/latest` payload.
///
/// The launchd job writes GitHub's response to disk verbatim and this decodes it, rather than the
/// script extracting fields itself. That split is deliberate: `jq` only ships from macOS 15 and
/// the deployment target is 14.4, and the alternatives (`python3` is a Command Line Tools shim
/// that can prompt to install Xcode) are worse. `JSONDecoder` is already used all over this app.
///
/// Everything except the tag is optional, and that is not defensiveness for its own sake — a
/// release published with no notes really does come back as `"body": null`, so a non-optional
/// `body` would be a decode failure waiting for the first sparse release. The tag is the only
/// field the feature cannot work without.
struct LatestRelease: Codable, Equatable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    /// Kept as the raw string rather than a `Date`. A date-format surprise would otherwise fail
    /// the whole decode and cost us the version, which is the one field that matters.
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    /// The version in the tag, or nil if it isn't one we can order. `/releases/latest` already
    /// excludes drafts and prereleases server-side, so there is nothing else to filter.
    var version: AppVersion? { AppVersion(tagName) }

    var notesURL: URL? { htmlURL.flatMap(URL.init(string:)) }

    /// The opening summary of the release notes — everything before the first section heading.
    ///
    /// Not the whole body. A GitHub release body for this project opens with a sentence or two of
    /// summary and then runs into install instructions, a checksum and the licence — and install
    /// instructions are the very last thing to show someone who has just been handed a one-line
    /// update command. The "Release notes" link covers anyone who wants the rest.
    ///
    /// Headings are also where the rendering falls down: the notice parses inline Markdown only,
    /// so `**bold**` and `code` come out right but a `## Install` line would show its hashes.
    /// Cutting at the first heading solves the noise and that at the same time.
    func displayNotes(limit: Int = 600) -> String? {
        guard let body else { return nil }
        var lead: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            // A space after the hashes, or nothing at all — otherwise "#1" and "#hashtag" would
            // read as headings.
            let isHeading = hashes > 0
                && (trimmed.count == hashes || trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes)] == " ")
            guard isHeading else {
                lead.append(line)
                continue
            }
            let haveProse = lead.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            // A single `#` before any prose is a title, not a section — releases often open with
            // one. Anything deeper, or any heading once prose has started, is where the summary
            // ends and the install instructions and licence begin.
            if !haveProse && hashes == 1 {
                lead.removeAll()
                continue
            }
            break
        }
        var text = lead.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > limit {
            text = String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return text
    }
}
