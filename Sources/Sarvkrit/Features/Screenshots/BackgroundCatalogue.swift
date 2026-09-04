import CoreGraphics
import Foundation

/// The built-in backgrounds.
///
/// **Twenty gradients as data, not twenty PNGs.** Images large enough for a 6K canvas would add
/// tens of megabytes to a menu-bar utility, be wrong at every aspect ratio other than the one
/// they were drawn at, and need @2x variants. A mesh resamples perfectly at any size.
///
/// **Meshes, not two-stop lines.** Every one of these used to be two colours at 135°, and a line
/// through colour space cannot hold what a good background does — one of these runs blue through
/// amber to peach, another purple through cyan to violet. The palettes were sampled from a
/// reference rather than invented, three by three, and the ids are unchanged so a capture already
/// using one simply starts looking better.
enum BackgroundCatalogue {

    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let mesh: MeshSpec

        /// Every hue the mesh actually contains, in degrees.
        ///
        /// **A set, not a mean.** Auto Balance picks the background furthest in hue from the
        /// screenshot, and a mesh spanning teal to indigo has a *mean* hue sitting in a region it
        /// barely contains — so scoring on the average could pick a background containing the very
        /// colour it was trying to avoid. Scoring against the whole set cannot.
        let hues: [Double]
        /// The darkest and lightest the mesh gets.
        ///
        /// Also not a mean: a mesh with a near-white lobe and a near-black one averages to 0.5 and
        /// would pass neither the light nor the dark filter, when in truth it fails both.
        let lightnessRange: ClosedRange<Double>

        /// Kept for the contrast filter, which wants one number to sort by.
        var lightness: Double { (lightnessRange.lowerBound + lightnessRange.upperBound) / 2 }
    }

    /// Fifteen sampled from the reference, five authored.
    ///
    /// A note on the names: several ids no longer describe their colours — the palette that suits
    /// a mesh is not always the one its id was coined for — so the *labels* were corrected and the
    /// **ids left alone**. Ids are what documents store; changing one would silently turn every
    /// capture using it into a different background.
    ///
    /// The reference's swatches are all vivid mid-tones — even its darkest has a light corner —
    /// and Auto Balance needs somewhere genuinely light to put a dark screenshot and somewhere
    /// genuinely dark to put a light one. Slate, Paper, Ink and Graphite are those: still meshes,
    /// still varying, but within a narrow band so they stay quiet behind the picture.
    static let entries: [Entry] = [
        entry("dusk", "Dusk", ["DD6784", "B65091", "503781",
                              "D85E8A", "D05EA0", "8A60AF",
                              "B956A2", "B474C2", "C88FCE"]),
        entry("ember", "Ember", ["EA6438", "E8355B", "ED8D79",
                              "E84356", "E73F3F", "E9BEBB",
                              "ED81A0", "F3B779", "ECDCC4"]),
        entry("mint", "Mint", ["64A4A4", "8EC4B3", "B7E4C6",
                              "77BEBD", "80C4BE", "87C9BE",
                              "81D6E6", "71C2C9", "5FB3B9"]),
        entry("ocean", "Ocean", ["1C2C77", "071A71", "153591",
                              "35569E", "1B3B8C", "2957A6",
                              "386EB0", "3972B5", "498FC1"]),
        entry("sand", "Sand", ["F6E3C4", "F2D3A0", "E8BE84",
                              "F3DDBB", "EFCB95", "E2B075",
                              "EBD0AA", "E4BC8B", "D6A268"]),
        entry("slate", "Slate", ["2E3440", "39404E", "434B5A",
                              "383F4C", "434B59", "4E5666",
                              "434A58", "4E5665", "5A6274"]),
        entry("paper", "Paper", ["F7F7F5", "FAFAF8", "F2F3F7",
                              "F4F2EF", "F8F8F6", "EFF1F6",
                              "EDEEEA", "F2F3F0", "E9ECF2"]),
        entry("ink", "Ink", ["0B0C14", "10111C", "0A0D18",
                              "141626", "191B2B", "101322",
                              "0C0E19", "15182A", "0A0C16"]),
        entry("blossom", "Blossom", ["C376B3", "D76682", "E572B4",
                              "858AE1", "D47593", "EEA19F",
                              "BF83EA", "EA98A3", "F2B78C"]),
        entry("citrus", "Coral", ["EF8585", "EB7A91", "E284A8",
                              "F0947A", "EC7A7D", "E66F83",
                              "F1A575", "EE836E", "E37075"]),
        entry("forest", "Indigo", ["1E38A4", "3541AD", "4A4EB9",
                              "6561CB", "7C6BD4", "8E74DB",
                              "9F84E6", "B683E1", "CB85DC"]),
        entry("lavender", "Lavender", ["CBC0F7", "AAA4EC", "8E72DB",
                              "967FCD", "BEA0D7", "827FD3",
                              "9385DF", "BABAF6", "9DC4F4"]),
        entry("rose", "Rose", ["B84F91", "ABACDA", "B9B0BA",
                              "D45842", "DE5D63", "823F75",
                              "BB5248", "3A1037", "691838"]),
        entry("steel", "Steel", ["B9C7D4", "BDBECC", "C4BFCA",
                              "CAD8DF", "DAC7C3", "E1C8C1",
                              "C3DCE5", "B3B3BE", "DDB9AD"]),
        entry("aurora", "Aurora", ["CA99D7", "AC64D9", "7E36CC",
                              "74B6E0", "CB93EB", "8D32E4",
                              "56BAF3", "4A98E7", "4527C2"]),
        entry("cocoa", "Wine", ["41294F", "7A354F", "6A334D",
                              "4E2E4D", "72344F", "B94651",
                              "5C2F4F", "753550", "B64650"]),
        entry("sky", "Sky", ["509CF3", "9BC4F9", "B8DFFA",
                              "4F6DEA", "92A6F8", "94D6FA",
                              "8E77F6", "8D87F7", "8BDEFA"]),
        entry("plum", "Plum", ["0F1958", "1D3377", "3A72BE",
                              "1D1336", "2A1F69", "4F3FB3",
                              "782333", "2C146A", "6C30B6"]),
        entry("moss", "Haze", ["789DD0", "8BA9D9", "8DA8D9",
                              "9BA6DA", "BABFE8", "BEBDE6",
                              "C1A1C9", "D6B7D5", "DCBAD3"]),
        entry("graphite", "Graphite", ["1E1E22", "26262B", "2C2C32",
                              "232328", "2C2C32", "34343B",
                              "2A2A30", "34343B", "3C3C44"]),
    ]

    /// Builds an entry, **deriving** its hues and lightness from the colours themselves.
    ///
    /// The old entries carried two hand-typed scalars that nothing checked against the gradient,
    /// so they could describe a colour the preset did not contain. Derived, they cannot drift.
    private static func entry(_ id: String, _ name: String, _ hexes: [String]) -> Entry {
        let colours = hexes.map(RGBAColour.init(hex:))
        let mesh = MeshSpec(columns: 3, rows: 3, colours: colours)

        var hues: [Double] = []
        var lowest = 1.0
        var highest = 0.0
        for colour in colours {
            let maximum = max(colour.r, max(colour.g, colour.b))
            let minimum = min(colour.r, min(colour.g, colour.b))
            let lightness = (maximum + minimum) / 2
            lowest = min(lowest, lightness)
            highest = max(highest, lightness)
            // Greys have no meaningful hue; including one would make every background look
            // equally distant from a grey screenshot.
            guard maximum - minimum > 0.08 else { continue }
            hues.append(hue(r: colour.r, g: colour.g, b: colour.b, max: maximum, min: minimum))
        }
        return Entry(id: id, name: name, mesh: mesh, hues: hues,
                     lightnessRange: lowest...max(lowest, highest))
    }

    private static func hue(r: Double, g: Double, b: Double,
                            max maximum: Double, min minimum: Double) -> Double {
        let chroma = maximum - minimum
        var value: Double
        if maximum == r { value = (g - b) / chroma }
        else if maximum == g { value = 2 + (b - r) / chroma }
        else { value = 4 + (r - g) / chroma }
        value *= 60
        return value < 0 ? value + 360 : value
    }

    static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    /// The mesh for an id, falling back rather than drawing nothing — an unrecognised id must not
    /// produce a transparent background the user can neither see nor explain.
    static func mesh(for id: String) -> MeshSpec {
        entry(id: id)?.mesh ?? entries[0].mesh
    }
}

extension CaptureBackground.Fill {
    /// The control grid a person can edit, if this fill has one.
    ///
    /// A preset resolves to its catalogue mesh, so **picking a preset and then changing one of its
    /// colours is a continuous gesture** — the preset is a starting point rather than a fixed
    /// choice. The other cases have no grid: a solid or an image is not a mesh, and an `.unknown`
    /// fill belongs to a newer build and must be handed back untouched.
    var editableMesh: MeshSpec? {
        switch self {
        case .mesh(let spec): return spec.isWellFormed ? spec : nil
        case .builtIn(let id): return BackgroundCatalogue.mesh(for: id)
        case .none, .solid, .gradient, .image, .unknown: return nil
        }
    }
}
