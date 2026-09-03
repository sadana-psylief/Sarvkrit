import CoreGraphics
import Foundation

enum ScrollAxis: String, Codable, CaseIterable, Equatable {
    case vertical
    case horizontal
}

/// One 64-bit hash per row (or column) of an image.
///
/// Reducing a frame to a vector of hashes is what makes the stitcher a pure function over
/// `[UInt64]` — testable with no bitmaps at all — and it is also much faster than comparing
/// pixels, which matters when this runs on every scroll pause.
///
/// Two details do the real work:
///
/// - **Only the middle 60% of the axis is hashed.** Scrollbars, window chrome and sticky side
///   rails move independently of the content, and including them makes two frames that show the
///   same text hash differently.
/// - **Each channel is quantised to 5 bits before hashing.** Sub-pixel anti-aliasing shifts text
///   by fractions of a pixel as it scrolls, so exact colours differ between frames showing the
///   same line. Quantising absorbs that; hashing raw pixels would find no matches at all on text.
enum ImageLineSignature {

    static func signatures(of image: CGImage, axis: ScrollAxis) -> [UInt64] {
        guard let data = pixels(of: image) else { return [] }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return [] }

        switch axis {
        case .vertical:
            let from = width * 20 / 100, to = max(from + 1, width * 80 / 100)
            return (0..<height).map { y in
                hash(data, width: width, indices: (from..<to).map { (x: $0, y: y) })
            }
        case .horizontal:
            let from = height * 20 / 100, to = max(from + 1, height * 80 / 100)
            return (0..<width).map { x in
                hash(data, width: width, indices: (from..<to).map { (x: x, y: $0) })
            }
        }
    }

    /// FNV-1a over quantised RGB. Not cryptographic — it only has to be stable and well spread.
    private static func hash(_ data: [UInt8], width: Int,
                             indices: [(x: Int, y: Int)]) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for index in indices {
            let offset = (index.y * width + index.x) * 4
            guard offset + 2 < data.count else { continue }
            // >> 3 keeps the top 5 bits of each channel.
            let packed = UInt64(data[offset] >> 3) << 10
                       | UInt64(data[offset + 1] >> 3) << 5
                       | UInt64(data[offset + 2] >> 3)
            value = (value ^ packed) &* 0x100_0000_01b3
        }
        return value
    }

    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
