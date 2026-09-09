import AVFoundation
import XCTest
@testable import Sarvkrit

/// Hearing the recording while you edit it.
///
/// **`player.isMuted = true` was unconditional, and `microphone.m4a` was never opened at all.** So
/// narration was not merely quiet in the editor — it had never been loaded, and neither had the
/// system audio riding on the screen's own track. Every clip carries `volume`,
/// `systemAudioVolume` and `isMuted`, and the inspector offers all three, so the editor shipped
/// controls for a soundtrack you could only hear by exporting and opening the file.
///
/// The same shape as the silent-export bug: the recorder captured it, the model stored settings for
/// it, and one layer in the middle never asked for it.
final class StudioPlaybackAudioTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A silent asset is enough: these tests are about whether the transport drives a soundtrack,
    /// not about what it sounds like. `StudioExportTests` owns the "is there signal" question.
    private func silentTrack(seconds: Double) throws -> AVAsset {
        let url = directory.appendingPathComponent("track-\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let rate = 44_100.0
        let frames = 1024
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &description)
        let audioFormat = try XCTUnwrap(description)

        var index = 0
        while Double(index * frames) / rate < seconds {
            var samples = [Int16](repeating: 0, count: frames)
            var block: CMBlockBuffer?
            samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: raw.count,
                    blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                    dataLength: raw.count, flags: 0, blockBufferOut: &block)
                if let block { CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                                             offsetIntoDestination: 0,
                                                             dataLength: raw.count) }
            }
            guard let block else { break }
            var buffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(index * frames),
                                              timescale: CMTimeScale(rate)),
                decodeTimeStamp: .invalid)
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
                                      formatDescription: audioFormat,
                                      sampleCount: frames, sampleTimingEntryCount: 1,
                                      sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                      sampleSizeArray: nil, sampleBufferOut: &buffer)
            if let buffer, input.isReadyForMoreMediaData { input.append(buffer) }
            index += 1
        }
        input.markAsFinished()
        let done = expectation(description: "audio written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 20)
        return AVURLAsset(url: url)
    }

    private func screenOnly(seconds: Double) throws -> URL {
        let url = directory.appendingPathComponent("screen-\(UUID().uuidString).mov")
        let size = CGSize(width: 160, height: 120)
        let writer = try RecordingWriter(url: url, size: size, fps: 60)
        for index in 0..<Int(seconds * 60) {
            writer.append(try pixels(at: Double(index) / 60, size: size))
        }
        let done = expectation(description: "video written")
        Task { await writer.finish(); done.fulfill() }
        wait(for: [done], timeout: 20)
        return url
    }

    private func pixels(at t: Double, size: CGSize) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(40 + Int(t * 60) % 180),
                   CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 600),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    @MainActor
    private func player(seconds: Double = 2) throws -> StudioPlayer {
        let made = StudioPlayer(url: try screenOnly(seconds: seconds))
        made.duration = seconds
        return made
    }

    // MARK: - There is something to play

    /// A screen-only take gains no soundtrack, so nothing is loaded and nothing is decoded for a
    /// recording that has no sound at all.
    @MainActor
    func testARecordingWithNoSoundGetsNoSoundtrack() throws {
        XCTAssertFalse(try player().hasSoundtrack)
    }

    @MainActor
    func testASoundtrackCanBeGiven() throws {
        let player = try player()
        player.setSoundtrack(asset: try silentTrack(seconds: 2), mix: nil as AVAudioMix?)
        XCTAssertTrue(player.hasSoundtrack)
    }

    // MARK: - The transport drives it

    @MainActor
    func testPlayingStartsTheSoundtrack() throws {
        let player = try player()
        player.setSoundtrack(asset: try silentTrack(seconds: 2), mix: nil as AVAudioMix?)
        player.play()
        XCTAssertEqual(player.soundtrackRate, 1)
    }

    @MainActor
    func testPausingStopsTheSoundtrack() throws {
        let player = try player()
        player.setSoundtrack(asset: try silentTrack(seconds: 2), mix: nil as AVAudioMix?)
        player.play()
        player.pause()
        XCTAssertEqual(player.soundtrackRate, 0)
    }

    /// **Running backwards is silent, not garbled.** `AVPlayer` will not play audio at a negative
    /// rate, and J on the shuttle is for finding a frame rather than for listening.
    @MainActor
    func testShuttlingBackwardsSilencesTheSoundtrack() throws {
        let player = try player()
        player.setSoundtrack(asset: try silentTrack(seconds: 2), mix: nil as AVAudioMix?)
        player.shuttle(-1)
        XCTAssertEqual(player.soundtrackRate, 0)
    }

    @MainActor
    func testShuttlingForwardsPlaysItFaster() throws {
        let player = try player()
        player.setSoundtrack(asset: try silentTrack(seconds: 2), mix: nil as AVAudioMix?)
        player.shuttle(2)
        XCTAssertEqual(player.soundtrackRate, 2)
    }

    /// **The soundtrack is in output time, and the picture is in source time.** `StudioAudio`
    /// builds the composition already cut to the timeline, so a trim that makes the two diverge is
    /// the case that would put every word in the wrong place if the audio were seeked like the
    /// video is.
    @MainActor
    func testScrubbingMovesTheSoundtrackInOutputTime() throws {
        let player = try player(seconds: 4)
        // A trim: output 0 is source 2, so seeking the audio like the video would be 2s out.
        player.sourceTime = { $0 + 2 }
        player.setSoundtrack(asset: try silentTrack(seconds: 4), mix: nil as AVAudioMix?)

        player.scrub(to: 1)

        let settled = expectation(description: "the soundtrack followed the playhead")
        var seen: TimeInterval = -1
        let poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                seen = player.soundtrackTime ?? -1
                if abs(seen - 1) < 0.1 { timer.invalidate(); settled.fulfill() }
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        wait(for: [settled], timeout: 5)
        poll.invalidate()
        XCTAssertEqual(seen, 1, accuracy: 0.1,
                       "the soundtrack was seeked to source time rather than output time")
    }
    // MARK: - The model supplies it

    /// **The seam, not a re-implementation.** Asserting that the player ends up with a soundtrack
    /// after the model prepares one is the whole property: the editor is silent exactly when this
    /// handover does not happen, and it never happened at all.
    @MainActor
    func testTheModelGivesThePlayerTheProjectsSoundtrack() async throws {
        let bundle = try RecordingBundle.create(
            at: directory.appendingPathComponent("with-sound.sarvrec"))
        try FileManager.default.copyItem(at: try screenOnly(seconds: 2), to: bundle.screenURL)
        try await writeSilence(to: bundle.microphoneURL, seconds: 2)

        var manifest = RecordingManifest(source: .display,
                                         pixelSize: CGSize(width: 160, height: 120),
                                         pointPixelScale: 1, fps: 60)
        manifest.state = .complete
        manifest.duration = 2
        manifest.hasMicrophone = true
        try bundle.write(manifest)
        try bundle.writeEvents(EventLog())

        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        XCTAssertFalse(model.player.hasSoundtrack, "nothing should be loaded before it is asked for")

        await model.prepareSoundtrack()
        XCTAssertTrue(model.player.hasSoundtrack,
                      "the editor had no soundtrack, so playback is silent")
    }

    /// A screen-only take stays silent and pays for nothing — `StudioAudio.composition` returns nil
    /// and that is an ordinary answer, not a failure.
    @MainActor
    func testAScreenOnlyProjectPreparesNoSoundtrack() async throws {
        let bundle = try RecordingBundle.create(
            at: directory.appendingPathComponent("silent.sarvrec"))
        try FileManager.default.copyItem(at: try screenOnly(seconds: 2), to: bundle.screenURL)

        var manifest = RecordingManifest(source: .display,
                                         pixelSize: CGSize(width: 160, height: 120),
                                         pointPixelScale: 1, fps: 60)
        manifest.state = .complete
        manifest.duration = 2
        try bundle.write(manifest)
        try bundle.writeEvents(EventLog())

        let model = StudioDocumentModel(bundle: bundle, manifest: manifest, events: EventLog())
        await model.prepareSoundtrack()
        XCTAssertFalse(model.player.hasSoundtrack)
    }

    private func writeSilence(to url: URL, seconds: Double) async throws {
        let source = try silentTrack(seconds: seconds)
        guard let asset = source as? AVURLAsset else { return }
        try FileManager.default.copyItem(at: asset.url, to: url)
    }
}
