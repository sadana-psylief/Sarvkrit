import XCTest
@testable import Sarvkrit

/// The forward-compatibility contract.
///
/// Swift's synthesised enum Codable throws on an unrecognised case key, which would make one
/// annotation from a newer build render the whole document unopenable — and the obvious recovery,
/// dropping what can't be read, silently deletes the user's work on the next save.
final class AnnotationDocumentCodingTests: XCTestCase {

    private func roundTrip(_ document: AnnotationDocument) throws -> AnnotationDocument {
        try JSONDecoder().decode(AnnotationDocument.self,
                                 from: try JSONEncoder().encode(document))
    }

    func testAKnownDocumentSurvivesARoundTrip() throws {
        var document = AnnotationDocument(imageSize: CGSize(width: 800, height: 600), scale: 2)
        document.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 100, y: 100))))
        document.add(.text(TextElement(origin: CGPoint(x: 10, y: 10), string: "hello")))
        document.cropRect = CGRect(x: 5, y: 5, width: 100, height: 100)

        XCTAssertEqual(try roundTrip(document), document)
    }

    func testEveryElementKindEncodesAndDecodes() throws {
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)
        document.add(.arrow(ArrowElement(start: .zero, end: .init(x: 1, y: 1))))
        document.add(.line(LineElement(start: .zero, end: .init(x: 1, y: 1))))
        document.add(.rectangle(ShapeElement(rect: rect)))
        document.add(.ellipse(ShapeElement(rect: rect)))
        document.add(.text(TextElement(origin: .zero)))
        document.add(.highlighter(HighlightElement(rect: rect)))
        document.add(.pencil(PencilElement(points: [.zero, .init(x: 1, y: 1)])))
        document.add(.spotlight(SpotlightElement(rect: rect)))
        document.add(.counter(CounterElement(centre: .zero)))
        document.add(.blur(PixelFilterElement(rect: rect)))
        document.add(.pixelate(PixelFilterElement(rect: rect)))
        document.add(.emoji(EmojiElement(rect: rect)))

        let decoded = try roundTrip(document)
        XCTAssertEqual(decoded.elements.count, 12)
        XCTAssertEqual(decoded, document)
    }

    func testAnUnknownElementSurvivesARoundTripByteForByte() throws {
        // The whole point. An older build must carry a newer build's work through unchanged.
        let json = """
        {
          "formatVersion": 1,
          "imageSize": [800, 600],
          "scale": 2,
          "elements": [
            { "id": "\(UUID().uuidString)", "z": 0,
              "kind": { "type": "hologram",
                        "payload": { "depth": 3, "tags": ["a", "b"], "on": true, "gone": null } } }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.elements.count, 1)
        XCTAssertTrue(decoded.elements[0].isUnknown)
        XCTAssertEqual(decoded.unknownCount, 1)

        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(AnnotationDocument.self, from: reencoded)
        XCTAssertEqual(again.elements[0].kind, decoded.elements[0].kind,
                       "the unknown payload must come back identical")
    }

    func testAnUnknownElementIsNeverDrawnOrHitTested() throws {
        let json = """
        {"formatVersion":1,"imageSize":[100,100],"scale":1,"elements":[
          {"id":"\(UUID().uuidString)","z":0,"kind":{"type":"future","payload":{"x":1}}}]}
        """
        let document = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        XCTAssertTrue(document.drawable.isEmpty, "an element we can't draw must not be drawn")
        XCTAssertNil(AnnotationGeometry.hitTest(document, at: CGPoint(x: 1, y: 1), tolerance: 50),
                     "selecting something that can't be edited would be a control that does nothing")
    }

    func testAnAdditiveFieldDefaultsRatherThanFailing() throws {
        // A document written before a field existed must still open. Swift's *synthesised*
        // decoder throws keyNotFound here even though the property has a default — verified, not
        // assumed — which is why both types decode by hand.
        let json = """
        {"formatVersion":1,"imageSize":[100,100],"elements":[]}
        """
        let document = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.scale, 1)
        XCTAssertNil(document.cropRect)
    }

    func testCropIsADocumentPropertyNotAnElement() throws {
        // So uncropping restores annotations that were outside the frame, rather than having
        // rewritten every element's origin at crop time and destroyed them.
        var document = AnnotationDocument(imageSize: CGSize(width: 800, height: 600))
        document.add(.rectangle(ShapeElement(rect: CGRect(x: 700, y: 500, width: 50, height: 50))))
        document.cropRect = CGRect(x: 0, y: 0, width: 100, height: 100)

        let decoded = try roundTrip(document)
        guard case .rectangle(let shape) = decoded.elements[0].kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(shape.rect.minX, 700, "coordinates stay absolute in the uncropped bitmap")
    }
}

final class AnnotationCounterTests: XCTestCase {

    func testCountersNumberInDrawOrderNotInsertionOrder() {
        // Draw order is what the reader sees, so a counter moved behind another must renumber.
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        document.add(.counter(CounterElement(centre: CGPoint(x: 10, y: 10))))
        document.add(.counter(CounterElement(centre: CGPoint(x: 20, y: 20))))
        let first = document.elements[0].id

        document.bringToFront(id: first)
        document.renumberCounters()

        let numbers = document.drawable.compactMap { element -> Int? in
            guard case .counter(let counter) = element.kind else { return nil }
            return counter.number
        }
        XCTAssertEqual(numbers, [1, 2])
        guard case .counter(let moved) = document.elements.first(where: { $0.id == first })!.kind
        else { return XCTFail("wrong kind") }
        XCTAssertEqual(moved.number, 2, "the one now in front should be numbered last")
    }

    func testDeletingTheMiddleCounterRenumbersTheRest() {
        // A tutorial that jumps from 1 to 3 is a broken tutorial.
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        for index in 0..<4 {
            document.add(.counter(CounterElement(centre: CGPoint(x: index * 10, y: 0))))
        }
        document.remove(id: document.elements[1].id)

        let numbers = document.drawable.compactMap { element -> Int? in
            guard case .counter(let counter) = element.kind else { return nil }
            return counter.number
        }
        XCTAssertEqual(numbers, [1, 2, 3])
    }

    func testNonCounterElementsDoNotConsumeNumbers() {
        var document = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        document.add(.counter(CounterElement(centre: .zero)))
        document.add(.line(LineElement(start: .zero, end: CGPoint(x: 1, y: 1))))
        document.add(.counter(CounterElement(centre: CGPoint(x: 5, y: 5))))

        let numbers = document.drawable.compactMap { element -> Int? in
            guard case .counter(let counter) = element.kind else { return nil }
            return counter.number
        }
        XCTAssertEqual(numbers, [1, 2])
    }
}
