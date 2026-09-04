import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Inset, alignment, and the shadow amount — the frame around the screenshot.
final class BackgroundFrameTests: XCTestCase {

    private let image = CGSize(width: 400, height: 300)

    private func style(_ change: (inout CaptureBackground) -> Void) -> CaptureBackground {
        var style = CaptureBackground()
        style.fill = .solid(.white)
        style.aspect = .free
        style.padding = 0
        style.shadow = nil
        change(&style)
        return style
    }

    // MARK: - Inset

    func testInsetShrinksTheScreenshotWithoutGrowingTheCanvas() {
        let plain = BackgroundLayout.compute(imageSize: image, style: style { _ in })
        let inset = BackgroundLayout.compute(imageSize: image, style: style { $0.inset = 40 })

        XCTAssertEqual(inset.canvas, plain.canvas, "inset must not change the canvas — that is padding's job")
        XCTAssertLessThan(inset.imageRect.width, plain.imageRect.width)
        XCTAssertLessThan(inset.imageRect.height, plain.imageRect.height)
    }

    func testInsetKeepsTheAspectRatio() {
        let inset = BackgroundLayout.compute(imageSize: image, style: style { $0.inset = 60 })
        XCTAssertEqual(inset.imageRect.width / inset.imageRect.height,
                       image.width / image.height, accuracy: 0.001,
                       "a capture must never be stretched to fit its frame")
    }

    func testAnAbsurdInsetLeavesASliverRatherThanAnInvertedRect() {
        // The slider is bounded, but a document can carry anything and a negative rect draws
        // nothing at all — which looks like the background feature being broken.
        let inset = BackgroundLayout.compute(imageSize: image, style: style { $0.inset = 10_000 })
        XCTAssertGreaterThan(inset.imageRect.width, 0)
        XCTAssertGreaterThan(inset.imageRect.height, 0)
    }

    // MARK: - Alignment

    func testWithNoSlackEveryAlignmentLandsInTheSamePlace() {
        // Correct rather than a bug: with the canvas exactly the padded image there is nowhere
        // else to put it. Pinned so nobody "fixes" alignment by inventing slack.
        let centred = BackgroundLayout.compute(imageSize: image, style: style { $0.padding = 20 })
        for alignment in CaptureBackground.Alignment.allCases {
            let placed = BackgroundLayout.compute(imageSize: image, style: style {
                $0.padding = 20
                $0.alignment = alignment
            })
            XCTAssertEqual(placed.imageRect, centred.imageRect, "\(alignment) moved without slack")
        }
    }

    func testAlignmentSpendsTheSlackAnAspectTargetCreates() {
        func rect(_ alignment: CaptureBackground.Alignment) -> CGRect {
            BackgroundLayout.compute(imageSize: image, style: style {
                $0.aspect = .square
                $0.alignment = alignment
            }).imageRect
        }
        // A 4:3 shot in a square canvas has vertical room and no horizontal room.
        XCTAssertEqual(rect(.top).minY, 0, accuracy: 0.001)
        XCTAssertGreaterThan(rect(.bottom).minY, rect(.top).minY)
        XCTAssertEqual(rect(.centre).minY, rect(.bottom).minY / 2, accuracy: 0.5)
        XCTAssertEqual(rect(.leading).minX, rect(.trailing).minX, accuracy: 0.001,
                       "no horizontal slack, so left and right agree")
    }

    func testAlignmentSpendsTheSlackAnInsetCreates() {
        func rect(_ alignment: CaptureBackground.Alignment) -> CGRect {
            BackgroundLayout.compute(imageSize: image, style: style {
                $0.inset = 30
                $0.alignment = alignment
            }).imageRect
        }
        XCTAssertEqual(rect(.topLeading).minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect(.topLeading).minY, 0, accuracy: 0.001)
        XCTAssertGreaterThan(rect(.bottomTrailing).minX, rect(.topLeading).minX)
        XCTAssertGreaterThan(rect(.bottomTrailing).minY, rect(.topLeading).minY)
    }

    func testCentreIsStillTheDefault() {
        XCTAssertEqual(CaptureBackground().alignment, .centre)
    }

    // MARK: - Round-tripping

    func testTheNewPropertiesSurviveADocument() throws {
        var style = CaptureBackground()
        style.inset = 37
        style.alignment = .bottomTrailing
        style.fill = .blurred(CaptureBackground.Blur(amount: 0.09, tint: -0.5))
        let data = try JSONEncoder().encode(style)
        XCTAssertEqual(try JSONDecoder().decode(CaptureBackground.self, from: data), style)
    }

    func testADocumentWrittenBeforeInsetExistedStillOpens() throws {
        // The rule this file's coder exists for: a property added later must be a non-event for
        // every document already on disk, because the throw is caught upstream and the capture
        // opens *flat* — losing every annotation in it.
        let json = """
        {"fill":{"builtIn":{"id":"dusk"}},"padding":64,"cornerRadius":16,\
        "aspect":"original","spacing":24,"isAutoBalanced":false}
        """
        let style = try JSONDecoder().decode(CaptureBackground.self,
                                             from: Data(json.utf8))
        XCTAssertEqual(style.inset, 0)
        XCTAssertEqual(style.alignment, .centre)
    }
}

/// Auto Balance as a standing preference rather than a one-shot button.
final class AutoBalanceAsAPreferenceTests: XCTestCase {

    private func capture() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 120, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        return try XCTUnwrap(context.makeImage())
    }

    /// The bug this is here for: the panel called `autoBalanced(model.base)` with no `base:`, so
    /// every press built on a *fresh* `CaptureBackground` and silently discarded the user's corner
    /// radius, shadow and aspect. Auto Balance chooses a fill and a padding; it has no business
    /// with the rest of the frame.
    func testItKeepsEverythingItDoesNotChoose() throws {
        var style = CaptureBackground()
        style.cornerRadius = 41
        style.aspect = .sixteenNine
        style.shadow = CaptureBackground.Shadow(radius: 7, offsetY: 3, opacity: 0.9, colour: .black)
        style.inset = 12
        style.alignment = .bottomTrailing

        let balanced = BackgroundCompositor.autoBalanced(try capture(), base: style)

        XCTAssertEqual(balanced.cornerRadius, 41)
        XCTAssertEqual(balanced.aspect, .sixteenNine)
        XCTAssertEqual(balanced.shadow?.radius, 7)
        XCTAssertEqual(balanced.inset, 12)
        XCTAssertEqual(balanced.alignment, .bottomTrailing)
    }

    func testItStillChoosesAFillAndAPadding() throws {
        var style = CaptureBackground()
        style.padding = 999
        let balanced = BackgroundCompositor.autoBalanced(try capture(), base: style)
        XCTAssertNotEqual(balanced.padding, 999)
        XCTAssertTrue(balanced.isAutoBalanced)
    }

    /// Re-balancing has to be stable, or the panel would drift a little with every slider nudge.
    func testBalancingTwiceChangesNothingTheSecondTime() throws {
        let image = try capture()
        let once = BackgroundCompositor.autoBalanced(image, base: CaptureBackground())
        XCTAssertEqual(BackgroundCompositor.autoBalanced(image, base: once), once)
    }
}

/// The blurred-from-the-screenshot backdrop.
final class BlurredBackdropTests: XCTestCase {

    /// A picture with a hard edge, so a blur is measurable rather than a matter of opinion.
    private func split() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
        return try XCTUnwrap(context.makeImage())
    }

    func testTheBackdropActuallyBlurs() throws {
        let source = try split()
        let blurred = try XCTUnwrap(BlurredBackdrop.render(
            source, size: CGSize(width: 200, height: 200),
            blur: CaptureBackground.Blur(amount: 0.06, tint: 0)))
        let rep = NSBitmapImageRep(cgImage: blurred)
        // Right on the seam, a blurred edge is a mix; the original is pure red or pure blue.
        let seam = try XCTUnwrap(rep.colorAt(x: 100, y: 100))
        XCTAssertGreaterThan(seam.redComponent, 0.08, "no red bled across — this is not blurred")
        XCTAssertGreaterThan(seam.blueComponent, 0.08, "no blue bled across — this is not blurred")
    }

    func testTintDarkensAndLightens() throws {
        let source = try split()
        func luma(_ tint: Double) throws -> CGFloat {
            let image = try XCTUnwrap(BlurredBackdrop.render(
                source, size: CGSize(width: 120, height: 120),
                blur: CaptureBackground.Blur(amount: 0.06, tint: tint)))
            let colour = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 60, y: 60))
            return 0.299 * colour.redComponent + 0.587 * colour.greenComponent
                + 0.114 * colour.blueComponent
        }
        XCTAssertLessThan(try luma(-0.6), try luma(0))
        XCTAssertGreaterThan(try luma(0.6), try luma(0))
    }

    func testTheBackdropCoversTheCanvasRatherThanLetterboxingIt() {
        // A wide canvas over a square source. Aspect-*fill*: the drawn rect must be at least as
        // big as the target in both directions, or the backdrop has bars down the side.
        let rect = BlurredBackdrop.fill(CGSize(width: 100, height: 100),
                                        into: CGSize(width: 400, height: 100))
        XCTAssertGreaterThanOrEqual(rect.width, 400)
        XCTAssertGreaterThanOrEqual(rect.height, 100)
        XCTAssertEqual(rect.midX, 200, accuracy: 0.001, "and stays centred")
    }

    func testABlurredFillWithNoImageStillPaintsSomething() throws {
        // A fill that paints nothing is a transparent composite the user cannot see or explain.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        BackgroundCompositor.drawFill(.blurred(CaptureBackground.Blur()),
                                      in: CGRect(x: 0, y: 0, width: 40, height: 40),
                                      context: context)
        let rep = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())))
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 20, y: 20)).alphaComponent, 0.9)
    }
}
