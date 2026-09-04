import Foundation

/// Keeps a boosted signal inside the range the hardware can play.
///
/// Boost multiplies, and multiplying a signal that already peaks near full scale takes it past
/// ±1.0, which is not "louder" — it is a sample the output device cannot represent. The naive fix
/// is a hard clamp, and it is audible: the tops of the loudest waves become flat, which is
/// broadband distortion arriving exactly on the transients you notice most.
///
/// This is the standard cubic soft clipper. Below the threshold it is *exactly* the identity, so
/// nothing is coloured until it needs to be; above it the curve bends over smoothly and reaches its
/// limit at the knee's end. That matters more than the precise shape: a quiet podcast raised to 200%
/// never reaches the threshold at all and must come through bit-for-bit untouched.
///
/// A free function over `Float` with no allocation, no branching beyond the comparison and no state,
/// because it is called once per sample on the real-time audio thread.
enum SoftClip {
    /// Where the curve starts bending. Below this the transfer is linear.
    static let threshold: Float = 1.0 / 3.0

    /// The classic cubic waveshaper, symmetric about zero.
    ///
    /// - `|x| < t`      → `2x`, the linear region
    /// - `t ≤ |x| < 2t` → the cubic knee
    /// - `|x| ≥ 2t`     → ±1, the ceiling
    ///
    /// The 2× in the linear region is the shaper's own make-up gain and would double everything, so
    /// `apply(_:gain:)` divides it back out — this function is the textbook curve, unmodified, and
    /// the correction lives with the caller that needs it.
    static func shape(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        if magnitude >= 2 * threshold {
            return sample < 0 ? -1 : 1
        }
        if magnitude >= threshold {
            let scaled = (2 - 3 * magnitude) * (2 - 3 * magnitude)
            let value = (3 - scaled) / 3
            return sample < 0 ? -value : value
        }
        return 2 * sample
    }

    /// Applies a gain and keeps the result inside ±1.
    ///
    /// At or below unity gain this is plain multiplication: attenuating can never overshoot, and a
    /// user who has only ever turned an app *down* must get exactly what they would have got before
    /// boost existed.
    static func apply(_ sample: Float, gain: Float) -> Float {
        guard gain > 1 else { return sample * gain }
        return shape(sample * gain / 2)
    }
}
