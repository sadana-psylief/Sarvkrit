import CoreGraphics
import Foundation

/// The built-in backgrounds.
///
/// **Twenty gradients as data, not twenty PNGs.** Images large enough for a 6K canvas would add
/// tens of megabytes to a menu-bar utility, be wrong at every aspect ratio other than the one
/// they were drawn at, and need @2x variants. A gradient resamples perfectly at any size and
/// renders in about a millisecond.
enum BackgroundCatalogue {

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let spec: GradientSpec
        /// Mean hue in degrees, for Auto Balance's "furthest from the screenshot" choice.
        let hue: Double
        /// Mean lightness, 0…1, so a dark app never lands on a dark background.
        let lightness: Double
    }

    private static func stop(_ r: Double, _ g: Double, _ b: Double,
                             at location: Double) -> GradientSpec.Stop {
        .init(colour: RGBAColour(r: r, g: g, b: b), location: location)
    }

    static let entries: [Entry] = [
        entry("dusk", "Dusk", [stop(0.29, 0.24, 0.55, at: 0), stop(0.72, 0.35, 0.55, at: 1)], hue: 280, lightness: 0.42),
        entry("ember", "Ember", [stop(0.96, 0.42, 0.20, at: 0), stop(0.85, 0.19, 0.35, at: 1)], hue: 15, lightness: 0.52),
        entry("mint", "Mint", [stop(0.60, 0.94, 0.78, at: 0), stop(0.24, 0.72, 0.68, at: 1)], hue: 160, lightness: 0.66),
        entry("ocean", "Ocean", [stop(0.13, 0.44, 0.78, at: 0), stop(0.05, 0.72, 0.82, at: 1)], hue: 200, lightness: 0.46),
        entry("sand", "Sand", [stop(0.96, 0.88, 0.74, at: 0), stop(0.88, 0.72, 0.52, at: 1)], hue: 38, lightness: 0.78),
        entry("slate", "Slate", [stop(0.20, 0.23, 0.28, at: 0), stop(0.34, 0.38, 0.44, at: 1)], hue: 210, lightness: 0.28),
        entry("paper", "Paper", [stop(0.98, 0.98, 0.97, at: 0), stop(0.90, 0.90, 0.89, at: 1)], hue: 45, lightness: 0.94),
        entry("ink", "Ink", [stop(0.07, 0.08, 0.11, at: 0), stop(0.16, 0.17, 0.22, at: 1)], hue: 230, lightness: 0.12),
        entry("blossom", "Blossom", [stop(0.99, 0.78, 0.85, at: 0), stop(0.92, 0.56, 0.72, at: 1)], hue: 340, lightness: 0.76),
        entry("citrus", "Citrus", [stop(1.0, 0.85, 0.30, at: 0), stop(0.96, 0.60, 0.16, at: 1)], hue: 42, lightness: 0.66),
        entry("forest", "Forest", [stop(0.14, 0.36, 0.24, at: 0), stop(0.28, 0.54, 0.33, at: 1)], hue: 140, lightness: 0.32),
        entry("lavender", "Lavender", [stop(0.83, 0.79, 0.96, at: 0), stop(0.64, 0.58, 0.90, at: 1)], hue: 260, lightness: 0.76),
        entry("rose", "Rose", [stop(0.94, 0.50, 0.50, at: 0), stop(0.78, 0.28, 0.42, at: 1)], hue: 355, lightness: 0.56),
        entry("steel", "Steel", [stop(0.62, 0.67, 0.72, at: 0), stop(0.42, 0.48, 0.55, at: 1)], hue: 205, lightness: 0.55),
        entry("aurora", "Aurora", [stop(0.24, 0.86, 0.72, at: 0), stop(0.36, 0.42, 0.90, at: 1)], hue: 190, lightness: 0.58),
        entry("cocoa", "Cocoa", [stop(0.44, 0.31, 0.24, at: 0), stop(0.62, 0.47, 0.36, at: 1)], hue: 25, lightness: 0.38),
        entry("sky", "Sky", [stop(0.62, 0.85, 0.98, at: 0), stop(0.35, 0.66, 0.92, at: 1)], hue: 205, lightness: 0.72),
        entry("plum", "Plum", [stop(0.38, 0.16, 0.42, at: 0), stop(0.60, 0.26, 0.56, at: 1)], hue: 295, lightness: 0.32),
        entry("moss", "Moss", [stop(0.55, 0.66, 0.36, at: 0), stop(0.36, 0.49, 0.26, at: 1)], hue: 90, lightness: 0.46),
        entry("graphite", "Graphite", [stop(0.32, 0.32, 0.34, at: 0), stop(0.16, 0.16, 0.18, at: 1)], hue: 240, lightness: 0.24),
    ]

    private static func entry(_ id: String, _ name: String, _ stops: [GradientSpec.Stop],
                              hue: Double, lightness: Double) -> Entry {
        Entry(id: id, name: name,
              spec: GradientSpec(stops: stops, angle: 135, kind: .linear),
              hue: hue, lightness: lightness)
    }

    static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    static func spec(for id: String) -> GradientSpec {
        entry(id: id)?.spec ?? entries[0].spec
    }
}
