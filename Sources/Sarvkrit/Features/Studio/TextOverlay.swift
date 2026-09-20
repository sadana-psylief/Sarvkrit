import AppKit
import CoreGraphics
import Foundation

/// A line of text put on the video by hand, at a place and for a stretch.
///
/// **Its own type, because captions cannot express this.** `Caption` has no text field and no time
/// range of its own — both derive from `words: [TranscriptWord]`, each needing a speech-recognition
/// timestamp — and `CaptionStyle` is stored once per project with a position that is one of three
/// canned values rather than a point. Faking a caption would mean inventing word timings to carry a
/// string, and then fighting the karaoke highlighting it exists for.
///
/// Everything is a **fraction of the canvas** rather than a point count, so a project keeps its
/// framing when the aspect or the export size changes — the same reason `CameraSettings` and
/// `CaptionStyle` are written that way.
struct TextOverlay: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String = "Text"
    /// Unit canvas coordinates, from the top-left.
    var origin = CGPoint(x: 0.5, y: 0.16)
    /// Of the canvas height.
    var sizeFraction: Double = 0.055
    var maxWidthFraction: Double = 0.8
    var colour = RGBAColour.white
    var background: RGBAColour? = RGBAColour(r: 0, g: 0, b: 0, a: 0.55)
    var typeface: TextElement.Typeface = .rounded
    var isBold = true
    /// Of the canvas height, like the size.
    var paddingFraction: Double = 0.018
    var cornerRadiusFraction: Double = 0.014
    var haloColour: RGBAColour?
    /// Faded in and out, because text appearing between two frames reads as a flash.
    var fadeSeconds: TimeInterval = TextOverlay.defaultFade

    static let minimumDuration: TimeInterval = 0.4
    static let defaultFade: TimeInterval = 0.2

    func covers(_ t: TimeInterval) -> Bool { t >= start && t < end }

    /// 0 outside, ramping at each end, 1 while it holds.
    func opacity(at t: TimeInterval) -> Double {
        guard covers(t) else { return 0 }
        let ramp = max(0.0001, min(fadeSeconds, (end - start) / 2))
        return min(1, max(0, min(t - start, end - t) / ramp))
    }

    /// The font at a given canvas size.
    func font(forCanvasHeight height: CGFloat) -> NSFont {
        let size = max(6, height * CGFloat(sizeFraction))
        switch typeface {
        case .rounded:
            let base = NSFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: isBold ? .bold : .regular)
        case .standard, .custom:
            return NSFont.systemFont(ofSize: size, weight: isBold ? .bold : .regular)
        }
    }

    /// Hand-written for the reason `Clip`'s and `TextElement`'s are: a field added in a later
    /// release must not make an older project fail to open, and an unreadable project is treated as
    /// no project — which would quietly discard somebody's edits.
    private enum Key: String, CodingKey {
        case id, start, end, text, origin, sizeFraction, maxWidthFraction
        case colour, background, typeface, isBold, paddingFraction, cornerRadiusFraction
        case haloColour, fadeSeconds
    }

    init(start: TimeInterval, end: TimeInterval, text: String = "Text") {
        self.start = start
        self.end = end
        self.text = text
    }

    /// Written by hand as well, because the synthesized encoder omits a nil `Optional` entirely —
    /// which would make "no background" indistinguishable from "saved before backgrounds existed"
    /// and quietly restore the box. The pair has to agree.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: .id)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(text, forKey: .text)
        try container.encode(origin, forKey: .origin)
        try container.encode(sizeFraction, forKey: .sizeFraction)
        try container.encode(maxWidthFraction, forKey: .maxWidthFraction)
        try container.encode(colour, forKey: .colour)
        // Explicitly, including null.
        try container.encode(background, forKey: .background)
        try container.encode(typeface, forKey: .typeface)
        try container.encode(isBold, forKey: .isBold)
        try container.encode(paddingFraction, forKey: .paddingFraction)
        try container.encode(cornerRadiusFraction, forKey: .cornerRadiusFraction)
        try container.encode(haloColour, forKey: .haloColour)
        try container.encode(fadeSeconds, forKey: .fadeSeconds)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        func read<T: Decodable>(_ key: Key, _ fallback: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? fallback
        }
        id = read(.id, UUID())
        start = read(.start, 0)
        end = read(.end, 0)
        text = read(.text, "Text")
        origin = read(.origin, CGPoint(x: 0.5, y: 0.16))
        sizeFraction = read(.sizeFraction, 0.055)
        maxWidthFraction = read(.maxWidthFraction, 0.8)
        colour = read(.colour, RGBAColour.white)
        // **`contains` rather than `try?`, and it matters.** A missing key means "this project
        // predates the field", which should take the default box; a key that is present and null
        // means "the user turned the box off", which must stay off. `try?` cannot tell those
        // apart, so turning the background off then reopening would put it back.
        if container.contains(.background) {
            background = try? container.decode(RGBAColour.self, forKey: .background)
        } else {
            background = RGBAColour(r: 0, g: 0, b: 0, a: 0.55)
        }
        typeface = read(.typeface, TextElement.Typeface.rounded)
        isBold = read(.isBold, true)
        paddingFraction = read(.paddingFraction, 0.018)
        cornerRadiusFraction = read(.cornerRadiusFraction, 0.014)
        haloColour = try? container.decode(RGBAColour.self, forKey: .haloColour)
        fadeSeconds = read(.fadeSeconds, 0.2)
    }
}
