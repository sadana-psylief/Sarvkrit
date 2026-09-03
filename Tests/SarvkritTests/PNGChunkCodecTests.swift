import XCTest
@testable import Sarvkrit

/// Pure Data in, Data out — which is the reason to hand-roll this rather than reach for ImageIO,
/// which cannot write private chunks at all.
final class PNGChunkCodecTests: XCTestCase {

    /// A minimal but structurally valid PNG: signature, IHDR, IDAT, IEND.
    private func minimalPNG() -> Data {
        var data = PNGChunkCodec.signature
        var ihdr = Data()
        ihdr.append(contentsOf: [0, 0, 0, 1, 0, 0, 0, 1])   // 1x1
        ihdr.append(contentsOf: [8, 6, 0, 0, 0])            // 8-bit RGBA
        data.append(PNGChunkCodec.encoded(.init(type: "IHDR", data: ihdr)))
        data.append(PNGChunkCodec.encoded(.init(type: "IDAT", data: Data([1, 2, 3, 4]))))
        data.append(PNGChunkCodec.encoded(.init(type: "IEND", data: Data())))
        return data
    }

    func testItReadsTheChunksOfAPNG() throws {
        let chunks = try PNGChunkCodec.chunks(in: minimalPNG())
        XCTAssertEqual(chunks.map(\.type), ["IHDR", "IDAT", "IEND"])
    }

    func testSomethingThatIsNotAPNGIsRejected() {
        XCTAssertThrowsError(try PNGChunkCodec.chunks(in: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? PNGChunkCodec.Failure, .notAPNG)
        }
    }

    func testAChunkClaimingMoreDataThanExistsIsReported() {
        // The dangerous case: a length field that would have us read past the buffer.
        let full = minimalPNG()
        // Cut inside IDAT's declared payload, so its CRC lies beyond the end of the file.
        let truncated = Data(full.prefix(full.count - 14))
        XCTAssertThrowsError(try PNGChunkCodec.chunks(in: truncated)) { error in
            XCTAssertEqual(error as? PNGChunkCodec.Failure, .truncated)
        }
    }

    func testAFileCutBetweenChunksSimplyEnds() {
        // Distinct from the case above, and deliberately lenient: there is nothing dangerous
        // about a file that stops on a chunk boundary, and the chunks read so far are good.
        let full = minimalPNG()
        let cut = Data(full.prefix(full.count - 6))
        let chunks = try? PNGChunkCodec.chunks(in: cut)
        XCTAssertEqual(chunks?.map(\.type), ["IHDR", "IDAT"])
    }

    func testAnInsertedChunkComesBackOut() throws {
        let payload = Data("annotation layer".utf8)
        let png = try PNGChunkCodec.inserting([.init(type: "srKD", data: payload)],
                                              into: minimalPNG())
        let chunks = try PNGChunkCodec.chunks(in: png)
        XCTAssertEqual(chunks.first { $0.type == "srKD" }?.data, payload)
    }

    func testInsertedChunksGoBeforeIEND() throws {
        // Anything after IEND is outside the file as far as a decoder is concerned.
        let png = try PNGChunkCodec.inserting([.init(type: "srKD", data: Data([1, 2]))],
                                              into: minimalPNG())
        let types = try PNGChunkCodec.chunks(in: png).map(\.type)
        XCTAssertEqual(types.last, "IEND")
        XCTAssertEqual(types, ["IHDR", "IDAT", "srKD", "IEND"])
    }

    func testACorruptChunkIsSkippedRatherThanFailingTheFile() throws {
        // The rule that matters: a damaged annotation layer degrades to "opens as a flat image".
        // The pixels are the part the user cannot recreate.
        var png = try PNGChunkCodec.inserting([.init(type: "srKD", data: Data("payload".utf8))],
                                              into: minimalPNG())
        // Corrupt the last byte of that chunk's CRC.
        let index = png.count - 13
        png[index] = png[index] ^ 0xff

        let chunks = try PNGChunkCodec.chunks(in: png)
        XCTAssertFalse(chunks.contains { $0.type == "srKD" }, "the bad chunk should be dropped")
        XCTAssertTrue(chunks.contains { $0.type == "IHDR" }, "and the good ones kept")
    }

    func testRemovingAChunkLeavesTheRest() throws {
        let png = try PNGChunkCodec.inserting([.init(type: "srKD", data: Data([9]))],
                                              into: minimalPNG())
        let stripped = try PNGChunkCodec.removing(types: ["srKD"], from: png)
        XCTAssertEqual(try PNGChunkCodec.chunks(in: stripped).map(\.type),
                       ["IHDR", "IDAT", "IEND"])
    }

    func testTheChunkTypeCaseBitsSayAncillaryPrivateAndUnsafeToCopy() {
        // Per the PNG spec, bit 5 of each byte carries the meaning. Unsafe-to-copy is the
        // load-bearing one: another editor that crops the image must DROP our annotation
        // coordinates rather than carry forward ones that no longer describe the pixels — stale
        // coordinates would put a redaction over the wrong part of the picture.
        for type in [CaptureDocumentFile.documentChunk, CaptureDocumentFile.baseChunk] {
            let bytes = Array(type.utf8)
            XCTAssertEqual(bytes.count, 4)
            XCTAssertTrue(bytes[0] & 0x20 != 0, "\(type): first byte must be lowercase (ancillary)")
            XCTAssertTrue(bytes[1] & 0x20 != 0, "\(type): second must be lowercase (private)")
            XCTAssertTrue(bytes[2] & 0x20 == 0, "\(type): third must be uppercase (reserved)")
            XCTAssertTrue(bytes[3] & 0x20 == 0, "\(type): fourth must be uppercase (unsafe to copy)")
        }
    }

    func testTheCRCMatchesTheKnownPNGPolynomial() {
        // "IEND" with no data has a CRC every PNG on disk shares.
        XCTAssertEqual(PNGChunkCodec.crc32(Array("IEND".utf8)), 0xAE42_6082)
    }
}

final class CaptureDocumentFileTests: XCTestCase {

    private func image(_ width: Int = 8, _ height: Int = 6) throws -> CGImage {
        try StubScreenCaptureService.image(size: CGSize(width: width, height: height))
    }

    func testAFlatPNGCarriesNoAnnotationLayer() throws {
        let data = try CaptureDocumentFile.encodeFlat(try image())
        XCTAssertFalse(CaptureDocumentFile.isReEditable(data))
        XCTAssertNil(try CaptureDocumentFile.decode(data).document)
    }

    func testAReEditableFileRoundTripsItsDocument() throws {
        var document = AnnotationDocument(imageSize: CGSize(width: 8, height: 6), scale: 2)
        document.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 4, y: 4))))

        let data = try CaptureDocumentFile.encode(document: document,
                                                  base: try image(), flattened: try image())
        XCTAssertTrue(CaptureDocumentFile.isReEditable(data))

        let contents = try CaptureDocumentFile.decode(data)
        XCTAssertEqual(contents.document, document)
        XCTAssertNotNil(contents.base)
        XCTAssertEqual(contents.flattened.width, 8)
    }

    func testAnOrdinaryScreenshotFromAnotherAppOpensAsFlat() throws {
        // Never throw for a well-formed PNG that simply isn't ours.
        let foreign = try CaptureDocumentFile.encodeFlat(try image(12, 10))
        let contents = try CaptureDocumentFile.decode(foreign)
        XCTAssertNil(contents.document)
        XCTAssertEqual(contents.flattened.width, 12)
    }

    func testAnUnreadableAnnotationLayerStillOpensThePixels() throws {
        var data = try CaptureDocumentFile.encodeFlat(try image())
        data = try PNGChunkCodec.inserting(
            [.init(type: CaptureDocumentFile.documentChunk, data: Data("not json".utf8))],
            into: data)

        let contents = try CaptureDocumentFile.decode(data)
        XCTAssertNil(contents.document, "the layer is unreadable")
        XCTAssertEqual(contents.flattened.width, 8, "but the screenshot is not lost")
    }

    func testTheReEditableFileIsStillAValidPNGForEveryoneElse() throws {
        let document = AnnotationDocument(imageSize: CGSize(width: 8, height: 6))
        let data = try CaptureDocumentFile.encode(document: document,
                                                  base: try image(), flattened: try image())
        // What Preview and Quick Look do: decode it as an ordinary image.
        XCTAssertNotNil(CaptureDocumentFile.image(from: data))
    }
}

final class EditorKeyRoutingTests: XCTestCase {

    func testEveryToolLetterIsUnique() {
        let keys = ToolKind.allCases.compactMap(\.key)
        XCTAssertEqual(keys.count, ToolKind.allCases.count, "every tool needs a key")
        XCTAssertEqual(Set(keys).count, keys.count, "two tools share a key")
    }

    func testASingleLetterSelectsItsTool() {
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "r", modifiers: [],
                                               isEditingText: false),
                       .selectTool(.rectangle))
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "A", modifiers: [],
                                               isEditingText: false),
                       .selectTool(.arrow), "case doesn't matter")
    }

    func testLettersAreIgnoredWhileTypingIntoATextAnnotation() {
        // The single most likely bug in this area, and invisible until someone types a word with
        // a tool letter in it.
        XCTAssertNil(EditorKeyRouting.action(forCharacters: "r", modifiers: [],
                                             isEditingText: true))
        XCTAssertNil(EditorKeyRouting.action(forCharacters: "3", modifiers: [],
                                             isEditingText: true))
    }

    func testCommandKeysStillWorkWhileTypingText() {
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "z", modifiers: [.command],
                                               isEditingText: true), .undo)
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "s", modifiers: [.command],
                                               isEditingText: true), .save)
    }

    func testEscapeAlwaysWorksEvenWhileTyping() {
        // How a half-drawn element or a text edit is abandoned; a field that swallowed it would
        // leave no way out but the mouse.
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "\u{1b}", modifiers: [],
                                               isEditingText: true), .cancel)
    }

    func testDigitsSelectColoursOneThroughSix() {
        for digit in 1...6 {
            XCTAssertEqual(EditorKeyRouting.action(forCharacters: "\(digit)", modifiers: [],
                                                   isEditingText: false),
                           .selectColour(digit))
        }
        XCTAssertNil(EditorKeyRouting.action(forCharacters: "7", modifiers: [],
                                             isEditingText: false))
    }

    func testShiftCommandSDistinguishesTheTwoSaves() {
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "s", modifiers: [.command],
                                               isEditingText: false), .save)
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "s",
                                               modifiers: [.command, .shift],
                                               isEditingText: false), .saveEditable)
    }

    func testUndoAndRedo() {
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "z", modifiers: [.command],
                                               isEditingText: false), .undo)
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "z",
                                               modifiers: [.command, .shift],
                                               isEditingText: false), .redo)
    }

    func testDeleteRemovesTheSelection() {
        XCTAssertEqual(EditorKeyRouting.action(forCharacters: "\u{7f}", modifiers: [],
                                               isEditingText: false), .deleteSelection)
    }

    func testAnUnboundKeyDoesNothing() {
        XCTAssertNil(EditorKeyRouting.action(forCharacters: "q", modifiers: [],
                                             isEditingText: false))
    }
}

final class BackgroundLayoutTests: XCTestCase {

    func testPaddingSurroundsTheImage() {
        var style = BackgroundStyle()
        style.padding = 50
        style.aspect = .free
        let (canvas, rect) = BackgroundLayout.compute(imageSize: CGSize(width: 200, height: 100),
                                                      style: style)
        XCTAssertEqual(canvas, CGSize(width: 300, height: 200))
        XCTAssertEqual(rect, CGRect(x: 50, y: 50, width: 200, height: 100))
    }

    func testAnAspectTargetIsMetByPaddingNeverByCropping() {
        // Trimming pixels off a capture to reach 16:9 would silently remove content the user
        // framed on purpose.
        var style = BackgroundStyle()
        style.padding = 0
        style.aspect = .sixteenNine
        let imageSize = CGSize(width: 100, height: 100)
        let (canvas, rect) = BackgroundLayout.compute(imageSize: imageSize, style: style)

        XCTAssertEqual(rect.size, imageSize, "the screenshot is never resized")
        XCTAssertEqual(canvas.width / canvas.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(canvas.width, imageSize.width)
    }

    func testTheImageStaysCentredWhenTheCanvasGrows() {
        var style = BackgroundStyle()
        style.padding = 10
        style.aspect = .square
        let (canvas, rect) = BackgroundLayout.compute(imageSize: CGSize(width: 300, height: 100),
                                                      style: style)
        XCTAssertEqual(rect.midX, canvas.width / 2, accuracy: 0.001)
        XCTAssertEqual(rect.midY, canvas.height / 2, accuracy: 0.001)
    }

    func testAZeroSizedImageIsNotACrash() {
        let (canvas, _) = BackgroundLayout.compute(imageSize: .zero, style: BackgroundStyle())
        XCTAssertEqual(canvas, .zero)
    }
}
