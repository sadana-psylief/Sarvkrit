import AppKit
import CoreGraphics
import os

/// Reads and writes display brightness, through whichever channel a display answers on.
///
/// **`DisplayServices` is a private framework**, resolved with `dlopen`/`dlsym` rather than linked,
/// so a macOS release that removes it degrades to the gamma fallback instead of failing to launch.
/// Like the temperature sensors it is undocumented but unprivileged: no root, no prompt, nothing
/// leaves the Mac. macOS ships no public API for setting the brightness of a display.
///
/// DDC is deliberately **not** implemented here. Talking to an external monitor over I²C means
/// `IOAVService`, which is private, per-port, and differs between Apple Silicon generations; when
/// it goes wrong it does so by hanging the I²C bus rather than returning an error. `BrightnessChannel`
/// already models `.ddc` so that adding it later changes one probe and nothing else — until then
/// externals fall to gamma, which works everywhere and says what it is.
final class BrightnessControl {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Displays")

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Symbols {
        let get: GetBrightness
        let set: SetBrightness
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY) else { return nil }
        guard let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return Symbols(get: unsafeBitCast(get, to: GetBrightness.self),
                       set: unsafeBitCast(set, to: SetBrightness.self))
    }()

    /// Gamma dimming for displays with no reachable backlight, keyed by display.
    ///
    /// **A gamma table outlives the process that set it.** If Sarvkrit is killed while a display is
    /// dimmed, that display stays dimmed with nothing on screen to explain why — the same class of
    /// problem as leaving a Mac unable to sleep, and handled the same way.
    private var gammaFactors: [CGDirectDisplayID: Float] = [:]

    /// Whether *Sarvkrit* currently has a display dimmed, persisted so the answer survives a crash.
    ///
    /// This is load-bearing, and getting it wrong is worse than the problem it solves.
    /// `CGDisplayRestoreColorSyncSettings()` does not undo "our" gamma — it resets the transfer
    /// function to the ColorSync profile's, discarding whatever *anything* had loaded. Calling it
    /// unconditionally at launch would mean Sarvkrit starting up wipes the display state of every
    /// calibration tool and every f.lux-style app on the Mac, for users who have never switched
    /// Displays on at all.
    ///
    /// So the restore is gated on this marker, exactly the way `SleepDisableFlag` only puts back a
    /// setting it can prove it was the one to change.
    private let defaults: UserDefaults
    private static let dimmedKey = "displays.gammaDimmed"

    private var hasDimmed: Bool {
        get { defaults.bool(forKey: Self.dimmedKey) }
        set {
            guard defaults.bool(forKey: Self.dimmedKey) != newValue else { return }
            defaults.set(newValue, forKey: Self.dimmedKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var channels: [CGDirectDisplayID: BrightnessChannel] = [:]

    // MARK: - Channels

    func channel(for display: ConnectedDisplay) -> BrightnessChannel {
        if let known = channels[display.id] { return known }
        let chosen = BrightnessChannel.choose(.init(
            isBuiltIn: display.isBuiltIn,
            respondsToDisplayServices: readDisplayServices(display.id) != nil,
            // Not probed: see the type's note on why DDC is not implemented yet.
            respondsToDDC: false))
        channels[display.id] = chosen
        return chosen
    }

    /// Forgets what it learned, for when displays are plugged or unplugged.
    func invalidate() {
        channels.removeAll()
    }

    // MARK: - Reading and writing

    /// 0…1, or `nil` where the display has no readable brightness.
    func brightness(of display: ConnectedDisplay) -> Float? {
        switch channel(for: display) {
        case .displayServices, .ddc:
            return readDisplayServices(display.id)
        case .gamma:
            // The dim factor *is* the brightness as far as the user is concerned, and it starts at
            // full because that is the state the Mac was found in.
            return gammaFactors[display.id] ?? 1
        case .unavailable:
            return nil
        }
    }

    func setBrightness(_ value: Float, for display: ConnectedDisplay) {
        let clamped = min(1, max(0, value))
        switch channel(for: display) {
        case .displayServices, .ddc:
            _ = Self.symbols?.set(display.id, clamped)
        case .gamma:
            applyGamma(clamped, to: display.id)
        case .unavailable:
            break
        }
    }

    private func readDisplayServices(_ id: CGDirectDisplayID) -> Float? {
        guard let symbols = Self.symbols else { return nil }
        var value: Float = 0
        guard symbols.get(id, &value) == 0 else { return nil }
        // A display that does not support this reports success and leaves the value untouched on
        // some machines, so an exact zero is treated as no answer. The cost of being wrong is a
        // display that falls back to gamma; the cost the other way is a slider pinned at 0%.
        guard value > 0 else { return nil }
        return value
    }

    // MARK: - Gamma

    /// Scales the whole transfer function. `CGSetDisplayTransferByFormula` is public API.
    private func applyGamma(_ factor: Float, to id: CGDirectDisplayID) {
        // Never fully black: a display at 0 with no way to see the slider that got it there is a
        // trap, and the user's next move would have to be blind. `DisplaysFeature` clamps the value
        // it reports to the same floor, so the label and the picture agree.
        let scale = max(Self.minimumGamma, factor)
        gammaFactors[id] = factor
        // Written *before* the table is set, so a crash between the two lines still leaves the
        // marker that gets it cleaned up.
        hasDimmed = true
        CGSetDisplayTransferByFormula(id,
                                      0, scale, 1,
                                      0, scale, 1,
                                      0, scale, 1)
    }

    /// The lowest the gamma fallback will go. See `applyGamma`.
    static let minimumGamma: Float = 0.15

    /// Puts every display's gamma back — but only if Sarvkrit is what dimmed it.
    ///
    /// Called on `deactivate()` and at launch. The launch call is the one that matters: it clears a
    /// table left behind by a crash, which nothing else would ever undo. It is also the one that
    /// must not fire otherwise, because the call resets far more than Sarvkrit set — see
    /// `hasDimmed`.
    func restoreGamma() {
        guard hasDimmed || !gammaFactors.isEmpty else { return }
        gammaFactors.removeAll()
        hasDimmed = false
        CGDisplayRestoreColorSyncSettings()
    }
}
