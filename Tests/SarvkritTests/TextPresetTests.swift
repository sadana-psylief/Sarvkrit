import AppKit
import XCTest
@testable import Sarvkrit

/// The seven text styles.
///
/// Worth stating what these pin, because the obvious reading of "7 presets" is seven typefaces and
/// that reading loses half the feature: they are three faces crossed with four container
/// treatments, and the containers are the part that makes text readable on a screenshot.
final class TextPresetTests: XCTestCase {

    func testThereAreSevenOfThemAndTheyAreAllDifferent() {
        XCTAssertEqual(TextPreset.allCases.count, 7)
        XCTAssertEqual(Set(TextPreset.allCases.map(\.title)).count, 7)
        XCTAssertEqual(Set(TextPreset.allCases.map(\.rawValue)).count, 7)
    }

    func testTheThreeFacesEachAppearBareAndTheBoxedOnesCarryABox() {
        XCTAssertEqual(TextPreset.standard.typeface, .standard)
        XCTAssertEqual(TextPreset.rounded.typeface, .rounded)
        XCTAssertEqual(TextPreset.monospaced.typeface, .monospaced)
        XCTAssertEqual(TextPreset.roundedBoxed.typeface, .rounded)
        XCTAssertEqual(TextPreset.monospacedBoxed.typeface, .monospaced)

        for bare in [TextPreset.standard, .rounded, .monospaced, .outlined] {
            XCTAssertFalse(bare.hasBackground, "\(bare.title) should not wear a box")
        }
        for boxed in [TextPreset.boxed, .roundedBoxed, .monospacedBoxed] {
            XCTAssertTrue(boxed.hasBackground, "\(boxed.title) should wear a box")
        }
    }

    func testOnlyOutlinedGetsAHaloAndOnlyMonospacedBoxedGetsABorder() {
        XCTAssertEqual(TextPreset.allCases.filter(\.hasHalo), [.outlined])
        XCTAssertEqual(TextPreset.allCases.filter(\.hasBorder), [.monospacedBoxed])
    }

    func testApplyingAPresetSetsEverythingTheRendererReads() {
        var text = TextElement(origin: .zero, string: "Hello", fontSize: 40)
        TextPreset.outlined.apply(to: &text, accent: .blue)
        XCTAssertEqual(text.haloColour, .white)
        XCTAssertNil(text.background)
        XCTAssertEqual(text.colour, .blue, "a bare style keeps the picked colour on the glyphs")

        TextPreset.roundedBoxed.apply(to: &text, accent: .blue)
        XCTAssertEqual(text.background, .blue, "a boxed style moves the picked colour to the box")
        XCTAssertNil(text.haloColour, "switching styles must clear what the last one set")
        XCTAssertGreaterThan(text.cornerRadius, 0)
        XCTAssertGreaterThan(text.padding, 0)
    }

    func testTextOnAColouredBoxIsNeverTheSameColourAsTheBox() {
        // The bug this exists for: setting the picked colour on the glyphs *and* the box, which
        // renders as an empty pill.
        for colour in [RGBAColour.red, .orange, .yellow, .green, .blue, .purple, .white] {
            var text = TextElement(origin: .zero, string: "Hi", fontSize: 30)
            TextPreset.boxed.apply(to: &text, accent: colour)
            XCTAssertNotEqual(text.colour, text.background, "\(colour) box and glyphs match")
        }
    }

    func testYellowGetsDarkTextAndBlueGetsWhite() {
        // Averaging the channels instead of weighting them puts the flip in the wrong place, and
        // yellow — the highlighter colour — is exactly where it shows.
        XCTAssertEqual(RGBAColour.yellow.readableForeground.r, 0.09, accuracy: 0.001)
        XCTAssertEqual(RGBAColour.blue.readableForeground, .white)
        XCTAssertEqual(RGBAColour.white.readableForeground.r, 0.09, accuracy: 0.001)
    }

    func testTheCornerRadiusScalesWithTheTextSoA4xCaptureStillLooksRounded() {
        var small = TextElement(origin: .zero, string: "x", fontSize: 20)
        var large = TextElement(origin: .zero, string: "x", fontSize: 80)
        TextPreset.roundedBoxed.apply(to: &small, accent: .red)
        TextPreset.roundedBoxed.apply(to: &large, accent: .red)
        XCTAssertEqual(large.cornerRadius / small.cornerRadius, 4, accuracy: 0.01)
    }

    func testEveryPresetResolvesToARealFont() {
        for preset in TextPreset.allCases {
            let font = preset.typeface.font(ofSize: 24, customName: nil)
            XCTAssertEqual(font.pointSize, 24, "\(preset.title)")
            XCTAssertFalse(font.fontName.isEmpty)
        }
        XCTAssertNotEqual(TextPreset.rounded.typeface.font(ofSize: 24, customName: nil).fontName,
                          TextPreset.standard.typeface.font(ofSize: 24, customName: nil).fontName,
                          "rounded must not silently fall back to the system face")
        XCTAssertTrue(TextPreset.monospaced.typeface
            .font(ofSize: 24, customName: nil).isFixedPitch)
    }

    // MARK: - Persistence

    func testAStyledTextElementSurvivesEncodingAndDecoding() throws {
        var text = TextElement(origin: CGPoint(x: 10, y: 20), string: "Secret", fontSize: 48)
        TextPreset.monospacedBoxed.apply(to: &text, accent: .green)

        let data = try JSONEncoder().encode(text)
        let back = try JSONDecoder().decode(TextElement.self, from: data)
        XCTAssertEqual(back, text)
        XCTAssertEqual(back.typeface, .monospaced)
        XCTAssertNotNil(back.borderColour)
    }

    func testADocumentWrittenBeforeThePresetsExistedStillOpens() throws {
        // The reason `TextElement` has a hand-written decoder. The synthesised one throws on a
        // missing key even where the property has a default, so adding a field to a shipped format
        // would make every older document fail to open — and a screenshot that will not open is
        // the user's work gone.
        // Built by stripping the new keys out of a current encoding rather than by hand, so the
        // fixture cannot drift away from the real format the way a literal would.
        var current = TextElement(origin: CGPoint(x: 5, y: 6), string: "Old", fontSize: 36)
        TextPreset.roundedBoxed.apply(to: &current, accent: .green)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(current)) as? [String: Any])
        for key in ["typeface", "cornerRadius", "borderColour", "haloColour", "background"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONSerialization.data(withJSONObject: json)

        let text = try JSONDecoder().decode(TextElement.self, from: legacy)
        XCTAssertEqual(text.string, "Old")
        XCTAssertEqual(text.typeface, .standard, "absent means the old default, not a failure")
        XCTAssertEqual(text.cornerRadius, 0)
        XCTAssertNil(text.haloColour)
    }

    // MARK: - Rendering

    func testEveryPresetActuallyPutsDifferentPixelsOnTheImage() throws {
        // Seven entries in a menu that render identically would be seven ways to do one thing.
        var digests: [String: String] = [:]
        for preset in TextPreset.allCases {
            var text = TextElement(origin: CGPoint(x: 20, y: 20), string: "Sample", fontSize: 40)
            preset.apply(to: &text, accent: .blue)
            let image = try render([.init(kind: .text(text))], size: CGSize(width: 300, height: 90))
            digests[preset.title] = try digest(of: image)
        }
        XCTAssertEqual(Set(digests.values).count, 7,
                       "some presets render identically: \(digests)")
    }

    func testTheOutlinedPresetPutsItsHaloOutsideTheGlyphsRatherThanOverThem() throws {
        // A halo drawn *over* the text is just white text. The check is that the dark glyph core
        // survives: some pixel in the middle must still be the text colour.
        var text = TextElement(origin: CGPoint(x: 10, y: 10), string: "III", fontSize: 60)
        TextPreset.outlined.apply(to: &text, accent: RGBAColour(r: 0, g: 0, b: 0))
        let image = try render([.init(kind: .text(text))], size: CGSize(width: 200, height: 90))

        let (dark, white) = try countTones(in: image)
        XCTAssertGreaterThan(dark, 200, "the glyphs were swallowed by their own halo")
        XCTAssertGreaterThan(white, 200, "no halo was drawn")
    }

    /// Writes the seven, rendered, to the scratchpad — the same "photograph it and look" step that
    /// caught four layout bugs the unit tests were happy with.
    func testWriteAPreviewSheetForVisualInspection() throws {
        guard let directory = ProcessInfo.processInfo.environment["SARVKRIT_PREVIEW_DIR"] else {
            throw XCTSkip("set SARVKRIT_PREVIEW_DIR to write the sheet")
        }
        var elements: [AnnotationElement] = []
        for (index, preset) in TextPreset.allCases.enumerated() {
            var text = TextElement(origin: CGPoint(x: 30, y: 30 + CGFloat(index) * 80),
                                   string: preset.title, fontSize: 42)
            preset.apply(to: &text, accent: .blue)
            elements.append(.init(kind: .text(text)))
        }
        let image = try render(elements, size: CGSize(width: 620, height: 620))
        let url = URL(fileURLWithPath: directory).appendingPathComponent("text-presets.png")
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: - Helpers

    private func render(_ elements: [AnnotationElement], size: CGSize) throws -> CGImage {
        let base = try grey(size)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Document space is top-left; `draw` expects the context already flipped into it, and
        // flips back itself for the base bitmap.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        var document = AnnotationDocument(imageSize: size)
        document.elements = elements
        AnnotationRenderer.draw(document, base: base, in: context)
        return try XCTUnwrap(context.makeImage())
    }

    /// A mid-grey ground, chosen so both the dark glyphs and the white halo stand out against it.
    private func grey(_ size: CGSize) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(of image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func digest(of image: CGImage) throws -> String {
        let bytes = try pixels(of: image)
        var hash: UInt64 = 1469598103934665603
        for byte in bytes {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func countTones(in image: CGImage) throws -> (dark: Int, white: Int) {
        let bytes = try pixels(of: image)
        var dark = 0
        var white = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[index]), g = Int(bytes[index + 1]), b = Int(bytes[index + 2])
            if r < 40 && g < 40 && b < 40 { dark += 1 }
            if r > 235 && g > 235 && b > 235 { white += 1 }
        }
        return (dark, white)
    }
}
