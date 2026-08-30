import Foundation

/// Filtering and ranking the clipboard history.
///
/// Pure, and it returns the **matched character ranges** alongside each hit. Computing them here
/// rather than in the row keeps exact and fuzzy consistent, and means the highlighting can't drift
/// from what actually matched.
enum ClipboardSearch {
    enum Mode: String, Codable, CaseIterable {
        case exact
        case fuzzy

        var title: String {
            switch self {
            case .exact: return "Exact"
            case .fuzzy: return "Fuzzy"
            }
        }
    }

    struct Match: Equatable {
        var score: Int
        /// Offsets into the **searched** string. The row must render that same string, or the
        /// bolding lands on the wrong characters.
        var ranges: [Range<String.Index>]
    }

    static func match(query: String, in text: String, mode: Mode) -> Match? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Match(score: 0, ranges: []) }

        switch mode {
        case .exact: return exactMatch(trimmed, in: text)
        case .fuzzy: return fuzzyMatch(trimmed, in: text)
        }
    }

    // MARK: - Exact

    private static func exactMatch(_ query: String, in text: String) -> Match? {
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else { return nil }
        // Earlier matches rank higher; a hit at the very start is what you usually meant.
        let distance = text.distance(from: text.startIndex, to: range.lowerBound)
        return Match(score: 1_000 - min(distance, 900), ranges: [range])
    }

    // MARK: - Fuzzy

    /// Subsequence match: every character of the query appears in order, not necessarily adjacent.
    /// `invpdf` finds `invoice-2026.pdf`.
    ///
    /// Scoring rewards runs of adjacent characters and matches at word starts, so the result that
    /// looks most like what you typed sorts above one that merely contains the letters scattered.
    private static func fuzzyMatch(_ query: String, in text: String) -> Match? {
        let haystack = Array(text)
        let needle = Array(query.lowercased())
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }

        var ranges: [Range<String.Index>] = []
        var score = 0
        var needleIndex = 0
        var previousMatchPosition = -2
        var runLength = 0

        for (position, character) in haystack.enumerated() {
            guard needleIndex < needle.count else { break }
            guard String(character).lowercased() == String(needle[needleIndex]) else { continue }

            if position == previousMatchPosition + 1 {
                // Adjacency is weighted heavily and compounds, because a run of consecutive
                // characters is the strongest signal that this is the thing you meant. It has to
                // outweigh the word-start bonus below: in a string like "i-n-v-x-y-z" every
                // separator makes the next letter a "word start", and a gentler adjacency bonus
                // let that scattered match outrank a clean "inv" in "invoice".
                runLength += 1
                score += 12 + runLength * 4
            } else {
                runLength = 0
                score += 1
            }
            // A match at the start of a word is more likely to be intentional.
            let isWordStart = position == 0 || !haystack[position - 1].isLetter
            if isWordStart { score += 10 }

            let lower = text.index(text.startIndex, offsetBy: position)
            let upper = text.index(after: lower)
            // Merge with the previous range when adjacent, so a run renders as one bold span.
            if let last = ranges.last, last.upperBound == lower {
                ranges[ranges.count - 1] = last.lowerBound..<upper
            } else {
                ranges.append(lower..<upper)
            }

            previousMatchPosition = position
            needleIndex += 1
        }

        guard needleIndex == needle.count else { return nil }
        // Shorter haystacks are better matches for the same query.
        score += max(0, 50 - haystack.count / 4)
        return Match(score: score, ranges: ranges)
    }
}

/// How the history is ordered for display.
enum ClipboardSortMode: String, Codable, CaseIterable {
    case lastCopy
    case firstCopy
    case copyCount

    var title: String {
        switch self {
        case .lastCopy: return "Time of last copy"
        case .firstCopy: return "Time of first copy"
        case .copyCount: return "Number of copies"
        }
    }
}

/// Where pinned entries sit relative to the rolling history.
enum PinnedPosition: String, Codable, CaseIterable {
    case top
    case bottom

    var title: String {
        switch self {
        case .top: return "Top"
        case .bottom: return "Bottom"
        }
    }
}

extension Array where Element == ClipboardItem {
    /// Sorts by the chosen mode, with pinned entries grouped to the top or bottom.
    func sorted(by mode: ClipboardSortMode, pinned position: PinnedPosition) -> [ClipboardItem] {
        func order(_ items: [ClipboardItem]) -> [ClipboardItem] {
            switch mode {
            case .lastCopy: return items.sorted { $0.createdAt > $1.createdAt }
            case .firstCopy: return items.sorted { $0.firstCopiedAt > $1.firstCopiedAt }
            case .copyCount:
                // Ties broken by recency, so equal-count entries stay in a sensible order rather
                // than shuffling on every redraw.
                return items.sorted {
                    $0.copyCount == $1.copyCount ? $0.createdAt > $1.createdAt : $0.copyCount > $1.copyCount
                }
            }
        }

        let pinnedItems = order(filter(\.isPinned))
        let rest = order(filter { !$0.isPinned })
        return position == .top ? pinnedItems + rest : rest + pinnedItems
    }
}
