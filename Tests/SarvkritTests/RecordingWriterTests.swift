import AVFoundation
import CoreMedia
import XCTest
@testable import Sarvkrit

/// The frame sink.
///
/// **This suite exists because of a crash.** `SCStream` delivers sample buffers on its own serial
/// queue, and the first version of the recorder wrapped the handler in `MainActor.assumeIsolated`
/// — which is an assertion, not a hop. The first frame of the first recording trapped with
/// `EXC_BREAKPOINT`, so recording appeared impossible to switch on at all.
///
/// The lesson is narrow and worth keeping: **the hot path must not touch the main actor.** Hopping
/// sixty times a second to append one frame would be wrong even if it were safe.
final class RecordingWriterTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("writer-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func writer() throws -> RecordingWriter {
        try RecordingWriter(url: directory.appendingPathComponent("screen.mov"),
                            size: CGSize(width: 64, height: 64), fps: 60)
    }

    /// A frame with no image, which is all this needs: the crash was in the dispatch assertion
    /// before the buffer was ever looked at.
    private func sample(at seconds: Double) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    /// **The regression test.** Appending from a background queue must simply work — this is
    /// exactly what ScreenCaptureKit does, and the old code trapped on it.
    func testAFrameCanBeAppendedFromABackgroundQueue() throws {
        let writer = try self.writer()
        let queue = DispatchQueue(label: "test.frames")
        let appended = expectation(description: "frame appended off the main thread")

        queue.async {
            XCTAssertFalse(Thread.isMainThread, "the point of this test is the other thread")
            writer.append(try? self.sample(at: 0))
            appended.fulfill()
        }
        wait(for: [appended], timeout: 5)
        XCTAssertGreaterThan(writer.elapsed, -1)
    }

    /// The same serial queue delivers every frame, so the writer is exercised the way SCK uses it.
    func testManyFramesFromTheStreamQueueAreAccepted() throws {
        let writer = try self.writer()
        let queue = DispatchQueue(label: "test.frames")
        let done = expectation(description: "frames appended")

        queue.async {
            for index in 0..<30 {
                writer.append(try? self.sample(at: Double(index) / 60))
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(writer.elapsed, 29.0 / 60.0, accuracy: 0.05)
    }

    /// Elapsed and dropped are read from the main actor by the HUD while frames are still arriving
    /// on the stream queue, so both sides have to be safe at once.
    func testCountersCanBeReadWhileFramesArrive() throws {
        let writer = try self.writer()
        let queue = DispatchQueue(label: "test.frames")
        let done = expectation(description: "frames appended")

        queue.async {
            for index in 0..<60 { writer.append(try? self.sample(at: Double(index) / 60)) }
            done.fulfill()
        }
        for _ in 0..<50 {
            _ = writer.elapsed
            _ = writer.droppedFrames
        }
        wait(for: [done], timeout: 10)
    }

    /// Elapsed means *recorded* time. A paused recording must not appear to still be running.
    func testPausingStopsTheClock() throws {
        let writer = try self.writer()
        writer.append(try sample(at: 0))
        writer.append(try sample(at: 1))
        writer.pause()
        writer.append(try sample(at: 5))
        writer.resume()
        writer.append(try sample(at: 6))
        // One second recorded before the pause, one after; the four-second gap is rebased out.
        XCTAssertEqual(writer.elapsed, 2, accuracy: 0.1)
    }

    func testTheFirstFrameAnchorsTheClock() throws {
        let writer = try self.writer()
        // A stream that starts at a non-zero presentation time must still report from zero.
        writer.append(try sample(at: 1000))
        writer.append(try sample(at: 1002))
        XCTAssertEqual(writer.elapsed, 2, accuracy: 0.05)
    }

    func testTheFirstFrameHostTimeIsReportedOnce() throws {
        let writer = try self.writer()
        XCTAssertNil(writer.firstFrameHostTime)
        writer.append(try sample(at: 0))
        let anchor = writer.firstFrameHostTime
        XCTAssertNotNil(anchor)
        writer.append(try sample(at: 1))
        XCTAssertEqual(writer.firstFrameHostTime, anchor, "the anchor moved after the first frame")
    }

    func testANilBufferIsIgnoredRatherThanCounted() throws {
        let writer = try self.writer()
        writer.append(nil)
        XCTAssertEqual(writer.droppedFrames, 0)
    }

    func testFinishingProducesAFile() async throws {
        let writer = try self.writer()
        writer.append(try sample(at: 0))
        writer.append(try sample(at: 0.5))
        await writer.finish()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("screen.mov").path))
    }
}
