import AppKit
import SwiftUI
import XCTest
@testable import Sarvkrit

/// The mesh renderer.
@MainActor
final class MeshRendererTests: XCTestCase {

    private let corners = MeshSpec(columns: 2, rows: 2, colours: [
        RGBAColour(hex: "FF0000"), RGBAColour(hex: "00FF00"),
        RGBAColour(hex: "0000FF"), RGBAColour(hex: "FFFFFF"),
    ])

    func testTheCornersAreExactlyTheControlColours() {
        // If the corners drift, every palette is subtly not the palette that was chosen.
        let topLeft = MeshRenderer.colour(corners, x: 0, y: 0)
        XCTAssertEqual(topLeft.r, 1, accuracy: 0.001)
        XCTAssertEqual(topLeft.g, 0, accuracy: 0.001)

        let bottomRight = MeshRenderer.colour(corners, x: 1, y: 1)
        XCTAssertEqual(bottomRight.r, 1, accuracy: 0.001)
        XCTAssertEqual(bottomRight.g, 1, accuracy: 0.001)
        XCTAssertEqual(bottomRight.b, 1, accuracy: 0.001)
    }

    func testItBlendsMonotonicallyBetweenControlPoints() {
        var previous = -1.0
        for step in 0...20 {
            let green = MeshRenderer.colour(corners, x: Double(step) / 20, y: 0).g
            XCTAssertGreaterThanOrEqual(green, previous - 0.0001, "green went backwards")
            previous = green
        }
        XCTAssertEqual(previous, 1, accuracy: 0.001)
    }

    func testAMalformedGridDoesNotCrashOrProduceNaN() {
        // A `MeshSpec` arrives from a file, so a short array is a real possibility.
        let broken = MeshSpec(columns: 3, rows: 3, colours: [RGBAColour(hex: "FF0000")])
        XCTAssertFalse(broken.isWellFormed)
        let colour = MeshRenderer.colour(broken, x: 0.5, y: 0.5)
        XCTAssertFalse(colour.r.isNaN)
        XCTAssertNil(MeshRenderer.image(broken, width: 32, height: 32))
    }

    func testEveryCatalogueEntryIsWellFormed() {
        for entry in BackgroundCatalogue.entries {
            XCTAssertTrue(entry.mesh.isWellFormed, "\(entry.name) has a broken grid")
            XCTAssertEqual(entry.mesh.colours.count, 9)
        }
    }

    /// The measured baseline: an undithered gradient gave 122 distinct colours in 125 hard steps
    /// across 380 pixels, which on a full-size export is 25-pixel bands.
    func testDitheringBeatsTheBandingBaseline() throws {
        let entry = try XCTUnwrap(BackgroundCatalogue.entry(id: "ocean"))
        let image = try XCTUnwrap(MeshRenderer.image(entry.mesh, width: 380, height: 40))
        let rep = NSBitmapImageRep(cgImage: image)

        var transitions = 0
        var previous: (Int, Int, Int)?
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: rep.pixelsHigh / 2) else { continue }
            let value = (Int(colour.redComponent * 255), Int(colour.greenComponent * 255),
                         Int(colour.blueComponent * 255))
            if let previous, previous != value { transitions += 1 }
            previous = value
        }
        XCTAssertGreaterThan(transitions, 200,
                             "only \(transitions) transitions — the dither is not working, and a "
                             + "full-size export will band")
    }

    func testTheRendererIsDeterministic() {
        // It is cached by content, so two identical requests must be the same image — and a
        // different spec must not collide with it.
        let a = MeshRenderer.image(corners, width: 40, height: 40)
        let b = MeshRenderer.image(corners, width: 40, height: 40)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "the cache handed back a different render for the same input")

        var other = corners
        other.colours[0] = RGBAColour(hex: "00FFFF")
        XCTAssertFalse(MeshRenderer.image(other, width: 40, height: 40) === a,
                       "a different mesh collided with a cached one")
    }
}

/// A contact sheet of the catalogue, for looking at.
@MainActor
final class MeshCatalogueSheetTests: XCTestCase {

    func testWriteTheCatalogueSheet() throws {
        guard let directory = PreviewDirectory.path else {
            throw XCTSkip("set SARVKRIT_PREVIEW_DIR to write the sheet")
        }
        let tile = 150, gap = 10, columns = 5
        let rows = (BackgroundCatalogue.entries.count + columns - 1) / columns
        let width = columns * tile + (columns + 1) * gap
        let height = rows * tile + (rows + 1) * gap

        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.95, green: 0.96, blue: 0.99, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        for (index, entry) in BackgroundCatalogue.entries.enumerated() {
            let rect = CGRect(x: gap + (index % columns) * (tile + gap),
                              y: gap + (index / columns) * (tile + gap),
                              width: tile, height: tile)
            BackgroundCompositor.draw(entry.mesh, in: rect, context: context)
        }

        let image = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("catalogue-sheet.png"))
    }
}

/// What the swatch shows must be what the export produces — including which way up.
@MainActor
final class SwatchAgreementTests: XCTestCase {

    /// Deliberately asymmetric top-to-bottom: a mesh whose rows differ is the only kind that can
    /// catch a flip, which is precisely why the bug survived twenty symmetric two-stop gradients.
    private let lopsided = MeshSpec(columns: 2, rows: 2, colours: [
        RGBAColour(hex: "FF0000"), RGBAColour(hex: "FF0000"),
        RGBAColour(hex: "0000FF"), RGBAColour(hex: "0000FF"),
    ])

    private func topLeft(of image: CGImage) -> NSColor? {
        NSBitmapImageRep(cgImage: image).colorAt(x: 2, y: 2)
    }

    func testTheSwatchDrawsRowZeroAtTheTop() throws {
        let view = GradientSwatch.SwatchView(mesh: lopsided)
        view.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let colour = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        XCTAssertGreaterThan(colour.redComponent, 0.8,
                             "the swatch drew the mesh upside down: its top is the bottom row")
        XCTAssertLessThan(colour.blueComponent, 0.2)
    }

    func testTheSwatchAndTheExportAgree() throws {
        let view = GradientSwatch.SwatchView(mesh: lopsided)
        view.frame = NSRect(x: 0, y: 0, width: 60, height: 60)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let swatch = try XCTUnwrap(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.sRGB))

        // A tiny screenshot with generous padding, so the canvas corner is background, not image.
        var style = CaptureBackground()
        style.fill = .mesh(lopsided)
        style.padding = 40
        style.shadow = nil
        let exported = try XCTUnwrap(BackgroundCompositor.render(Self.solidImage(), style: style))
        let corner = try XCTUnwrap(topLeft(of: exported)?.usingColorSpace(.sRGB))

        XCTAssertEqual(swatch.redComponent, corner.redComponent, accuracy: 0.06,
                       "the picker is showing something the export does not produce")
        XCTAssertEqual(swatch.blueComponent, corner.blueComponent, accuracy: 0.06)
    }

    private static func solidImage(side: Int = 20) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()!
    }
}

/// The document format. A background is saved in the same file as the annotations, so a fill that
/// fails to decode does not lose a background — `CaptureDocumentFile.decode` falls back to opening
/// the capture flat, which loses **every edit in the document**.
final class BackgroundPersistenceTests: XCTestCase {

    private func roundTrip(_ fill: CaptureBackground.Fill) throws -> CaptureBackground.Fill {
        var style = CaptureBackground()
        style.fill = fill
        let data = try JSONEncoder().encode(style)
        return try JSONDecoder().decode(CaptureBackground.self, from: data).fill
    }

    func testACustomMeshSurvivesARoundTrip() throws {
        let mesh = MeshSpec(columns: 3, rows: 2, colours: [
            RGBAColour(hex: "112233"), RGBAColour(hex: "445566"), RGBAColour(hex: "778899"),
            RGBAColour(hex: "AABBCC"), RGBAColour(hex: "DDEEFF"), RGBAColour(hex: "010203"),
        ])
        XCTAssertEqual(try roundTrip(.mesh(mesh)), .mesh(mesh))
    }

    func testEveryOtherFillStillRoundTrips() throws {
        for fill: CaptureBackground.Fill in [.none, .solid(.red), .builtIn(id: "ocean"),
                                             .image(fileName: "wall.png"),
                                             .gradient(GradientSpec(stops: [
                                                .init(colour: .red, location: 0),
                                                .init(colour: .blue, location: 1)]))] {
            XCTAssertEqual(try roundTrip(fill), fill, "\(fill) did not survive")
        }
    }

    /// The case that matters: the wire shape is the one the synthesised coder wrote, so a document
    /// saved before the hand-written codec existed still opens.
    func testADocumentWrittenByTheOldCoderStillOpens() throws {
        let json = """
        {"fill":{"builtIn":{"id":"dusk"}},"padding":64,"cornerRadius":16,\
        "aspect":"original","shadow":{"radius":40,"offsetY":20,"opacity":0.35,\
        "colour":{"r":0,"g":0,"b":0,"a":1}}}
        """
        let style = try JSONDecoder().decode(CaptureBackground.self, from: Data(json.utf8))
        XCTAssertEqual(style.fill, .builtIn(id: "dusk"))
        XCTAssertEqual(style.padding, 64)
    }

    /// A fill this build has never heard of is held verbatim and written back byte-for-byte, so a
    /// newer build's background is not quietly replaced by opening the file in an older one.
    func testAnUnrecognisedFillIsPreservedRatherThanDropped() throws {
        let json = #"{"fill":{"video":{"fileName":"loop.mov","seed":7}},"padding":12,"#
                 + #""cornerRadius":4,"aspect":"original"}"#
        let style = try JSONDecoder().decode(CaptureBackground.self, from: Data(json.utf8))
        guard case .unknown(let type, _) = style.fill else {
            return XCTFail("an unknown fill decoded as \(style.fill) instead of being held")
        }
        XCTAssertEqual(type, "video")

        let written = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(style)) as? [String: Any]
        let fill = try XCTUnwrap(written?["fill"] as? [String: Any])
        let video = try XCTUnwrap(fill["video"] as? [String: Any])
        XCTAssertEqual(video["fileName"] as? String, "loop.mov")
        XCTAssertEqual(video["seed"] as? Int, 7)
    }

    /// A mesh that does not hold the colours it claims must not reach the renderer as an editable
    /// grid — a short array from a truncated file would be an index crash at draw time.
    func testAMalformedStoredMeshIsNotOfferedForEditing() {
        let broken = MeshSpec(columns: 3, rows: 3, colours: [.red, .blue])
        XCTAssertNil(CaptureBackground.Fill.mesh(broken).editableMesh)
        XCTAssertNotNil(CaptureBackground.Fill.builtIn(id: "dusk").editableMesh)
        XCTAssertNil(CaptureBackground.Fill.solid(.red).editableMesh)
    }
}

/// Adding a property to `CaptureBackground` must not orphan documents written before it.
extension BackgroundPersistenceTests {
    func testADocumentMissingLaterPropertiesStillOpens() throws {
        // Exactly the keys the format had before `spacing` and `isAutoBalanced` were added.
        let json = #"{"fill":{"builtIn":{"id":"ocean"}},"padding":40,"cornerRadius":8,"#
                 + #""aspect":"square"}"#
        let style = try JSONDecoder().decode(CaptureBackground.self, from: Data(json.utf8))
        XCTAssertEqual(style.fill, .builtIn(id: "ocean"))
        XCTAssertEqual(style.aspect, .square)
        XCTAssertEqual(style.spacing, CaptureBackground().spacing,
                       "a property added later should fall back to its default, not throw")
        XCTAssertFalse(style.isAutoBalanced)
    }

    /// "No shadow" and "shadow not mentioned" are different documents and must stay different.
    func testAnExplicitlyAbsentShadowIsNotReplacedByTheDefault() throws {
        let none = try JSONDecoder().decode(
            CaptureBackground.self, from: Data(#"{"fill":{"none":{}},"shadow":null}"#.utf8))
        XCTAssertNil(none.shadow, "a document saying there is no shadow got the default one back")

        let unmentioned = try JSONDecoder().decode(
            CaptureBackground.self, from: Data(#"{"fill":{"none":{}}}"#.utf8))
        XCTAssertNotNil(unmentioned.shadow)

        let partial = try JSONDecoder().decode(
            CaptureBackground.self, from: Data(#"{"shadow":{"radius":12}}"#.utf8))
        XCTAssertEqual(partial.shadow?.radius, 12)
        XCTAssertEqual(partial.shadow?.opacity, CaptureBackground.Shadow().opacity)
    }
}

/// Banding at the size an export actually is, not the size a swatch is.
@MainActor
final class ExportBandingTests: XCTestCase {

    /// A Retina-sized canvas is past the renderer's pixel budget, so the buffer is rendered
    /// smaller and scaled up — the exact move the dither comment warns destroys the dither.
    /// This is the one defect a 30pt swatch cannot show, so it is measured on a real export.
    func testAFullSizeExportDoesNotBand() throws {
        var style = CaptureBackground()
        style.fill = .builtIn(id: "ocean")
        style.padding = 300
        style.shadow = nil

        let shot = Self.solid(width: 2400, height: 1400)
        let exported = try XCTUnwrap(BackgroundCompositor.render(shot, style: style))
        let rep = NSBitmapImageRep(cgImage: exported)

        // A horizontal run through the padding above the screenshot: all background.
        var transitions = 0
        var previous: (Int, Int, Int)?
        let y = 120
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            let value = (Int(colour.redComponent * 255), Int(colour.greenComponent * 255),
                         Int(colour.blueComponent * 255))
            if let previous, previous != value { transitions += 1 }
            previous = value
        }

        // Undithered, a 3000px span of this gradient steps about 120 times — 25px bands. Grain
        // means transitions in the thousands.
        XCTAssertGreaterThan(transitions, 1000,
                             "only \(transitions) colour changes across \(rep.pixelsWide)px: the "
                             + "dither was resampled away and the export bands")
    }

    private static func solid(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

private extension NSColor {
    /// This colour as it resolves in a given appearance.
    ///
    /// A dynamic catalog colour asked for its `cgColor` outside a drawing context answers for
    /// whatever appearance happens to be current, which in a test is not the one being
    /// photographed.
    func withAppearance(_ appearance: NSAppearance?) -> NSColor {
        guard let appearance else { return self }
        var resolved = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: self.usingColorSpace(.sRGB)?.cgColor ?? self.cgColor)
                ?? self
        }
        return resolved
    }
}

/// The colour grid, rendered and looked at.
@MainActor
final class BackgroundInspectorTests: XCTestCase {

    func testWriteTheInspector() throws {
        guard let directory = PreviewDirectory.path else {
            throw XCTSkip("set SARVKRIT_PREVIEW_DIR to write the preview")
        }
        let base = MeshRenderer.image(BackgroundCatalogue.entries[0].mesh, width: 400, height: 300)!
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let model = EditorDocumentModel(base: base)
            model.edit { $0.background = CaptureBackground() }
            let view = NSHostingView(rootView: BackgroundInspector(
                model: model,
                presets: BackgroundPresetStore(directory: temporaryDirectory()),
                wallpapers: WallpaperStore(directory: temporaryDirectory())))
            // Tall enough that the scroll view is not the thing being photographed. The panel had
            // grown past the old 560 and everything below the mesh editor was simply off the
            // bottom of the picture, which is a poor way to check a panel's design.
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 980)
            // **Explicit, or the labels come out invisible.** An `NSHostingView` with no window
            // resolves `.secondary` against no appearance at all, and every caption in the panel
            // rendered as nothing — which reads in the PNG exactly like a missing label.
            view.appearance = NSAppearance(named: appearance)
            // **And a ground to stand on.** A hosting view paints no background of its own, so in
            // dark mode the whole panel was white-on-white and looked, in the PNG, like a picker
            // with no labels and no sliders. In the app it sits on the window's material; here
            // that has to be said out loud.
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.windowBackgroundColor
                .withAppearance(NSAppearance(named: appearance)).cgColor
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("inspector-\(appearance.rawValue).png"))
        }
    }

    /// A throwaway folder, so the preview never shows whatever presets or wallpapers happen to be
    /// on the machine running it.
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
