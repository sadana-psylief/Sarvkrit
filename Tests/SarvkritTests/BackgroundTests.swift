import CoreGraphics
import XCTest
@testable import Sarvkrit

final class BackgroundCatalogueTests: XCTestCase {

    func testEveryBackgroundHasItsOwnIdAndName() {
        // The count is no longer the point — it was twenty, it is thirty-two, and it will grow
        // again. What must hold is that no two share an id, because the id is what a saved
        // document stores, and that no two share a name, because the name is the only thing
        // distinguishing one 30pt swatch from another in the picker's tooltip.
        XCTAssertGreaterThanOrEqual(BackgroundCatalogue.entries.count, 20)
        let ids = BackgroundCatalogue.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate id")
        let names = BackgroundCatalogue.entries.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate name")
    }

    /// The twenty that shipped are load-bearing: their ids are in documents already saved, and
    /// re-tuning one in place would change a background somebody already chose.
    func testTheOriginalTwentyAreStillThereUnderTheirOwnIds() {
        let original = ["dusk", "ember", "mint", "ocean", "sand", "slate", "paper", "ink",
                        "blossom", "citrus", "forest", "lavender", "rose", "steel", "aurora",
                        "cocoa", "sky", "plum", "moss", "graphite"]
        let ids = Set(BackgroundCatalogue.entries.map(\.id))
        for id in original {
            XCTAssertTrue(ids.contains(id), "\(id) went missing")
        }
    }

    func testEveryEntryHasAUsableMesh() {
        // Replaces the two-stop check. The presets are meshes now — a line through colour space
        // could not hold what these do.
        for entry in BackgroundCatalogue.entries {
            XCTAssertTrue(entry.mesh.isWellFormed, "\(entry.id)")
            XCTAssertLessThanOrEqual(entry.lightnessRange.lowerBound,
                                     entry.lightnessRange.upperBound, "\(entry.id)")
        }
    }

    func testANeutralPresetClaimsNoHueAndSoContrastsWithEverything() {
        // Paper and Graphite are deliberately grey. Extracting a hue from a grey would be
        // meaningless — the channel that happens to lead by a hair would decide it — so they
        // report none, and `nearestHue` treats that as maximally distant. Which is right: a
        // neutral background sits behind any colour of screenshot.
        let paper = try! XCTUnwrap(BackgroundCatalogue.entry(id: "paper"))
        XCTAssertTrue(paper.hues.isEmpty)

        let vivid = try! XCTUnwrap(BackgroundCatalogue.entry(id: "ember"))
        XCTAssertFalse(vivid.hues.isEmpty, "a coloured preset must expose its hues")
    }

    func testHuesAndLightnessAreDerivedFromTheColoursThemselves() {
        // They used to be hand-typed scalars that nothing checked against the gradient, so an
        // entry could advertise a colour it did not contain. Derived, they cannot drift.
        let entry = try! XCTUnwrap(BackgroundCatalogue.entry(id: "ocean"))
        let lightnesses = entry.mesh.colours.map { colour -> Double in
            (max(colour.r, max(colour.g, colour.b)) + min(colour.r, min(colour.g, colour.b))) / 2
        }
        XCTAssertEqual(entry.lightnessRange.lowerBound, lightnesses.min()!, accuracy: 0.001)
        XCTAssertEqual(entry.lightnessRange.upperBound, lightnesses.max()!, accuracy: 0.001)
    }

    func testTheCatalogueSpansLightAndDark() {
        // Auto Balance needs both, or a dark screenshot has nowhere light to sit.
        XCTAssertTrue(BackgroundCatalogue.entries.contains { $0.lightness >= 0.7 })
        XCTAssertTrue(BackgroundCatalogue.entries.contains { $0.lightness <= 0.3 })
    }

    func testAnUnknownIdFallsBackRatherThanCrashing() {
        XCTAssertNil(BackgroundCatalogue.entry(id: "nope"))
        XCTAssertTrue(BackgroundCatalogue.mesh(for: "nope").isWellFormed)
    }
}

final class AutoBalanceTests: XCTestCase {

    /// A grid with a uniform border and a distinct block in the middle.
    private func bordered(inset: Int, colour: (r: Double, g: Double, b: Double)) -> AutoBalance.Grid {
        let side = 16
        var cells = [(r: Double, g: Double, b: Double)](
            repeating: (1, 1, 1), count: side * side)
        for y in inset..<(side - inset) {
            for x in inset..<(side - inset) {
                cells[y * side + x] = colour
            }
        }
        return AutoBalance.Grid(width: side, height: side, cells: cells)
    }

    func testAUniformMarginIsTrimmed() {
        let bounds = AutoBalance.contentBounds(bordered(inset: 4, colour: (0.1, 0.2, 0.8)))
        XCTAssertEqual(bounds.minX, 4.0 / 16, accuracy: 0.07)
        XCTAssertEqual(bounds.width, 8.0 / 16, accuracy: 0.15)
    }

    func testAFullBleedImageTrimsNothing() {
        // Real content, edge to edge: strong alternating values, which is what a screenshot with
        // no margin actually looks like to this check.
        let side = 8
        let noisy = AutoBalance.Grid(
            width: side, height: side,
            cells: (0..<(side * side)).map { index in
                // (x + y), not the flat index: with an even width, index % 2 is constant down
                // each column, so every column would read as uniform margin.
                let on = ((index % side) + (index / side)) % 2 == 0
                return (r: on ? 0.95 : 0.05, g: on ? 0.9 : 0.1, b: on ? 0.85 : 0.15)
            })
        let bounds = AutoBalance.contentBounds(noisy)
        XCTAssertEqual(bounds.width, 1, accuracy: 0.2)
        XCTAssertEqual(bounds.height, 1, accuracy: 0.2)
    }

    func testAVeryLowContrastGradientCountsAsMargin() {
        // The complement, and a deliberate limitation worth pinning: the check is variance-based,
        // so an almost-flat area reads as margin even if it isn't literally uniform. That is the
        // behaviour that makes padding look optically even on a shot with a soft background.
        let side = 8
        let faint = AutoBalance.Grid(
            width: side, height: side,
            cells: (0..<(side * side)).map { index in
                let value = 0.5 + Double(index % 3) * 0.002
                return (r: value, g: value, b: value)
            })
        XCTAssertLessThan(AutoBalance.contentBounds(faint).width, 0.5)
    }

    func testTheDominantHueIgnoresGreyChrome() {
        // A screenshot is mostly chrome. Without weighting greys down, every image's "dominant
        // colour" is the same pale grey and the choice below means nothing.
        var cells = [(r: Double, g: Double, b: Double)](repeating: (0.6, 0.6, 0.61), count: 100)
        for index in 0..<8 { cells[index] = (0.9, 0.1, 0.1) }      // a little strong red
        let grid = AutoBalance.Grid(width: 10, height: 10, cells: cells)

        let hue = try! XCTUnwrap(AutoBalance.dominantHue(grid))
        XCTAssertLessThan(AutoBalance.circularDistance(hue, 0), 30, "should read as red, not grey")
    }

    func testAnImageWithNoColourHasNoDominantHue() {
        let grey = AutoBalance.Grid(width: 4, height: 4,
                                    cells: Array(repeating: (0.5, 0.5, 0.5), count: 16))
        XCTAssertNil(AutoBalance.dominantHue(grey))
    }

    func testADarkScreenshotNeverGetsADarkBackground() {
        // The contrast floor matters more than the hue: a dark app on a dark backdrop simply
        // disappears into it.
        let entry = try! XCTUnwrap(AutoBalance.suggestedBackground(dominantHue: 220,
                                                                   imageLuma: 0.08))
        XCTAssertGreaterThanOrEqual(entry.lightness, 0.55)
    }

    func testALightScreenshotGetsADarkBackground() {
        let entry = try! XCTUnwrap(AutoBalance.suggestedBackground(dominantHue: 40,
                                                                   imageLuma: 0.92))
        XCTAssertLessThanOrEqual(entry.lightness, 0.45)
    }

    func testTheChosenBackgroundContainsNoHueCloseToTheScreenshots() {
        // Restated for meshes, and it is a stronger claim than the old one. Scoring on a *mean*
        // hue could pick a background that contains the screenshot's colour while averaging far
        // from it — teal-to-indigo averages to a blue in neither lobe. Every hue in the chosen
        // mesh has to be distant, not just the average of them.
        let entry = try! XCTUnwrap(AutoBalance.suggestedBackground(dominantHue: 0,
                                                                   imageLuma: 0.9))
        func nearest(_ candidate: BackgroundCatalogue.Entry) -> Double {
            candidate.hues.map { AutoBalance.circularDistance($0, 0) }.min() ?? 180
        }
        // The claim is that it picks the best available, not that a distant one must exist — a
        // catalogue of nothing but reds should still choose, and choose the least red.
        let pool = BackgroundCatalogue.entries.filter { $0.lightnessRange.upperBound <= 0.5 }
        XCTAssertFalse(pool.isEmpty, "no dark background exists to put a light screenshot on")
        for candidate in pool {
            XCTAssertLessThanOrEqual(nearest(candidate), nearest(entry) + 0.001,
                                     "\(candidate.name) contrasts better than the chosen "
                                     + "\(entry.name)")
        }
    }

    func testPaddingIsClampedAtBothEnds() {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        let tiny = AutoBalance.padding(contentBounds: full,
                                       imageSize: CGSize(width: 40, height: 40))
        let huge = AutoBalance.padding(contentBounds: full,
                                       imageSize: CGSize(width: 8000, height: 8000))
        XCTAssertGreaterThanOrEqual(tiny, 24 * 0.6)
        XCTAssertLessThanOrEqual(huge, 160)
    }

    func testAShotThatIsMostlyMarginGetsLessAddedPadding() {
        let sparse = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let dense = CGRect(x: 0, y: 0, width: 1, height: 1)
        let size = CGSize(width: 1000, height: 1000)
        XCTAssertLessThan(AutoBalance.padding(contentBounds: sparse, imageSize: size),
                          AutoBalance.padding(contentBounds: dense, imageSize: size))
    }

    func testCircularDistanceWrapsAroundTheColourWheel() {
        XCTAssertEqual(AutoBalance.circularDistance(350, 10), 20, accuracy: 0.001)
        XCTAssertEqual(AutoBalance.circularDistance(0, 180), 180, accuracy: 0.001)
    }
}

final class BackgroundCompositorTests: XCTestCase {

    private func image(_ width: Int = 40, _ height: Int = 30) throws -> CGImage {
        try StubScreenCaptureService.image(size: CGSize(width: width, height: height))
    }

    func testTheCompositeIsBiggerThanTheScreenshotByThePadding() throws {
        var style = CaptureBackground()
        style.padding = 20
        style.aspect = .free
        let composed = try XCTUnwrap(BackgroundCompositor.render(try image(100, 60), style: style))
        XCTAssertEqual(composed.width, 140)
        XCTAssertEqual(composed.height, 100)
    }

    func testAnAspectTargetProducesThatAspect() throws {
        var style = CaptureBackground()
        style.padding = 0
        style.aspect = .square
        let composed = try XCTUnwrap(BackgroundCompositor.render(try image(200, 50), style: style))
        XCTAssertEqual(composed.width, composed.height)
    }

    func testAutoBalanceProducesAUsableStyle() throws {
        let style = BackgroundCompositor.autoBalanced(try image(120, 90))
        XCTAssertTrue(style.isAutoBalanced)
        XCTAssertGreaterThan(style.padding, 0)
        if case .builtIn(let id) = style.fill {
            XCTAssertNotNil(BackgroundCatalogue.entry(id: id))
        } else {
            XCTFail("auto balance should choose from the catalogue")
        }
    }

    func testTheGridIsBuiltAtTheRequestedSize() throws {
        let grid = try XCTUnwrap(BackgroundCompositor.grid(from: try image(400, 400), side: 16))
        XCTAssertEqual(grid.width, 16)
        XCTAssertEqual(grid.cells.count, 256)
    }
}

final class ImageCombinerTests: XCTestCase {

    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        try StubScreenCaptureService.image(size: CGSize(width: width, height: height))
    }

    func testAVerticalStackHasTheCombinedHeight() throws {
        let combined = try XCTUnwrap(ImageCombiner.render(
            [try image(100, 40), try image(100, 60)],
            mode: .vertical, spacing: 10, normalize: .none))
        XCTAssertEqual(combined.width, 100)
        XCTAssertEqual(combined.height, 110)
    }

    func testAGridProducesTheGridCanvas() throws {
        let images = try (0..<4).map { _ in try image(50, 50) }
        let combined = try XCTUnwrap(ImageCombiner.render(
            images, mode: .grid(columns: 2), spacing: 0, normalize: .none))
        XCTAssertEqual(combined.width, 100)
        XCTAssertEqual(combined.height, 100)
    }

    func testNoImagesProducesNothingRatherThanCrashing() {
        XCTAssertNil(ImageCombiner.render([], mode: .vertical, spacing: 0, normalize: .none))
    }

    func testTheResultCanBecomeTheBaseOfANewDocument() throws {
        // The reason combining works this way: everything else applies to the result with no
        // special casing at all.
        let combined = try XCTUnwrap(ImageCombiner.render(
            [try image(60, 40), try image(60, 40)],
            mode: .vertical, spacing: 4, normalize: .none))
        let document = AnnotationDocument(
            imageSize: CGSize(width: combined.width, height: combined.height))
        XCTAssertEqual(document.imageSize, CGSize(width: 60, height: 84))
        XCTAssertNotNil(AnnotationRenderer.flatten(document, base: combined))
    }
}

final class BackgroundPresetStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sarvkrit-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testAPresetSurvivesAReload() {
        let store = BackgroundPresetStore(directory: root)
        var style = CaptureBackground()
        style.padding = 99
        store.add(name: "Brand", style: style)

        let reloaded = BackgroundPresetStore(directory: root)
        XCTAssertEqual(reloaded.presets.count, 1)
        XCTAssertEqual(reloaded.presets[0].name, "Brand")
        XCTAssertEqual(reloaded.presets[0].style.padding, 99)
    }

    func testRemovingAPresetPersists() {
        let store = BackgroundPresetStore(directory: root)
        store.add(name: "One", style: CaptureBackground())
        store.remove(id: store.presets[0].id)
        XCTAssertTrue(BackgroundPresetStore(directory: root).presets.isEmpty)
    }

    func testAnUnreadableFileIsLeftInPlace() throws {
        // Same rule as RuleStore: a file we can't parse might be recoverable by hand, and
        // overwriting it guarantees it isn't.
        let url = root.appendingPathComponent("backgrounds.json")
        try Data("not json".utf8).write(to: url)

        let store = BackgroundPresetStore(directory: root)
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json",
                       "the unreadable file must not be replaced")
    }
}
