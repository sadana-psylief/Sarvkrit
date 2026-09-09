import Foundation

/// Finding the dead air in a narration track.
///
/// Pure over an amplitude envelope — an array of per-slice peak levels — rather than over an
/// `AVAudioFile`, so the judgement can be tuned and tested without decoding anything. Reading the
/// envelope out of the audio is somebody else's job.
///
/// **The result is a set of suggested cuts, not a filter.** Applying this live would mean the
/// timeline no longer shows what will be exported, which breaks the promise the whole editor rests
/// on: what you see is what comes out.
enum SilenceDetector {

    struct Tuning: Equatable {
        /// dBFS. Below this counts as quiet. Room tone sits well under it; a whisper does not.
        var threshold: Double = -45
        /// A gap shorter than this is a breath between sentences, not dead air. Cutting breaths
        /// makes speech sound hurried in a way listeners notice without being able to say why.
        var minimumDuration: TimeInterval = 0.6
        /// Left at each edge of a cut.
        ///
        /// Cutting exactly where the level crosses the threshold clips the attack of the next
        /// word — speech begins quietly and gets loud — and the result sounds gasped.
        var pad: TimeInterval = 0.15

        init() {}

        var thresholdAmplitude: Float { Float(pow(10, threshold / 20)) }
    }

    /// Ranges of the envelope, in seconds, that are quiet enough and long enough to cut.
    static func silences(in envelope: [Float], sampleRate: Double,
                         tuning: Tuning = Tuning()) -> [Range<TimeInterval>] {
        guard !envelope.isEmpty, sampleRate > 0 else { return [] }
        let limit = tuning.thresholdAmplitude

        var found: [Range<TimeInterval>] = []
        var runStart: Int?

        func close(at index: Int) {
            guard let start = runStart else { return }
            runStart = nil
            let from = Double(start) / sampleRate
            let to = Double(index) / sampleRate
            guard to - from >= tuning.minimumDuration else { return }
            // Padded inwards, and dropped if the padding consumes it — a cut with a negative
            // length is not a cut.
            let padded = (from + tuning.pad)..<(to - tuning.pad)
            if padded.lowerBound < padded.upperBound { found.append(padded) }
        }

        for (index, level) in envelope.enumerated() {
            if abs(level) < limit {
                if runStart == nil { runStart = index }
            } else {
                close(at: index)
            }
        }
        close(at: envelope.count)
        return found
    }
}
