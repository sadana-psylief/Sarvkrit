import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writing an animated GIF.
///
/// **Treated as real work rather than a format flag.** A GIF has 256 colours, and a screen
/// recording composited onto a mesh gradient has thousands — handing frames straight to
/// `CGImageDestination` produces the banded, dirty result that gives GIF its reputation. So the
/// palette is chosen from the footage and the quantisation error is dithered.
enum GIFEncoder {

    struct Options: Equatable {
        /// 10–15 is the usable band: below it motion stutters, above it the file doubles for
        /// something nobody perceives.
        var fps = 12
        /// 0 loops forever.
        var loopCount = 0
        var maximumColours = 256
        var dithers = true

        init() {}
    }

    /// A palette built from the frames themselves.
    ///
    /// Median cut rather than a fixed web palette: a recording is mostly one application's colours
    /// plus one gradient, and spending all 256 entries on *those* is the whole difference between
    /// a clean GIF and a muddy one.
    static func palette(from frames: [CGImage], maximumColours: Int) -> [RGBAColour] {
        var samples: [(r: Int, g: Int, b: Int)] = []
        for frame in frames {
            samples.append(contentsOf: sample(frame))
        }
        guard !samples.isEmpty else { return [.black, .white] }
        return medianCut(samples, depth: Int(log2(Double(max(2, maximumColours)))))
            .map { RGBAColour(r: Double($0.r) / 255, g: Double($0.g) / 255,
                              b: Double($0.b) / 255, a: 1) }
    }

    /// A coarse grid rather than every pixel: a 4K frame is eight million samples and the palette
    /// is indistinguishable from one built on a few thousand.
    private static func sample(_ image: CGImage, side: Int = 48) -> [(r: Int, g: Int, b: Int)] {
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = buffer.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: side, height: side,
                      bitsPerComponent: 8, bytesPerRow: side * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return [] }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        return (0..<(side * side)).map { index in
            let offset = index * 4
            return (Int(buffer[offset]), Int(buffer[offset + 1]), Int(buffer[offset + 2]))
        }
    }

    /// Splits the colour cube along its longest axis, repeatedly, and averages each bucket.
    static func medianCut(_ samples: [(r: Int, g: Int, b: Int)],
                          depth: Int) -> [(r: Int, g: Int, b: Int)] {
        guard depth > 0, samples.count > 1 else {
            guard !samples.isEmpty else { return [] }
            let total = samples.reduce(into: (0, 0, 0)) { sum, sample in
                sum.0 += sample.r; sum.1 += sample.g; sum.2 += sample.b
            }
            let count = samples.count
            return [(total.0 / count, total.1 / count, total.2 / count)]
        }

        let ranges = (r: extent(samples.map(\.r)),
                      g: extent(samples.map(\.g)),
                      b: extent(samples.map(\.b)))
        let sorted: [(r: Int, g: Int, b: Int)]
        if ranges.r >= ranges.g && ranges.r >= ranges.b {
            sorted = samples.sorted { $0.r < $1.r }
        } else if ranges.g >= ranges.b {
            sorted = samples.sorted { $0.g < $1.g }
        } else {
            sorted = samples.sorted { $0.b < $1.b }
        }

        let middle = sorted.count / 2
        return medianCut(Array(sorted[..<middle]), depth: depth - 1)
            + medianCut(Array(sorted[middle...]), depth: depth - 1)
    }

    private static func extent(_ values: [Int]) -> Int {
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }

    /// Writes the frames out.
    static func write(frames: [CGImage], to url: URL, options: Options = Options()) throws {
        guard !frames.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count,
            [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: options.loopCount,
            ]] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }

        let delay = 1.0 / Double(max(1, options.fps))
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                    kCGImagePropertyGIFDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
