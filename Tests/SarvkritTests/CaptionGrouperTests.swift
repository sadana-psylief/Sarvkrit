import XCTest
@testable import Sarvkrit

/// Breaking a stream of timed words into caption lines.
///
/// This is where caption *quality* lives. A recogniser hands back words and timings; whether the
/// result reads well is entirely a matter of where the lines break, and the answer is the same one
/// a person would give: at a breath, at a full stop, and never so long that the eye has to travel.
final class CaptionGrouperTests: XCTestCase {

    /// Words at a steady pace, `gap` apart, unless a word is followed by an explicit pause.
    private func words(_ text: String, from start: TimeInterval = 0,
                       gap: TimeInterval = 0.3) -> [TranscriptWord] {
        var t = start
        return text.split(separator: " ").map { piece -> TranscriptWord in
            let word = TranscriptWord(text: String(piece), start: t, duration: gap * 0.8)
            t += gap
            return word
        }
    }

    func testNoWordsMakeNoCaptions() {
        XCTAssertTrue(CaptionGrouper.lines(from: []).isEmpty)
    }

    func testAShortPhraseIsOneLine() {
        XCTAssertEqual(CaptionGrouper.lines(from: words("you press command")).count, 1)
    }

    /// **Every word, exactly once, in order.** A grouper that drops or duplicates a word produces
    /// captions that are subtly wrong in a way nobody proof-reads for.
    func testEveryWordSurvivesExactlyOnce() {
        let source = words("the quick brown fox jumps over the lazy dog again and again today")
        let regrouped = CaptionGrouper.lines(from: source).flatMap(\.words)
        XCTAssertEqual(regrouped.map(\.text), source.map(\.text))
    }

    /// A pause is where a person would breathe, and therefore where a line should end.
    func testALongPauseBreaksTheLine() {
        var source = words("down here")
        let later = words("and now we format it", from: 5)
        source.append(contentsOf: later)
        XCTAssertEqual(CaptionGrouper.lines(from: source).count, 2)
    }

    func testAFullStopBreaksTheLine() {
        let source = words("show US dollars. now the next thing")
        XCTAssertGreaterThan(CaptionGrouper.lines(from: source).count, 1)
    }

    func testALongRunIsBrokenUp() {
        let source = words(String(repeating: "alpha ", count: 30))
        let lines = CaptionGrouper.lines(from: source)
        XCTAssertGreaterThan(lines.count, 2)
    }

    func testNoLineExceedsTheCharacterBudgetByMuch() {
        let source = words(String(repeating: "alpha ", count: 40))
        let tuning = CaptionGrouper.Tuning()
        for line in CaptionGrouper.lines(from: source) {
            let characters = line.words.map(\.text).joined(separator: " ").count
            XCTAssertLessThanOrEqual(characters, tuning.maximumCharacters + 12)
        }
    }

    func testNoLineExceedsTheWordBudget() {
        let source = words(String(repeating: "a ", count: 40))
        let tuning = CaptionGrouper.Tuning()
        for line in CaptionGrouper.lines(from: source) {
            XCTAssertLessThanOrEqual(line.words.count, tuning.maximumWords)
        }
    }

    /// A line holding one word looks like a mistake on screen.
    func testASingleWordIsNotLeftStranded() {
        let source = words(String(repeating: "alpha ", count: 19))
        for line in CaptionGrouper.lines(from: source) where line.words.count == 1 {
            XCTFail("a caption was left with one word")
        }
    }

    func testALineIsTimedFromItsWords() {
        let source = words("you press command and drag")
        guard let line = CaptionGrouper.lines(from: source).first,
              let first = line.words.first, let last = line.words.last else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(line.start, first.start, accuracy: 0.0001)
        XCTAssertEqual(line.end, last.start + last.duration, accuracy: 0.0001)
    }

    func testLinesComeBackInOrder() {
        let source = words(String(repeating: "alpha ", count: 30))
        let starts = CaptionGrouper.lines(from: source).map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    // MARK: - Karaoke

    /// Word-level highlighting is the thing that makes these captions look expensive, and it is
    /// only possible because the recogniser gives per-word timings.
    func testTheSpokenWordCountRisesThroughTheLine() {
        let line = CaptionGrouper.lines(from: words("you press command and drag it")).first
        XCTAssertEqual(line?.spokenWordCount(at: -1), 0)
        XCTAssertEqual(line?.spokenWordCount(at: 100), line?.words.count)
    }

    func testAWordCountsAsSpokenOnceItHasStarted() {
        let source = words("you press command")
        let line = CaptionGrouper.lines(from: source).first
        XCTAssertEqual(line?.spokenWordCount(at: source[1].start + 0.01), 2)
    }
}
