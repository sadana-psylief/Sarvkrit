import Foundation

/// One word, with the timing the recogniser gave it.
///
/// `SFSpeechRecognizer` hands back per-word `timestamp` and `duration`, which is the only reason
/// word-level highlighting is possible at all — it is not something the app could work out.
struct TranscriptWord: Codable, Equatable {
    var text: String
    var start: TimeInterval
    var duration: TimeInterval

    var end: TimeInterval { start + duration }
}

/// One line of captions.
struct Caption: Codable, Equatable, Identifiable {
    var id = UUID()
    var words: [TranscriptWord]

    var start: TimeInterval { words.first?.start ?? 0 }
    var end: TimeInterval { words.last?.end ?? 0 }
    var text: String { words.map(\.text).joined(separator: " ") }

    /// How many words have been spoken by `t`.
    ///
    /// The renderer draws this many in the spoken colour and the rest in the upcoming one, which is
    /// the karaoke effect. A word counts as spoken the moment it *starts* — waiting for it to
    /// finish puts the highlight permanently behind the voice.
    func spokenWordCount(at t: TimeInterval) -> Int {
        words.filter { $0.start <= t }.count
    }
}

/// Breaking a stream of timed words into lines worth reading.
///
/// **This is where caption quality lives.** The recogniser decides the words; where the lines break
/// decides whether anyone can read them. The answer is the one a person would give: at a breath, at
/// a full stop, and never so long that the eye has to travel.
enum CaptionGrouper {

    struct Tuning: Equatable {
        /// A gap longer than this is where the speaker drew breath.
        var pause: TimeInterval = 0.45
        /// Roughly two seconds of reading at a comfortable size.
        var maximumCharacters: Int = 42
        var maximumWords: Int = 9
        /// Sentence enders. A line that runs past a full stop reads as two thoughts at once.
        var terminators: Set<Character> = [".", "!", "?"]

        init() {}
    }

    static func lines(from words: [TranscriptWord], tuning: Tuning = Tuning()) -> [Caption] {
        guard !words.isEmpty else { return [] }

        var lines: [[TranscriptWord]] = []
        var current: [TranscriptWord] = []

        func flush() {
            guard !current.isEmpty else { return }
            lines.append(current)
            current = []
        }

        for word in words {
            if let previous = current.last {
                let drewBreath = word.start - previous.end > tuning.pause
                let sentenceEnded = previous.text.last.map { tuning.terminators.contains($0) }
                    ?? false
                let wouldBeTooLong = characterCount(current) + word.text.count + 1
                    > tuning.maximumCharacters
                let wouldBeTooMany = current.count + 1 > tuning.maximumWords

                if drewBreath || sentenceEnded || wouldBeTooLong || wouldBeTooMany { flush() }
            }
            current.append(word)
        }
        flush()

        return mergingOrphans(lines).map { Caption(words: $0) }
    }

    private static func characterCount(_ words: [TranscriptWord]) -> Int {
        guard !words.isEmpty else { return 0 }
        return words.reduce(0) { $0 + $1.text.count } + words.count - 1
    }

    /// A line holding a single word looks like a mistake on screen, so it is pulled back onto the
    /// line before it. Merging backwards rather than forwards keeps the break at the pause or the
    /// full stop that caused it, which is the one the reader can hear.
    private static func mergingOrphans(_ lines: [[TranscriptWord]]) -> [[TranscriptWord]] {
        guard lines.count > 1 else { return lines }
        var result: [[TranscriptWord]] = []
        for line in lines {
            if line.count == 1, var previous = result.popLast() {
                previous.append(contentsOf: line)
                result.append(previous)
            } else {
                result.append(line)
            }
        }
        return result
    }
}
