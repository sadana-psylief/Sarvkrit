import Foundation

/// Pulling one track down while another is speaking.
///
/// Pure over the speech envelope, producing a gain curve for the *other* track. Applying it is
/// somebody else's job; deciding the shape is this one's.
enum Ducker {

    struct Tuning: Equatable {
        /// dBFS. Above this, someone is talking.
        var threshold: Double = -35
        /// How far the other track comes down, in dB.
        var depth: Double = -12
        /// Quick, so the duck is already there by the time the first syllable lands.
        var attack: TimeInterval = 0.08
        /// **Slow, and the reason is audible.** A release as fast as the attack makes the music
        /// surge back between every word, which is the pumping that gives away a badly ducked mix.
        var release: TimeInterval = 0.4

        init() {}

        var thresholdAmplitude: Float { Float(pow(10, threshold / 20)) }
        /// The duck expressed as a multiplier rather than in dB, which is what a mixer wants.
        var depthGain: Double { pow(10, depth / 20) }
    }

    /// A gain multiplier per envelope sample, in 0…1.
    static func gains(forSpeech envelope: [Float], sampleRate: Double,
                      tuning: Tuning = Tuning()) -> [Float] {
        guard !envelope.isEmpty, sampleRate > 0 else { return [] }

        let step = 1 / sampleRate
        let duckTo = Float(tuning.depthGain)
        let limit = tuning.thresholdAmplitude
        // A one-pole step per sample. Two coefficients rather than one is the whole point: the
        // direction of travel is what decides how fast the gain is allowed to move.
        let downward = Float(1 - exp(-step / tuning.attack))
        let upward = Float(1 - exp(-step / tuning.release))

        var gain: Float = 1
        var result: [Float] = []
        result.reserveCapacity(envelope.count)

        for level in envelope {
            let target: Float = abs(level) >= limit ? duckTo : 1
            gain += (target - gain) * (target < gain ? downward : upward)
            result.append(min(1, max(duckTo, gain)))
        }
        return result
    }
}
