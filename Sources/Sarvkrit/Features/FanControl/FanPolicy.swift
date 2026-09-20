import Foundation

/// "Above 75 °C, run the fans at 70%."
struct FanCurve: Equatable, Codable {
    var thresholdCelsius: Double = 75
    var targetPercent: Double = 70
    /// How far the Mac has to cool below the threshold before the fans are handed back. Without a
    /// band, a machine sitting exactly at the threshold toggles the fans every sample and sounds
    /// broken — a worse failure than running a few degrees warm.
    var hysteresisCelsius: Double = 4
}

/// What the user has asked Sarvkrit to do about the fans.
enum FanMode: Equatable {
    /// Watch only. The SMC keeps the fans.
    case monitor
    case manual(percent: Double)
    case automatic(FanCurve)
}

enum FanReleaseReason: Equatable {
    /// We are not in the business of controlling this fan.
    case notControlling
    case belowThreshold
    /// The hard ceiling. Apple's controller knows things this app does not.
    case overCeiling
    /// A ramp with nothing to ramp on.
    case noTemperature
}

enum FanCommand: Equatable {
    case hold(percent: Double)
    case release(FanReleaseReason)
}

/// The whole control decision, as a function.
///
/// Pure, and `isEngaged` is a parameter rather than state kept inside, so every case is one call
/// with no setup — the `KeepAwakeState` and `ThermalClassification` pattern. This is the code that
/// decides how fast a fan runs, and "looks right" is not good enough for that.
enum FanPolicy {
    /// **Not configurable, and not persisted.** Above this, the fans go back to macOS whatever the
    /// user asked for. At this temperature Apple's controller is coordinating both fans, the power
    /// delivery and the frequency governor; a speed pinned by hand is strictly worse than getting
    /// out of the way. Making it a setting would turn a safety net into another way to get it
    /// wrong.
    static let hardCeilingCelsius: Double = 95

    static func command(mode: FanMode, celsius: Double?, isEngaged: Bool) -> FanCommand {
        // Watching only is checked first, so that a Mac running hot while the feature is off is
        // reported as "not ours" rather than as a ceiling event we did not act on.
        guard mode != .monitor else { return .release(.notControlling) }

        if let celsius, celsius >= hardCeilingCelsius { return .release(.overCeiling) }

        switch mode {
        case .monitor:
            return .release(.notControlling)

        case let .manual(percent):
            // No temperature needed: the user named a speed. It has no ceiling on a Mac whose
            // sensors we cannot read, which is why that Mac is told so.
            return .hold(percent: clampPercent(percent))

        case let .automatic(curve):
            guard let celsius else { return .release(.noTemperature) }
            // Engaged, the fans hold on until the Mac has cooled through the whole band.
            let engageAt = isEngaged ? curve.thresholdCelsius - curve.hysteresisCelsius
                                     : curve.thresholdCelsius
            guard celsius >= engageAt else { return .release(.belowThreshold) }
            return .hold(percent: clampPercent(curve.targetPercent))
        }
    }

    private static func clampPercent(_ percent: Double) -> Double {
        percent.isNaN ? 0 : min(max(percent, 0), 100)
    }
}
