import AVFoundation
import CoreMedia
import XCTest
@testable import Sarvkrit

/// Turning a camera frame into a bitmap, on the queue it arrived on.
///
/// **The second instance of one mistake, which is why this suite is about the pattern rather than
/// the function.** Both the screen recorder and the camera preview reached back to the main actor
/// from a capture callback with `MainActor.assumeIsolated` — an assertion, not a hop — and both
/// trapped on their first frame. Every existing test called into that code from the main thread,
/// where the assertion holds and the bug is invisible.
///
/// So the rule these tests encode: **anything AVFoundation hands to a delegate queue must be
/// exercised from a background queue.** Testing it from the main thread proves nothing at all.
final class PreviewFrameRendererTests: XCTestCase {

    private func sample() throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    /// **The regression test.** This is precisely what AVFoundation does, and precisely what the
    /// crashing version could not survive.
    func testAFrameConvertsFromABackgroundQueue() throws {
        let renderer = PreviewFrameRenderer()
        let sample = try self.sample()
        let queue = DispatchQueue(label: "test.preview")
        let done = expectation(description: "converted off the main thread")
        var produced: CGImage?

        queue.async {
            XCTAssertFalse(Thread.isMainThread, "the point of this test is the other thread")
            produced = renderer.image(from: sample)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let image = try XCTUnwrap(produced, "no bitmap came back")
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
    }

    /// A capture queue delivers frame after frame; one conversion working is not the same as the
    /// stream surviving.
    func testManyFramesConvertInARow() throws {
        let renderer = PreviewFrameRenderer()
        let queue = DispatchQueue(label: "test.preview")
        let done = expectation(description: "all converted")
        var count = 0

        queue.async {
            for _ in 0..<30 {
                if let sample = try? self.sample(), renderer.image(from: sample) != nil {
                    count += 1
                }
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(count, 30)
    }

    /// The renderer is shared across a session's lifetime, so it has to tolerate being used from
    /// more than one place at once.
    func testTheRendererIsSafeFromSeveralQueuesAtOnce() throws {
        let renderer = PreviewFrameRenderer()
        let done = expectation(description: "all queues finished")
        done.expectedFulfillmentCount = 4

        for index in 0..<4 {
            DispatchQueue(label: "test.preview.\(index)").async {
                for _ in 0..<10 {
                    if let sample = try? self.sample() { _ = renderer.image(from: sample) }
                }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 30)
    }

    /// A buffer with no image is a real thing on a capture queue — a metadata-only sample — and it
    /// must be skipped rather than crashed on.
    func testASampleWithNoImageIsIgnored() throws {
        let renderer = PreviewFrameRenderer()
        var format: CMFormatDescription?
        CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Metadata,
                                  mediaSubType: 0, extensions: nil,
                                  formatDescriptionOut: &format)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format, sampleCount: 0, sampleTimingEntryCount: 0,
                             sampleTimingArray: nil, sampleSizeEntryCount: 0,
                             sampleSizeArray: nil, sampleBufferOut: &sample)
        XCTAssertNil(renderer.image(from: try XCTUnwrap(sample)))
    }
}
