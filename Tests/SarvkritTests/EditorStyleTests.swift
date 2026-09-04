import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Restyling what is already on the canvas.
///
/// The toolbar used to affect only the *next* mark, which made changing your mind about a colour
/// mean deleting and redrawing. That is the difference between a toolbar and a preference.
@MainActor
final class EditorStyleTests: XCTestCase {

    private func model() throws -> EditorDocumentModel {
        let base = try StubScreenCaptureService.image(size: CGSize(width: 200, height: 200))
        return EditorDocumentModel(base: base)
    }

    func testChangingColourRestylesTheSelectedElement() throws {
        let model = try model()
        model.edit { $0.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 50, y: 50)))) }
        model.selection = model.document.elements.first?.id

        model.colour = .green
        model.applyStyleToSelection()

        guard case .arrow(let arrow) = model.document.elements[0].kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(arrow.stroke.colour, .green)
    }

    func testChangingTheArrowStyleRestylesTheSelectedArrow() throws {
        let model = try model()
        model.edit { $0.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 50, y: 50)))) }
        model.selection = model.document.elements.first?.id

        model.arrowHead = .thin
        model.applyStyleToSelection()

        guard case .arrow(let arrow) = model.document.elements[0].kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(arrow.head, .thin)
    }

    func testThicknessIsScaledForTheCapture() throws {
        // Every stored length is in image pixels, so a 6pt-looking stroke on a 2x capture is 12.
        let base = try StubScreenCaptureService.image(size: CGSize(width: 200, height: 200))
        var document = AnnotationDocument(imageSize: CGSize(width: 200, height: 200), scale: 2)
        document.add(.line(LineElement(start: .zero, end: CGPoint(x: 50, y: 0))))
        let model = EditorDocumentModel(base: base, document: document)
        model.selection = model.document.elements.first?.id
        model.strokeWidth = 6
        model.applyStyleToSelection()

        guard case .line(let line) = model.document.elements[0].kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertEqual(line.stroke.width, 12)
    }

    func testRestylingWithNothingSelectedChangesNothing() throws {
        let model = try model()
        model.edit { $0.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 50, y: 50)))) }
        let before = model.document
        model.selection = nil
        model.colour = .purple
        model.applyStyleToSelection()
        XCTAssertEqual(model.document, before)
    }

    func testRestylingIsOneUndoStep() throws {
        let model = try model()
        model.edit { $0.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 50, y: 50)))) }
        model.selection = model.document.elements.first?.id
        model.colour = .blue
        model.applyStyleToSelection()

        model.undo()
        guard case .arrow(let arrow) = model.document.elements[0].kind else {
            return XCTFail("wrong kind")
        }
        XCTAssertNotEqual(arrow.stroke.colour, .blue, "one undo should put the colour back")
    }

    func testEveryArrowStyleIsReachable() throws {
        // Four shapes were built; the picker is what makes three of them usable at all.
        for head in [ArrowElement.Head.filled, .open, .thin, .curved] {
            let model = try model()
            model.arrowHead = head
            model.edit {
                $0.add(.arrow(ArrowElement(start: .zero, end: CGPoint(x: 80, y: 0),
                                           head: model.arrowHead)))
            }
            guard case .arrow(let arrow) = model.document.elements[0].kind else {
                return XCTFail("wrong kind")
            }
            XCTAssertEqual(arrow.head, head)
        }
    }
}
