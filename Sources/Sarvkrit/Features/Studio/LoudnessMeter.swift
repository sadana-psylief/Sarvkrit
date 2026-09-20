import Foundation

/// How loud a track is, and what it would take to fix it.
enum LoudnessMeter {

    /// The streaming convention, and what a viewer's other tabs are mastered to.
    static let defaultTarget: Double = -16

    /// Anything quieter than this is silence as far as the meter is concerned. Without a floor,
    /// an empty envelope measures negative infinity and every number downstream becomes `nan`.
    static let floor: Double = -120

    /// RMS of an amplitude envelope, in dBFS.
    static func loudness(of envelope: [Float]) -> Double {
        guard !envelope.isEmpty else { return floor }
        let meanSquare = envelope.reduce(0.0) { $0 + Double($1) * Double($1) }
            / Double(envelope.count)
        guard meanSquare > 0 else { return floor }
        return max(floor, 10 * log10(meanSquare))
    }

    /// The correction, in dB, from a measured level to a target.
    ///
    /// **One constant gain for the whole track, not a compressor.** A demo recorded slightly too
    /// quiet is the actual problem here; dynamic-range compression on speech is a taste decision
    /// with an audible signature, and the app should not make it on someone's behalf without
    /// saying so. Anything the gain would push past full scale goes through `SoftClip`, which the
    /// volume mixer already uses and which leaves everything below the threshold bit-for-bit
    /// untouched.
    static func gain(from measured: Double, to target: Double = defaultTarget) -> Double {
        target - measured
    }
}
