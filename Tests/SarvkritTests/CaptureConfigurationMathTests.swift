import XCTest
@testable import Sarvkrit

/// The window-capture sizing rule.
///
/// `captureImage` produces exactly the configured size, so the configured size is the crop. These
/// pin that it is derived from the filter's content rect and never from a separately-sourced
/// window frame — see `CaptureConfigurationMath` for what was actually measured on macOS 26,
/// which is less dramatic than the usual telling of this.
final class CaptureConfigurationMathTests: XCTestCase {

    func testSizeComesFromTheContentRect() {
        let size = CaptureConfigurationMath.pixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), pointPixelScale: 2)
        XCTAssertEqual(size.width, 800)
        XCTAssertEqual(size.height, 600)
    }

    func testWhenTheTwoSourcesDisagreeTheContentRectWins() {
        // The case the file exists for: whenever the filter's content rect and the window frame
        // differ, the buffer must follow the content rect, because that is what will be rendered.
        // Sizing from the frame here would clip 40pt off each edge.
        let windowFrame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let contentRect = windowFrame.insetBy(dx: -40, dy: -40)      // shadow spills outside

        let correct = CaptureConfigurationMath.pixelSize(
            contentRect: contentRect, pointPixelScale: 2)
        let naive = CaptureConfigurationMath.naivePixelSize(
            windowFrame: windowFrame, pointPixelScale: 2)

        XCTAssertEqual(correct.width, 960)
        XCTAssertEqual(naive.width, 800)
        XCTAssertNotEqual(correct.width, naive.width,
                          "fixture no longer distinguishes the two sizings")
        XCTAssertNotEqual(correct.height, naive.height)
    }

    func testWhenTheTwoSourcesAgreeSoDoTheAnswers() {
        // Which is why a frame-based implementation looks fine: on macOS 26 the two always agreed
        // in practice, so the wrong version passes every test you'd think to write first.
        let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        let correct = CaptureConfigurationMath.pixelSize(contentRect: frame, pointPixelScale: 2)
        let naive = CaptureConfigurationMath.naivePixelSize(windowFrame: frame, pointPixelScale: 2)
        XCTAssertEqual(correct.width, naive.width)
        XCTAssertEqual(correct.height, naive.height)
    }

    func testFractionalRectsRoundRatherThanTruncate() {
        // 100.5pt at 2x is 201 pixels. Truncating shaves a row off every capture that lands on a
        // fractional boundary, which a trackpad does constantly.
        let size = CaptureConfigurationMath.pixelSize(
            contentRect: CGRect(x: 0, y: 0, width: 100.5, height: 100.5), pointPixelScale: 2)
        XCTAssertEqual(size.width, 201)
        XCTAssertEqual(size.height, 201)
    }

    func testASizeIsNeverZero() {
        // A zero-dimension configuration makes SCK throw rather than return an empty image.
        let size = CaptureConfigurationMath.pixelSize(contentRect: .zero, pointPixelScale: 2)
        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
    }
}
