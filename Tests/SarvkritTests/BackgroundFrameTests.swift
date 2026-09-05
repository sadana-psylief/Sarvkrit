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

    /// The bug report this replaces: "alignment does not work only left center right no top or
    /// bottom."
    ///
    /// It was true, and it was a design error rather than a wiring one. Alignment used to spend
    /// only the slack *left over* after the padding, and the only thing that ever creates slack
    /// is the Ratio target — which grows exactly one dimension. On `.original` with a landscape
    /// shot that is always the horizontal one, so vertical free space was zero forever.
    ///
    /// Alignment now redistributes the padding itself, keeping the total, so all nine directions
    /// do something on any capture.
    func testEveryAlignmentMovesTheShot() {
        func origin(_ alignment: CaptureBackground.Alignment) -> CGPoint {
            BackgroundLayout.compute(imageSize: image, style: style {
                $0.padding = 40
                $0.alignment = alignment
            }).imageRect.origin
        }
        let centre = origin(.centre)
        for alignment in CaptureBackground.Alignment.allCases where alignment != .centre {
            XCTAssertNotEqual(origin(alignment), centre, "\(alignment) did not move")
        }
        // And each one moves the way its name says.
        XCTAssertLessThan(origin(.top).y, centre.y)
        XCTAssertGreaterThan(origin(.bottom).y, centre.y)
        XCTAssertLessThan(origin(.leading).x, centre.x)
        XCTAssertGreaterThan(origin(.trailing).x, centre.x)
    }

    func testCentreIsExactlyWhereItAlwaysWas() {
        // The one alignment that must not change: everything anybody has already made is centred.
        let placed = BackgroundLayout.compute(imageSize: image, style: style {
            $0.padding = 40
            $0.alignment = .centre
        })
        XCTAssertEqual(placed.imageRect.minX, 40, accuracy: 0.001)
        XCTAssertEqual(placed.imageRect.minY, 40, accuracy: 0.001)
    }

    func testAnAlignedShotKeepsAMarginAndTheTotalPadding() {
        // Never flush: a shot jammed against the canvas edge reads as a mistake, and the shadow
        // would be clipped by it. A quarter of the padding stays on the near side and the rest
        // goes opposite, so the total is preserved either way.
        let padding: CGFloat = 40
        let placed = BackgroundLayout.compute(imageSize: image, style: style {
            $0.padding = padding
            $0.alignment = .topLeading
        })
        XCTAssertEqual(placed.imageRect.minX, padding * 0.25, accuracy: 0.001)
        XCTAssertEqual(placed.imageRect.minY, padding * 0.25, accuracy: 0.001)

        let canvas = BackgroundLayout.compute(imageSize: image, style: style {
            $0.padding = padding
            $0.alignment = .topLeading
        }).canvas
        XCTAssertEqual(canvas.width - placed.imageRect.maxX, padding * 1.75, accuracy: 0.001,
                       "the padding moved, it did not evaporate")
    }

    func testOppositeAlignmentsMirrorEachOther() {
        func rect(_ alignment: CaptureBackground.Alignment) -> CGRect {
            BackgroundLayout.compute(imageSize: image, style: style {
                $0.padding = 40
                $0.alignment = alignment
            }).imageRect
        }
        let canvas = BackgroundLayout.compute(imageSize: image, style: style {
            $0.padding = 40
        }).canvas
        XCTAssertEqual(rect(.leading).minX, canvas.width - rect(.trailing).maxX, accuracy: 0.001)
        XCTAssertEqual(rect(.top).minY, canvas.height - rect(.bottom).maxY, accuracy: 0.001)
    }

    func testWithNoPaddingAlignmentGoesFlush() {
        // Nothing to preserve, so the shot goes all the way. Only reachable when there is slack
        // from a ratio target or an inset, since otherwise the canvas is the image.
        let placed = BackgroundLayout.compute(imageSize: image, style: style {
            $0.padding = 0
            $0.aspect = .square
            $0.alignment = .top
        })
        XCTAssertEqual(placed.imageRect.minY, 0, accuracy: 0.001)
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

/// The shadow slider's single number.
final class ShadowAmountTests: XCTestCase {

    /// Opening the panel, nudging the shadow and putting it back must leave the picture it
    /// started with — at **any** capture size, now that the mapping scales with one.
    func testAnyAmountSurvivesARoundTripAtAnySize() {
        for shortSide in [CGFloat(300), 500, 1200, 4000] {
            for amount in [Double(5), 20, 50, 80, 100] {
                let shadow = BackgroundInspector.shadow(amount, shortSide: shortSide)
                let back = BackgroundInspector.shadowAmount(for: shadow, shortSide: shortSide)
                XCTAssertEqual(back, amount, accuracy: 0.5, "\(amount) at \(shortSide)")
            }
        }
    }

    /// The midpoint still means the shadow everybody is used to — but only at the capture size
    /// `CaptureBackground.Shadow()`'s absolute numbers were chosen for. That is the point of
    /// scaling: 50 is the same *look* everywhere, not the same forty pixels everywhere.
    func testFiftyOnAFiveHundredPixelShotIsTheOldDefault() {
        let original = CaptureBackground.Shadow()
        let restored = BackgroundInspector.shadow(50, shortSide: 500)
        XCTAssertEqual(restored?.radius ?? 0, original.radius, accuracy: 0.5)
        XCTAssertEqual(restored?.offsetY ?? 0, original.offsetY, accuracy: 0.5)
        XCTAssertEqual(restored?.opacity ?? 0, original.opacity, accuracy: 0.01)
    }

    func testABiggerCaptureGetsABiggerShadow() {
        // The whole complaint: an absolute 40-pixel radius is invisible on a 4K shot.
        let small = BackgroundInspector.shadow(50, shortSide: 400)
        let large = BackgroundInspector.shadow(50, shortSide: 2400)
        XCTAssertEqual((large?.radius ?? 0) / (small?.radius ?? 1), 6, accuracy: 0.01)
    }

    func testZeroMeansNoShadow() {
        XCTAssertNil(BackgroundInspector.shadow(0, shortSide: 500))
        XCTAssertEqual(BackgroundInspector.shadowAmount(for: nil, shortSide: 500), 0)
    }

    func testMoreIsMore() {
        let light = BackgroundInspector.shadow(20, shortSide: 500)
        let heavy = BackgroundInspector.shadow(90, shortSide: 500)
        XCTAssertLessThan(light?.radius ?? 0, heavy?.radius ?? 0)
        XCTAssertLessThan(light?.opacity ?? 0, heavy?.opacity ?? 0)
    }
}

/// Corner radii past what CoreGraphics will accept.
final class RoundedPathTests: XCTestCase {

    /// `CGPath(roundedRect:cornerWidth:cornerHeight:)` asserts when the corner is more than half
    /// the side. The Corners slider used to stop at 64 and could never get there; it now reaches
    /// half the shorter side exactly, and Inset shrinks the drawn rect *below* the size that
    /// maximum was computed from — so this is reachable from the UI, not just from a bad document.
    func testARadiusPastHalfTheSideIsAStadiumNotACrash() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let path = CGPath.rounded(rect, cornerRadius: 5_000)
        XCTAssertEqual(path.boundingBox.width, 200, accuracy: 0.5)
        XCTAssertEqual(path.boundingBox.height, 100, accuracy: 0.5)
        // A stadium: the mid-height point of the left edge is on the path's boundary, while the
        // corner the radius has eaten is not inside it.
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)), "the corner should be rounded away")
        XCTAssertTrue(path.contains(CGPoint(x: 100, y: 50)), "the middle is still filled")
    }

    func testZeroRadiusIsAPlainRect() {
        let path = CGPath.rounded(CGRect(x: 0, y: 0, width: 40, height: 40), cornerRadius: 0)
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1)), "no corner should be taken off")
    }

    func testANegativeRadiusIsTreatedAsZero() {
        let path = CGPath.rounded(CGRect(x: 0, y: 0, width: 40, height: 40), cornerRadius: -20)
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 1)))
    }

    /// The reachable-from-the-UI case, end to end: corners at the slider's maximum *and* an inset.
    func testCornersAtMaximumWithAnInsetStillComposites() throws {
        let base = try XCTUnwrap(CGContext(
            data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        base.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.9, alpha: 1))
        base.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let image = try XCTUnwrap(base.makeImage())

        var style = CaptureBackground()
        style.cornerRadius = 100        // half the shorter side, the slider's new maximum
        style.inset = 50                // and then shrink the rect below what that assumed
        style.padding = 40
        XCTAssertNotNil(BackgroundCompositor.render(image, style: style, sources: .init(base: image)))
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
