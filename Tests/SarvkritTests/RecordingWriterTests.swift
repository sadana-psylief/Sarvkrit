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

    // MARK: - System audio

    /// **`capturesAudio` on the stream configuration did nothing on its own.**
    ///
    /// It was set, `hasSystemAudio` was written into the manifest, and no `.audio` stream output was
    /// ever added — so ScreenCaptureKit never delivered a buffer, this writer had no audio input to
    /// put one in, and the manifest's claim was simply false. Audio now rides in `screen.mov`
    /// alongside the picture: one writer, one fragment interval, and a raw recording that plays
    /// with sound.
    func testSystemAudioReachesTheFile() async throws {
        let url = directory.appendingPathComponent("with-system-audio.mov")
        let writer = try RecordingWriter(url: url, size: CGSize(width: 160, height: 120), fps: 60,
                                         capturesAudio: true)

        // A video frame first: the session is anchored on it, so audio arriving earlier has no
        // timeline to sit on and is deliberately dropped.
        for index in 0..<30 {
            writer.append(try sample(at: Double(index) / 60))
            writer.appendAudio(try audioSample(at: Double(index) / 60))
        }
        await writer.finish()

        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty, "system audio never reached the recording")
    }

    /// Audio before the first frame is dropped rather than shifting the whole soundtrack earlier
    /// than the picture.
    func testAudioBeforeTheFirstFrameIsDropped() async throws {
        let url = directory.appendingPathComponent("audio-first.mov")
        let writer = try RecordingWriter(url: url, size: CGSize(width: 160, height: 120), fps: 60,
                                         capturesAudio: true)

        for index in 0..<10 {
            writer.appendAudio(try audioSample(at: Double(index) / 60))
        }
        await writer.finish()

        // No video frame ever landed, so there is no usable file at all — a writer with nothing in
        // it produces something `AVURLAsset` refuses to open, and that is the existing behaviour
        // for a video-only writer. What matters is that audio arriving first did not change it by
        // sneaking a soundtrack in ahead of a picture that never came.
        let asset = AVURLAsset(url: url)
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        XCTAssertTrue(audio.isEmpty, "audio was written with no picture to anchor it to")
    }

    private func audioSample(at seconds: Double) throws -> CMSampleBuffer {
        let rate = 48_000.0
        let frames = 512
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &description)

        let bytes = frames * 4
        let memory = malloc(bytes)!
        memset(memory, 0x20, bytes)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: memory, blockLength: bytes,
                                           blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
            presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: try XCTUnwrap(block),
                                  formatDescription: try XCTUnwrap(description),
                                  sampleCount: frames, sampleTimingEntryCount: 1,
                                  sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: [4], sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }
}
