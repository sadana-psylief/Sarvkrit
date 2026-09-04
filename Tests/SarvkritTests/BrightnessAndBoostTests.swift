import CoreGraphics
import XCTest
@testable import Sarvkrit

/// The pure decisions behind display brightness and volume boost.
final class BrightnessAndBoostTests: XCTestCase {

    // MARK: - Choosing a brightness channel

    private func capabilities(builtIn: Bool = false, displayServices: Bool = false,
                              ddc: Bool = false, gamma: Bool = true)
        -> BrightnessChannel.Capabilities {
        .init(isBuiltIn: builtIn, respondsToDisplayServices: displayServices,
              respondsToDDC: ddc, supportsGamma: gamma)
    }

    func testRealBrightnessIsAlwaysPreferredToDimmingThePicture() {
        // Not a preference — honesty. The first two move the backlight, so 50% looks like 50% and
        // the display's own controls agree. Gamma leaves the backlight where it was.
        XCTAssertEqual(BrightnessChannel.choose(capabilities(displayServices: true, ddc: true)),
                       .displayServices)
        XCTAssertEqual(BrightnessChannel.choose(capabilities(ddc: true)), .ddc)
        XCTAssertEqual(BrightnessChannel.choose(capabilities()), .gamma)
    }

    func testTheBuiltInPanelIsNeverProbedForDDC() {
        // It has none, and asking costs an I²C round trip on every display change.
        XCTAssertEqual(BrightnessChannel.choose(capabilities(builtIn: true, ddc: true)), .gamma)
    }

    func testADisplayThatAnswersNothingIsUnavailableRatherThanGamma() {
        XCTAssertEqual(BrightnessChannel.choose(capabilities(gamma: false)), .unavailable)
    }

    func testOnlyRealChannelsClaimTheyCanBrighten() {
        // The one thing the panel must not get wrong: a gamma slider cannot take a display past
        // the setting on the monitor itself, and must not look like one that can.
        XCTAssertTrue(BrightnessChannel.displayServices.canIncreaseBeyondCurrent)
        XCTAssertTrue(BrightnessChannel.ddc.canIncreaseBeyondCurrent)
        XCTAssertFalse(BrightnessChannel.gamma.canIncreaseBeyondCurrent)
        XCTAssertFalse(BrightnessChannel.unavailable.canIncreaseBeyondCurrent)
    }

    func testAChannelThatCannotBrightenAlwaysExplainsItself() {
        for channel in [BrightnessChannel.gamma, .unavailable] {
            XCTAssertNotNil(channel.explanation, "\(channel)")
        }
        for channel in [BrightnessChannel.displayServices, .ddc] {
            XCTAssertNil(channel.explanation, "a real backlight needs no caveat")
        }
    }

    func testThisMacReportsAtLeastOneDisplay() {
        // A smoke test over `CGGetOnlineDisplayList` and the `NSScreen` name matching, which is
        // done on a device-description key with no public constant.
        let displays = DisplayList.current()
        XCTAssertFalse(displays.isEmpty)
        for display in displays {
            XCTAssertFalse(display.name.isEmpty, "every display needs a name to be listed under")
        }
    }

    // MARK: - Volume boost

    func testAttenuationIsUntouchedByTheClipper() {
        // Anyone who has only ever turned an app *down* must get exactly what they got before
        // boost existed — the clipper must not colour the ordinary case.
        for gain in [Float(0), 0.25, 0.5, 1] {
            for sample in [Float(-1), -0.5, 0, 0.3, 1] {
                XCTAssertEqual(SoftClip.apply(sample, gain: gain), sample * gain, accuracy: 1e-6,
                               "gain \(gain) sample \(sample)")
            }
        }
    }

    func testAQuietSignalIsBoostedLinearly() {
        // A quiet podcast at 200% never reaches the knee, so it must come through as plain
        // multiplication rather than shaped. Non-integer gains too: the shaper's own 2× make-up
        // gain is divided back out in `apply`, and a test that only ever used gain 2 would pass
        // even if that correction were wrong.
        for (sample, gain) in [(Float(0.1), Float(2)), (-0.15, 2), (0.1, 1.5), (0.2, 1.5),
                               (-0.08, 1.25), (0.05, 1.9)] {
            XCTAssertEqual(SoftClip.apply(sample, gain: gain), sample * gain, accuracy: 1e-6,
                           "sample \(sample) at gain \(gain)")
        }
    }

    // MARK: - Gamma is only ever restored when we dimmed something

    func testGammaIsNotRestoredWhenSarvkritDimmedNothing() {
        // The bug this pins would have shipped: `CGDisplayRestoreColorSyncSettings` resets the
        // transfer function to the ColorSync profile's, discarding whatever *any* app had loaded.
        // Called unconditionally at launch it would wipe the display state of every calibration
        // tool and f.lux-style app on the Mac, for users who never switched Displays on.
        let defaults = UserDefaults(suiteName: "displays.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        XCTAssertFalse(defaults.bool(forKey: "displays.gammaDimmed"),
                       "a fresh install has dimmed nothing")

        _ = DisplaysFeature(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "displays.gammaDimmed"))
    }

    func testTheDimmedMarkerSurvivesToTheNextLaunch() {
        // A gamma table outlives the process, so the record that we set one has to as well — this
        // is the crash case, and the only case where restoring is right.
        let defaults = UserDefaults(suiteName: "displays.\(UUID())")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        defaults.set(true, forKey: "displays.gammaDimmed")
        _ = DisplaysFeature(defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: "displays.gammaDimmed"),
                       "launching after a crash restores the gamma and clears the marker")
    }

    func testTheOutputNeverLeavesTheRepresentableRange() {
        // The whole point: a sample outside ±1 is not louder, it is one the device cannot play.
        for gain in stride(from: Float(1), through: 2, by: 0.1) {
            for sample in stride(from: Float(-1), through: 1, by: 0.05) {
                let output = SoftClip.apply(sample, gain: gain)
                XCTAssertLessThanOrEqual(abs(output), 1.0001, "gain \(gain) sample \(sample)")
            }
        }
    }

    func testTheCurveIsMonotonicAndOddlySymmetric() {
        // Monotonic or the waveform folds back on itself, which is a different and much nastier
        // distortion than clipping. Symmetric, or the signal acquires a DC offset.
        var previous = SoftClip.apply(-1, gain: 2)
        for step in stride(from: Float(-0.99), through: 1, by: 0.01) {
            let output = SoftClip.apply(step, gain: 2)
            XCTAssertGreaterThanOrEqual(output, previous - 1e-6, "at \(step)")
            previous = output
            XCTAssertEqual(SoftClip.apply(-step, gain: 2), -output, accuracy: 1e-5, "at \(step)")
        }
    }

    // MARK: - Levels above unity

    func testALevelCanNowGoAboveFullVolume() {
        var levels = MixerLevels(defaults: UserDefaults(suiteName: "mixer.\(UUID())")!)
        levels.setLevel(1.46, for: "com.example.browser")
        XCTAssertEqual(levels.level(for: "com.example.browser"), 1.46, accuracy: 1e-6)
        XCTAssertTrue(levels.hasCustomLevel(for: "com.example.browser"))
    }

    func testABoostIsRememberedRatherThanTreatedAsFullVolume() {
        // The regression this pins: the old rule removed the entry for anything "1 or greater",
        // which with a ceiling of 1 meant "exactly 1". With boost it would have silently discarded
        // every boost the instant it was set, and the app would simply have played at normal
        // volume with the slider showing 200%.
        var levels = MixerLevels(defaults: UserDefaults(suiteName: "mixer.\(UUID())")!)
        levels.setLevel(2, for: "com.example.video")
        XCTAssertEqual(levels.level(for: "com.example.video"), 2, accuracy: 1e-6)
    }

    func testExactlyFullVolumeIsStillTheAbsenceOfASetting() {
        // Otherwise the "apps you have changed" list fills up with apps set back to normal.
        var levels = MixerLevels(defaults: UserDefaults(suiteName: "mixer.\(UUID())")!)
        levels.setLevel(0.4, for: "com.example.chat")
        XCTAssertTrue(levels.hasCustomLevel(for: "com.example.chat"))
        levels.setLevel(1, for: "com.example.chat")
        XCTAssertFalse(levels.hasCustomLevel(for: "com.example.chat"))
    }

    func testLevelsAreClampedToTheSupportedRange() {
        var levels = MixerLevels(defaults: UserDefaults(suiteName: "mixer.\(UUID())")!)
        levels.setLevel(9, for: "com.example.loud")
        XCTAssertEqual(levels.level(for: "com.example.loud"), MixerLevels.maximum)
        levels.setLevel(-3, for: "com.example.quiet")
        XCTAssertEqual(levels.level(for: "com.example.quiet"), MixerLevels.minimum)
    }

    func testAnUntouchedAppIsAtFullVolumeAndNotBoosted() {
        // The invariant that must survive boost: an app nobody has touched sounds exactly as it
        // would if this feature did not exist.
        let levels = MixerLevels(defaults: UserDefaults(suiteName: "mixer.\(UUID())")!)
        XCTAssertEqual(levels.level(for: "com.example.untouched"), 1)
    }
}
