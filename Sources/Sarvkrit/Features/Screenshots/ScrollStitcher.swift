import CoreGraphics
import Foundation

/// One captured frame, reduced to what the stitcher needs.
struct ScrollFrame: Equatable {
    /// Row hashes for a vertical scroll, column hashes for a horizontal one.
    let lines: [UInt64]
    let width: Int
    let height: Int

    /// Lines along the scroll axis.
    var length: Int { lines.count }
}

/// Where every frame's lines end up in the finished image.
struct StitchPlan: Equatable {
    struct Placement: Equatable {
        let frameIndex: Int
        /// Lines taken from that frame.
        let sourceRange: Range<Int>
        /// Where they land in the output.
        let destinationOffset: Int
    }

    let placements: [Placement]
    let totalLength: Int
    /// Lines identical in every frame at the head — a sticky header, written once.
    let stickyLeading: Int
    let stickyTrailing: Int
    let endedBecause: EndReason
}

enum EndReason: Equatable {
    case contentExhausted
    case frameLimit
    /// Two consecutive frames didn't overlap — the user scrolled further than a screen, or the
    /// content changed completely. Reported rather than guessed at.
    case noOverlapFound(atFrame: Int)
}

/// Assembling a scrolling capture.
///
/// **Pure over `[UInt64]`, deliberately.** The whole algorithm — overlap detection, sticky
/// regions, when to stop — is decided here against line hashes, with no bitmap in sight, so the
/// test fixtures are arrays a person can read. `render` is the only part that touches pixels, and
/// it is kept trivial enough to eyeball because it is the part that cannot be tested this way.
enum ScrollStitcher {

    struct Options: Equatable {
        /// Below this many matching lines, a match isn't believed.
        var minimumOverlap = 40
        /// How much better than second-best a match must be. This is what makes a page of uniform
        /// background report *no* match rather than a confident wrong one.
        var minimumMargin = 0.15
        /// A runaway capture must not eat memory without bound.
        var frameLimit = 40
    }

    /// Best offset of `b` within `a`, by normalised agreement over line hashes.
    ///
    /// - Returns: nil when nothing scores well enough, or when the best candidate isn't clearly
    ///   better than the runner-up. **The margin is the whole point**: a scrolling page of solid
    ///   white matches at every offset equally well, and a confident wrong answer there produces
    ///   a silently mangled image, where an admission of failure can be retried.
    static func offset(of b: [UInt64], in a: [UInt64],
                       minimumOverlap: Int) -> (offset: Int, score: Double, margin: Double)? {
        guard !a.isEmpty, !b.isEmpty else { return nil }

        var best = (offset: 0, score: 0.0)
        var second = 0.0

        // `shift` is how far b has moved down relative to a.
        for shift in 0...max(0, a.count - 1) {
            let overlap = min(a.count - shift, b.count)
            guard overlap >= minimumOverlap else { break }
            var matches = 0
            for index in 0..<overlap where a[shift + index] == b[index] { matches += 1 }
            let score = Double(matches) / Double(overlap)
            if score > best.score {
                second = best.score
                best = (offset: shift, score: score)
            } else if score > second {
                second = score
            }
        }

        guard best.score > 0.6 else { return nil }
        return (offset: best.offset, score: best.score, margin: best.score - second)
    }

    /// Decides where every frame's lines go.
    static func plan(frames: [ScrollFrame], axis: ScrollAxis, options: Options) -> StitchPlan {
        guard let first = frames.first else {
            return StitchPlan(placements: [], totalLength: 0, stickyLeading: 0,
                              stickyTrailing: 0, endedBecause: .contentExhausted)
        }

        let sticky = stickyRegions(in: frames)
        let bodyStart = sticky.leading
        let bodyEnd = first.length - sticky.trailing

        var placements: [StitchPlan.Placement] = [
            .init(frameIndex: 0, sourceRange: 0..<first.length, destinationOffset: 0)
        ]
        var written = first.length - sticky.trailing
        var reason = EndReason.contentExhausted

        for index in 1..<max(1, frames.count) {
            if index >= options.frameLimit {
                reason = .frameLimit
                break
            }
            let previous = frames[index - 1]
            let current = frames[index]

            // Match on the body only: a sticky header is identical in every frame and would match
            // at offset zero every time, pinning the stitch in place.
            let previousBody = Array(previous.lines[bodyStart..<min(bodyEnd, previous.length)])
            let currentBody = Array(current.lines[bodyStart..<min(bodyEnd, current.length)])

            guard let match = offset(of: currentBody, in: previousBody,
                                     minimumOverlap: options.minimumOverlap),
                  match.margin >= options.minimumMargin else {
                reason = .noOverlapFound(atFrame: index)
                break
            }

            // Identical frames mean the page stopped moving: the end of the content.
            if match.offset == 0 {
                reason = .contentExhausted
                break
            }

            // Everything below the overlap is new.
            let newLines = match.offset
            let takeFrom = bodyEnd - newLines
            guard takeFrom >= bodyStart, newLines > 0 else {
                reason = .contentExhausted
                break
            }
            placements.append(.init(frameIndex: index,
                                    sourceRange: takeFrom..<bodyEnd,
                                    destinationOffset: written))
            written += newLines
        }

        // The sticky footer goes on once, at the very bottom.
        if sticky.trailing > 0 {
            placements.append(.init(frameIndex: 0,
                                    sourceRange: (first.length - sticky.trailing)..<first.length,
                                    destinationOffset: written))
            written += sticky.trailing
        }

        return StitchPlan(placements: placements, totalLength: written,
                          stickyLeading: sticky.leading, stickyTrailing: sticky.trailing,
                          endedBecause: reason)
    }

    /// Lines identical across *every* frame at the head and the tail.
    ///
    /// Only full-width sticky elements are found this way; a floating "back to top" button sits in
    /// the middle of its rows and will repeat. Stated rather than pretended otherwise.
    static func stickyRegions(in frames: [ScrollFrame]) -> (leading: Int, trailing: Int) {
        guard let first = frames.first, frames.count > 1 else { return (0, 0) }

        var leading = 0
        while leading < first.length,
              frames.allSatisfy({ leading < $0.length && $0.lines[leading] == first.lines[leading] }) {
            leading += 1
        }
        // Every line matching means the frames are identical, not that the whole page is sticky.
        if leading == first.length { return (0, 0) }

        var trailing = 0
        while trailing < first.length - leading,
              frames.allSatisfy({ frame in
                  let index = frame.length - 1 - trailing
                  return index >= 0 && frame.lines[index] == first.lines[first.length - 1 - trailing]
              }) {
            trailing += 1
        }
        return (leading, trailing)
    }

    /// The one impure step: blit according to a plan.
    static func render(_ plan: StitchPlan, images: [CGImage], axis: ScrollAxis) -> CGImage? {
        guard let first = images.first, plan.totalLength > 0 else { return nil }
        let width = axis == .vertical ? first.width : plan.totalLength
        let height = axis == .vertical ? plan.totalLength : first.height
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        for placement in plan.placements {
            guard placement.frameIndex < images.count else { continue }
            let image = images[placement.frameIndex]
            let length = placement.sourceRange.count
            guard length > 0 else { continue }

            let sourceRect = axis == .vertical
                ? CGRect(x: 0, y: placement.sourceRange.lowerBound,
                         width: image.width, height: length)
                : CGRect(x: placement.sourceRange.lowerBound, y: 0,
                         width: length, height: image.height)
            guard let slice = image.cropping(to: sourceRect) else { continue }

            // CGContext is bottom-left; the plan counts from the top.
            let destination = axis == .vertical
                ? CGRect(x: 0, y: height - placement.destinationOffset - length,
                         width: width, height: length)
                : CGRect(x: placement.destinationOffset, y: 0, width: length, height: height)
            context.draw(slice, in: destination)
        }
        return context.makeImage()
    }
}
