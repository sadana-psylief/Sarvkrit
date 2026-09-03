import CoreGraphics
import XCTest
@testable import Sarvkrit

/// Redaction, which is a security property rather than a visual style.
///
/// The stake is asymmetric: a weak blur over a password is worse than no blur, because the user
/// believes they redacted it and then shares the image. These pin the parts that make that claim
/// either true or false.
final class PixelFiltersTests: XCTestCase {

    /// An image with a hard black/white split, so a filter's effect is unmistakable.
    private func split(width: Int = 64, height: Int = 64) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        return try XCTUnwrap(context.makeImage())
    }

    /// A checkerboard with the same mean as `split` but completely different structure.
    private func checkerboard(width: Int = 64, height: Int = 64) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<height {
            for x in 0..<width {
                let on = (x + y) % 2 == 0
                context.setFillColor(CGColor(red: on ? 1 : 0, green: on ? 1 : 0,
                                             blue: on ? 1 : 0, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(buffer.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    func testSecureBlurOutputDoesNotDependOnTheContent() throws {
        // The definition of "secure" here: the output is a function of the region's mean colour,
        // the seed and the geometry — nothing else. Two images with the same mean and opposite
        // structure must therefore produce the same patch.
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let element = PixelFilterElement(rect: rect, mode: .secureBlur, radius: 20, seed: 42)

        let fromSplit = try XCTUnwrap(PixelFilters.render(element, over: try split()))
        let fromChecker = try XCTUnwrap(PixelFilters.render(element, over: try checkerboard()))

        XCTAssertEqual(try pixels(fromSplit), try pixels(fromChecker),
                       "secure redaction must not carry the structure of what it covers")
    }

    func testSecureBlurActuallyChangesThePixels() throws {
        // The complement of the test above: identical output is only meaningful if it isn't
        // simply the original.
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let element = PixelFilterElement(rect: rect, mode: .secureBlur, radius: 20, seed: 1)
        let base = try split()
        let redacted = try XCTUnwrap(PixelFilters.render(element, over: base))
        XCTAssertNotEqual(try pixels(redacted), try pixels(base))
    }

    func testPixelateIsDeterministicForASeed() throws {
        // Stored jitter rather than a fresh roll, so a reopened document renders identically
        // instead of shimmering every time it is drawn.
        let element = PixelFilterElement(rect: CGRect(x: 0, y: 0, width: 64, height: 64),
                                         mode: .pixellate, radius: 16, seed: 7)
        let base = try split()
        let first = try XCTUnwrap(PixelFilters.render(element, over: base))
        let second = try XCTUnwrap(PixelFilters.render(element, over: base))
        XCTAssertEqual(try pixels(first), try pixels(second))
    }

    func testADifferentSeedGivesADifferentJitter() throws {
        let base = try checkerboard()
        let a = PixelFilterElement(rect: CGRect(x: 0, y: 0, width: 64, height: 64),
                                   mode: .pixellate, radius: 16, seed: 1)
        var b = a
        b.seed = 2
        XCTAssertNotEqual(try pixels(try XCTUnwrap(PixelFilters.render(a, over: base))),
                          try pixels(try XCTUnwrap(PixelFilters.render(b, over: base))))
    }

    func testTheMinimumCellSizeIsEnforced() {
        // Depix-class attacks recover pixelated text reliably when the alphabet is small — which
        // is exactly the password and account-number case.
        let rect = CGRect(x: 0, y: 0, width: 400, height: 60)
        XCTAssertGreaterThanOrEqual(PixelFilters.minimumCellSize(for: rect, scale: 1), 16)
        XCTAssertGreaterThanOrEqual(PixelFilters.minimumCellSize(for: rect, scale: 2), 32,
                                    "a Retina capture needs a proportionally larger cell")
    }

    func testOnlySecureModeClaimsToBeSecure() {
        // Naming is part of the safety here: a mode that says "blur" must not imply privacy.
        XCTAssertTrue(PixelFilterElement.Mode.secureBlur.isSecure)
        XCTAssertFalse(PixelFilterElement.Mode.smoothBlur.isSecure)
        XCTAssertFalse(PixelFilterElement.Mode.pixellate.isSecure)
        XCTAssertEqual(PixelFilterElement.Mode.smoothBlur.title, "Blur (smooth)")
    }

    func testABlurAtTheImageEdgeDoesNotDarkenTheBorder() throws {
        // Without clampedToExtent, CIGaussianBlur samples transparent black from outside the
        // image and leaves a dark vignette along any edge it touches. This fails the moment
        // someone removes the clamp.
        let base = try XCTUnwrap({ () -> CGImage? in
            let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return context?.makeImage()
        }())

        let element = PixelFilterElement(rect: CGRect(x: 0, y: 0, width: 64, height: 20),
                                         mode: .smoothBlur, radius: 12, seed: 0)
        let blurred = try XCTUnwrap(PixelFilters.render(element, over: base))
        let data = try pixels(blurred)

        // Sample the top-left corner, which is flush against two edges.
        let corner = Int(data[0])
        XCTAssertGreaterThan(corner, 200,
                             "a white image blurred at its edge must stay white, not darken")
    }

    func testAZeroSizedRegionRendersNothingRatherThanCrashing() throws {
        let element = PixelFilterElement(rect: .zero, mode: .secureBlur, radius: 10, seed: 0)
        XCTAssertNil(PixelFilters.render(element, over: try split()))
    }

    func testTheCacheReturnsTheSameImageForTheSameElement() throws {
        let cache = PixelFilterCache()
        let base = try split()
        let element = PixelFilterElement(rect: CGRect(x: 0, y: 0, width: 32, height: 32),
                                         mode: .secureBlur, radius: 10, seed: 3)
        let first = try XCTUnwrap(cache.image(for: element, base: base, downscale: 1))
        let second = try XCTUnwrap(cache.image(for: element, base: base, downscale: 1))
        XCTAssertTrue(first === second, "a Gaussian over a large bitmap must not be redone per frame")
    }
}

final class SeededRandomTests: XCTestCase {

    func testTheSameSeedGivesTheSameSequence() {
        var a = SeededRandom(seed: 99)
        var b = SeededRandom(seed: 99)
        XCTAssertEqual((0..<10).map { _ in a.next() }, (0..<10).map { _ in b.next() })
    }

    func testDifferentSeedsDiverge() {
        var a = SeededRandom(seed: 1)
        var b = SeededRandom(seed: 2)
        XCTAssertNotEqual((0..<10).map { _ in a.next() }, (0..<10).map { _ in b.next() })
    }

    func testAZeroSeedStillProducesAUsableSequence() {
        // xorshift is stuck at zero forever if it is ever seeded with it.
        var generator = SeededRandom(seed: 0)
        XCTAssertNotEqual(generator.next(), 0)
        XCTAssertNotEqual(generator.next(), generator.next())
    }

    func testUnitValuesStayInRange() {
        var generator = SeededRandom(seed: 12_345)
        for _ in 0..<200 {
            let value = generator.nextUnit()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }
}
