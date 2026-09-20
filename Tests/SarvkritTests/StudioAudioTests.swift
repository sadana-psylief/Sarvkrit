import XCTest
@testable import Sarvkrit

/// Silence, typing bursts, loudness and ducking — all four over a plain amplitude envelope.
///
/// None of these opens an audio file. An envelope is an array of floats; a keystroke run is an
/// array of timestamps. Keeping the judgements at that level is what makes them adjustable without
/// an AVFoundation dependency in the test bundle, and it is the same reason `MixerLevels` and
/// `SoftClip` are testable today.
final class StudioAudioTests: XCTestCase {

    private func envelope(_ amplitude: Float, seconds: Double, rate: Double = 100) -> [Float] {
        [Float](repeating: amplitude, count: Int(seconds * rate))
    }

    // MARK: - Silence

    func testLoudAudioHasNoSilences() {
        XCTAssertTrue(SilenceDetector.silences(in: envelope(0.5, seconds: 5), sampleRate: 100)
            .isEmpty)
    }

    func testALongQuietStretchIsFound() {
        let signal = envelope(0.5, seconds: 1) + envelope(0.0001, seconds: 3)
            + envelope(0.5, seconds: 1)
        let found = SilenceDetector.silences(in: signal, sampleRate: 100)
        XCTAssertEqual(found.count, 1)
    }

    /// A breath between sentences is not dead air, and cutting it makes speech sound gasped.
    func testAShortGapIsLeftAlone() {
        let signal = envelope(0.5, seconds: 1) + envelope(0.0001, seconds: 0.3)
            + envelope(0.5, seconds: 1)
        XCTAssertTrue(SilenceDetector.silences(in: signal, sampleRate: 100).isEmpty)
    }

    /// Cutting exactly at the threshold clips the attack of the next word. The pad is what stops
    /// a de-silenced recording sounding like it was edited with a hatchet.
    func testTheDetectedRangeIsPaddedInFromBothEnds() {
        let signal = envelope(0.5, seconds: 1) + envelope(0.0001, seconds: 3)
            + envelope(0.5, seconds: 1)
        guard let range = SilenceDetector.silences(in: signal, sampleRate: 100).first else {
            return XCTFail("expected a silence")
        }
        let pad = SilenceDetector.Tuning().pad
        XCTAssertEqual(range.lowerBound, 1 + pad, accuracy: 0.05)
        XCTAssertEqual(range.upperBound, 4 - pad, accuracy: 0.05)
    }

    func testAnEmptyEnvelopeHasNoSilences() {
        XCTAssertTrue(SilenceDetector.silences(in: [], sampleRate: 100).isEmpty)
    }

    func testEverySilenceIsAtLeastTheMinimumLong() {
        let signal = envelope(0.5, seconds: 0.5) + envelope(0.0001, seconds: 0.8)
            + envelope(0.5, seconds: 0.5) + envelope(0.0001, seconds: 2)
        let tuning = SilenceDetector.Tuning()
        for range in SilenceDetector.silences(in: signal, sampleRate: 100) {
            XCTAssertGreaterThanOrEqual(range.upperBound - range.lowerBound,
                                        tuning.minimumDuration - tuning.pad * 2 - 0.02)
        }
    }

    // MARK: - Typing

    private func keys(from start: Double, count: Int, every gap: Double) -> [KeyEvent] {
        (0..<count).map {
            KeyEvent(t: start + Double($0) * gap, label: "A", isModifierCombination: false)
        }
    }

    /// Watching someone type is boring at 1× and fine at 4×.
    func testATypingBurstIsSuggested() {
        XCTAssertEqual(TypingDetector.runs(in: keys(from: 5, count: 12, every: 0.12)).count, 1)
    }

    func testAStrayKeypressIsNotATypingBurst() {
        XCTAssertTrue(TypingDetector.runs(in: keys(from: 5, count: 2, every: 0.12)).isEmpty)
    }

    func testTwoSeparatedBurstsAreSuggestedSeparately() {
        let both = keys(from: 5, count: 10, every: 0.12) + keys(from: 40, count: 10, every: 0.12)
        XCTAssertEqual(TypingDetector.runs(in: both).count, 2)
    }

    func testASuggestionSpansTheBurst() {
        guard let run = TypingDetector.runs(in: keys(from: 5, count: 10, every: 0.2)).first else {
            return XCTFail("expected a run")
        }
        XCTAssertEqual(run.start, 5, accuracy: 0.001)
        XCTAssertEqual(run.end, 6.8, accuracy: 0.001)
    }

    /// A suggestion, never an application. A speed change silently inserted into someone's
    /// timeline is the kind of helpfulness that makes a tool untrustworthy.
    func testASuggestionCarriesASpeedRatherThanApplyingOne() {
        let run = TypingDetector.runs(in: keys(from: 5, count: 10, every: 0.12)).first
        XCTAssertEqual(run?.suggestedSpeed ?? 0, TypingDetector.Tuning().suggestedSpeed)
    }

    // MARK: - Loudness

    func testSilenceMeasuresVeryQuiet() {
        XCTAssertLessThan(LoudnessMeter.loudness(of: envelope(0.00001, seconds: 1)), -80)
    }

    func testFullScaleMeasuresNearZero() {
        XCTAssertEqual(LoudnessMeter.loudness(of: envelope(1, seconds: 1)), 0, accuracy: 0.5)
    }

    func testHalfScaleMeasuresAboutMinusSix() {
        XCTAssertEqual(LoudnessMeter.loudness(of: envelope(0.5, seconds: 1)), -6, accuracy: 0.5)
    }

    /// One constant gain, not a compressor. A demo recorded slightly too quiet is the actual
    /// problem, and dynamic-range compression on speech is a taste decision the app should not
    /// make on someone's behalf.
    func testTheGainIsWhateverClosesTheGapToTheTarget() {
        XCTAssertEqual(LoudnessMeter.gain(from: -26, to: -16), 10, accuracy: 0.0001)
    }

    func testAnEmptyEnvelopeIsTreatedAsSilent() {
        XCTAssertLessThan(LoudnessMeter.loudness(of: []), -80)
    }

    // MARK: - Ducking

    func testWithNoSpeechTheOtherTrackIsUntouched() {
        let gains = Ducker.gains(forSpeech: envelope(0.0001, seconds: 2), sampleRate: 100)
        XCTAssertTrue(gains.allSatisfy { abs($0 - 1) < 0.001 })
    }

    func testSustainedSpeechPullsTheOtherTrackDown() {
        let gains = Ducker.gains(forSpeech: envelope(0.5, seconds: 3), sampleRate: 100)
        let target = Ducker.Tuning().depthGain
        XCTAssertEqual(Double(gains.last ?? 1), target, accuracy: 0.02)
    }

    func testTheGainNeverLeavesItsRange() {
        let speech = envelope(0.6, seconds: 1) + envelope(0.0001, seconds: 1)
            + envelope(0.6, seconds: 1)
        let target = Ducker.Tuning().depthGain
        for gain in Ducker.gains(forSpeech: speech, sampleRate: 100) {
            XCTAssertLessThanOrEqual(Double(gain), 1.0001)
            XCTAssertGreaterThanOrEqual(Double(gain), target - 0.0001)
        }
    }

    /// Ducking has to be quick to get out of the way and slow to come back, or the music pumps on
    /// every syllable.
    func testItDucksFasterThanItRecovers() {
        let tuning = Ducker.Tuning()
        XCTAssertLessThan(tuning.attack, tuning.release)

        let speech = envelope(0.6, seconds: 0.5) + envelope(0.0001, seconds: 0.5)
        let gains = Ducker.gains(forSpeech: speech, sampleRate: 100)
        let duckedBy = 1 - Double(gains[49])
        let recoveredBy = Double(gains[99]) - Double(gains[50])
        XCTAssertGreaterThan(duckedBy, recoveredBy)
    }

    func testAnEmptySpeechTrackProducesNoGains() {
        XCTAssertTrue(Ducker.gains(forSpeech: [], sampleRate: 100).isEmpty)
    }
}
