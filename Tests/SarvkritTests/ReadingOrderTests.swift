import XCTest
@testable import Sarvkrit

/// Reading order, over synthetic boxes — no Vision involved.
///
/// This is where OCR quality lives: the recognition is Apple's, the ordering is ours, and a naive
/// top-to-bottom sort turns any two-column screenshot into interleaved nonsense.
final class ReadingOrderTests: XCTestCase {

    private func fragment(_ text: String, x: Double, y: Double,
                          width: Double = 100, height: Double = 20) -> ReadingOrder.Fragment {
        ReadingOrder.Fragment(text: text,
                              rect: CGRect(x: x, y: y, width: width, height: height))
    }

    func testASingleLineComesBackVerbatim() {
        let text = ReadingOrder.text(from: [fragment("hello", x: 0, y: 0)])
        XCTAssertEqual(text, "hello")
    }

    func testWordsOnOneLineAreOrderedLeftToRight() {
        let text = ReadingOrder.text(from: [
            fragment("world", x: 120, y: 0, width: 80),
            fragment("hello", x: 0, y: 0, width: 100),
        ])
        XCTAssertEqual(text, "hello world")
    }

    func testWobblyBaselinesStillClusterIntoOneLine() {
        // One bold word a point taller, or a baseline that drifts, must not split a line in two.
        let text = ReadingOrder.text(from: [
            fragment("the", x: 0, y: 100, width: 40, height: 20),
            fragment("quick", x: 50, y: 103, width: 60, height: 22),
            fragment("fox", x: 120, y: 99, width: 40, height: 19),
        ])
        XCTAssertEqual(text, "the quick fox")
    }

    func testTwoColumnsAreNotInterleaved() {
        // The case that makes or breaks this. Sorted purely by y, the output would read
        // "Left one / Right one / Left two / Right two".
        let text = ReadingOrder.text(from: [
            fragment("Left one", x: 0, y: 0, width: 100),
            fragment("Right one", x: 400, y: 0, width: 100),
            fragment("Left two", x: 0, y: 30, width: 100),
            fragment("Right two", x: 400, y: 30, width: 100),
        ])
        XCTAssertEqual(text, "Left one\nLeft two\nRight one\nRight two")
    }

    func testAnOrdinaryParagraphIsNotShreddedIntoColumns() {
        // Words with normal inter-word gaps belong to one flow, however many there are.
        let words = (0..<8).map { fragment("w\($0)", x: Double($0) * 55, y: 0, width: 50) }
        let text = ReadingOrder.text(from: words)
        XCTAssertEqual(text, "w0 w1 w2 w3 w4 w5 w6 w7")
    }

    func testAParagraphGapBecomesABlankLine() {
        let text = ReadingOrder.text(from: [
            fragment("first", x: 0, y: 0, height: 20),
            fragment("second", x: 0, y: 25, height: 20),
            fragment("far below", x: 0, y: 120, height: 20),
        ])
        XCTAssertEqual(text, "first\nsecond\n\nfar below")
    }

    func testEmptyInputProducesEmptyText() {
        XCTAssertEqual(ReadingOrder.text(from: []), "")
        XCTAssertTrue(ReadingOrder.lines(from: []).isEmpty)
    }

    func testLinesAreReturnedTopToBottomWithinAColumn() {
        let lines = ReadingOrder.lines(from: [
            fragment("third", x: 0, y: 60),
            fragment("first", x: 0, y: 0),
            fragment("second", x: 0, y: 30),
        ])
        XCTAssertEqual(lines.map { $0.map(\.text).joined() }, ["first", "second", "third"])
    }
}

final class CombineLayoutTests: XCTestCase {
    private let a = CGSize(width: 200, height: 100)
    private let b = CGSize(width: 200, height: 150)

    func testAVerticalStackIsTheSumPlusTheGaps() {
        let (canvas, frames) = CombineLayout.compute(sizes: [a, b], mode: .vertical,
                                                     spacing: 10, normalize: .none)
        XCTAssertEqual(canvas.height, 100 + 10 + 150)
        XCTAssertEqual(canvas.width, 200)
        XCTAssertEqual(frames[1].minY, 110)
    }

    func testSpacingIsBetweenNotAround() {
        // The outer margin is the Background tool's padding; having both would double it.
        let (canvas, frames) = CombineLayout.compute(sizes: [a, a], mode: .vertical,
                                                     spacing: 40, normalize: .none)
        XCTAssertEqual(frames[0].minY, 0, "no gap before the first")
        XCTAssertEqual(canvas.height, 100 + 40 + 100, "and none after the last")
    }

    func testAHorizontalRowIsTheSameTheOtherWay() {
        let (canvas, _) = CombineLayout.compute(sizes: [a, b], mode: .horizontal,
                                                spacing: 10, normalize: .none)
        XCTAssertEqual(canvas.width, 200 + 10 + 200)
        XCTAssertEqual(canvas.height, 150)
    }

    func testNarrowerImagesAreCentredInAVerticalStack() {
        let narrow = CGSize(width: 100, height: 100)
        let (_, frames) = CombineLayout.compute(sizes: [a, narrow], mode: .vertical,
                                                spacing: 0, normalize: .none)
        XCTAssertEqual(frames[1].minX, 50, "otherwise a mixed set reads as left-aligned by accident")
    }

    func testMatchingTheLargestScalesTheOthersUp() {
        let small = CGSize(width: 100, height: 50)
        let (_, frames) = CombineLayout.compute(sizes: [a, small], mode: .vertical,
                                                spacing: 0, normalize: .widest)
        XCTAssertEqual(frames[1].width, 200)
        XCTAssertEqual(frames[1].height, 100, "the aspect ratio is preserved")
    }

    func testMatchingTheSmallestScalesTheOthersDown() {
        let small = CGSize(width: 100, height: 50)
        let (canvas, _) = CombineLayout.compute(sizes: [a, small], mode: .vertical,
                                                spacing: 0, normalize: .narrowest)
        XCTAssertEqual(canvas.width, 100)
    }

    func testAGridFillsRowMajor() {
        let sizes = Array(repeating: a, count: 4)
        let (canvas, frames) = CombineLayout.compute(sizes: sizes, mode: .grid(columns: 2),
                                                     spacing: 10, normalize: .none)
        XCTAssertEqual(canvas.width, 200 * 2 + 10)
        XCTAssertEqual(canvas.height, 100 * 2 + 10)
        XCTAssertEqual(frames[0].origin, .zero)
        XCTAssertEqual(frames[1].minX, 210)
        XCTAssertEqual(frames[2].minY, 110)
    }

    func testAGridWithAPartialLastRow() {
        let sizes = Array(repeating: a, count: 5)
        let (canvas, frames) = CombineLayout.compute(sizes: sizes, mode: .grid(columns: 2),
                                                     spacing: 0, normalize: .none)
        XCTAssertEqual(canvas.height, 100 * 3, "three rows for five images in two columns")
        XCTAssertEqual(frames[4].minY, 200)
    }

    func testASingleImageIsUnchanged() {
        let (canvas, frames) = CombineLayout.compute(sizes: [a], mode: .vertical,
                                                     spacing: 50, normalize: .widest)
        XCTAssertEqual(canvas, a)
        XCTAssertEqual(frames, [CGRect(origin: .zero, size: a)])
    }

    func testNoImagesIsAnEmptyCanvasNotACrash() {
        let (canvas, frames) = CombineLayout.compute(sizes: [], mode: .vertical,
                                                     spacing: 10, normalize: .none)
        XCTAssertEqual(canvas, .zero)
        XCTAssertTrue(frames.isEmpty)
    }

    func testAZeroColumnGridIsTreatedAsOne() {
        let (_, frames) = CombineLayout.compute(sizes: [a, a], mode: .grid(columns: 0),
                                                spacing: 0, normalize: .none)
        XCTAssertEqual(frames[1].minY, 100, "stacked, not overlapping")
    }
}
