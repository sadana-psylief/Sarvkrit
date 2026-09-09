import AVFoundation
import CoreMedia
import XCTest
@testable import Sarvkrit

/// Exporting a project to a file.
///
/// **The whole pipeline, end to end, with no window.** A recording is written, a project is built
/// over it, and the exporter is asked for a file — which is the one path that has to work for any
/// of this to be worth anything, and the one nobody notices is broken until they try it.
final class StudioExportTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    /// A real, decodable recording: solid colour frames at 60 fps, written the way the recorder
    /// writes them.
    private func makeRecording(seconds: Double,
                               size: CGSize = CGSize(width: 160, height: 120))
        throws -> RecordingBundle {
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("r.sarvrec"))
        let writer = try RecordingWriter(url: bundle.screenURL, size: size, fps: 60)

        let frames = Int(seconds * 60)
        for index in 0..<frames {
            writer.append(try sample(at: Double(index) / 60, size: size))
        }
        let expectation = expectation(description: "written")
        Task { await writer.finish(); expectation.fulfill() }
        wait(for: [expectation], timeout: 20)

        var manifest = RecordingManifest(source: .display, pixelSize: size,
                                         pointPixelScale: 1, fps: 60)
        manifest.state = .complete
        manifest.duration = seconds
        try bundle.write(manifest)
        try bundle.writeEvents(EventLog())
        return bundle
    }

    /// The same, plus a real `camera.mov`.
    ///
    /// **This fixture is the point.** Every export test before it wrote only `screen.mov`, so "is
    /// the camera in the finished file" was not a question the suite could ask — and the answer, for
    /// the whole life of the feature, was no: nothing ever opened `camera.mov` after recording it.
    private func makeRecordingWithCamera(seconds: Double) throws -> RecordingBundle {
        let bundle = try makeRecording(seconds: seconds)
        let size = CGSize(width: 160, height: 120)
        let writer = try RecordingWriter(url: bundle.cameraURL, size: size, fps: 60)
        for index in 0..<Int(seconds * 60) {
            // Near-white, so the picture-in-picture cannot be confused with the screen beneath it.
            writer.append(try sample(at: Double(index) / 60, size: size, luma: 250))
        }
        let written = expectation(description: "camera written")
        Task { await writer.finish(); written.fulfill() }
        wait(for: [written], timeout: 20)

        var manifest = try bundle.readManifest()
        manifest.hasCamera = true
        try bundle.write(manifest)
        return bundle
    }

    /// A real audio file at the bundle's microphone path: a tone, so "is there sound in the
    /// export" has an answer that is not zero.
    private func writeNarration(to url: URL, seconds: Double) async throws {
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
            for n in 0..<frames {
                let t = Double(index * frames + n) / rate
                samples[n] = Int16(sin(2 * .pi * 440 * t) * 12_000)
            }
            var block: CMBlockBuffer?
            let bytes = frames * 2
            let memory = malloc(bytes)!
            samples.withUnsafeBytes { _ = memcpy(memory, $0.baseAddress!, bytes) }
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: memory,
                                               blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0,
                                               dataLength: bytes, flags: 0, blockBufferOut: &block)
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(index * frames),
                                              timescale: CMTimeScale(rate)),
                decodeTimeStamp: .invalid)
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: try XCTUnwrap(block),
                                      formatDescription: audioFormat, sampleCount: frames,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: [2],
                                      sampleBufferOut: &sample)
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            input.append(try XCTUnwrap(sample))
            index += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    /// The bytes of the first exported frame, for comparing two exports of the same project.
    private func firstFrame(of url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        return Data(bytes: base,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }

    private func sample(at seconds: Double, size: CGSize, luma: Int? = nil) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(luma ?? (40 + Int(seconds * 60) % 180)),
                   CVPixelBufferGetBytesPerRow(buffer) * Int(size.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

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
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    private func project(over bundle: RecordingBundle, seconds: Double) throws -> StudioProject {
        let manifest = try bundle.readManifest()
        return StudioProject(canvasSize: manifest.pixelSize.size,
                             timeline: Timeline(clips: [Clip(sourceStart: 0, sourceEnd: seconds)]))
    }

    // MARK: - The pipeline

    func testAProjectExportsToAPlayableFile() async throws {
        let bundle = try makeRecording(seconds: 1)
        let destination = directory.appendingPathComponent("out.mp4")

        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 1), events: EventLog(),
            recording: bundle, preset: .web, to: destination, onProgress: { _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let asset = AVURLAsset(url: destination)
        let track = try await asset.loadTracks(withMediaType: .video).first
        XCTAssertNotNil(track, "the exported file has no video track")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1, accuracy: 0.2)
    }

    /// **The bug this guards against.** The reader is pulled forward frame by frame, so an
    /// off-by-one in that loop yields a file of the right length made of one repeated frame — which
    /// still opens, still reports the right duration, and is completely wrong.
    func testTheExportIsNotOneFrameRepeated() async throws {
        let bundle = try makeRecording(seconds: 1)
        let destination = directory.appendingPathComponent("out.mp4")

        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 1), events: EventLog(),
            recording: bundle, preset: .web, to: destination, onProgress: { _ in })

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()

        var signatures: Set<Int> = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                signatures.insert(base.load(as: UInt8.self).hashValue)
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        XCTAssertGreaterThan(signatures.count, 1,
                             "every exported frame is identical — the reader never advanced")
    }

    /// **The assertion that was impossible before, and the one that would have caught this.**
    ///
    /// The renderer's own snapshot test hands `drawCamera` a camera image directly, so it proved the
    /// compositing worked and said nothing about whether anything ever supplied one. Nothing did:
    /// both production call sites built `FrameSources(screen:)` and left the other three fields at
    /// their defaults. The camera was recorded faithfully and then never read again.
    func testTheExportContainsTheCamera() async throws {
        let bundle = try makeRecordingWithCamera(seconds: 1)
        let project = try project(over: bundle, seconds: 1)

        let withCamera = directory.appendingPathComponent("with-camera.mp4")
        try await StudioExporter().export(
            project: project, events: EventLog(), recording: bundle,
            preset: .web, to: withCamera, onProgress: { _ in })

        // The same recording again with the camera switched off in its manifest, so the picture in
        // picture is the only difference between the two files.
        var manifest = try bundle.readManifest()
        manifest.hasCamera = false
        try bundle.write(manifest)

        let without = directory.appendingPathComponent("without-camera.mp4")
        try await StudioExporter().export(
            project: project, events: EventLog(), recording: bundle,
            preset: .web, to: without, onProgress: { _ in })

        let a = try await firstFrame(of: withCamera)
        let b = try await firstFrame(of: without)
        XCTAssertNotEqual(a, b, "the exported file is identical with and without a camera track")
    }

    // MARK: - Sound

    /// **The assertion whose absence let every export ship silent.**
    ///
    /// `StudioExporter` did not contain the word "audio" once. It wrote a single video input and
    /// read only the screen's video track — while the recorder captured narration, the manifest
    /// recorded `hasMicrophone`, and `Clip` carried `volume`, `systemAudioVolume` and `isMuted`.
    /// Every one of those controls was editing a track that never reached a file.
    func testTheExportHasAudioWhenTheRecordingHasNarration() async throws {
        let bundle = try makeRecording(seconds: 1)
        try await writeNarration(to: bundle.microphoneURL, seconds: 1)
        var manifest = try bundle.readManifest()
        manifest.hasMicrophone = true
        try bundle.write(manifest)

        let destination = directory.appendingPathComponent("with-sound.mp4")
        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 1), events: EventLog(),
            recording: bundle, preset: .web, to: destination, onProgress: { _ in })

        let asset = AVURLAsset(url: destination)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(audio.isEmpty, "the exported file has no audio track at all")

        let loudest = try await Self.peak(of: destination)
        XCTAssertGreaterThan(loudest, 0.01, "the exported audio track is silent")
    }

    /// Isolates the fixture from the pipeline: if this fails, the test's own tone file is wrong
    /// rather than the exporter.
    func testTheNarrationFixtureAndCompositionAreSound() async throws {
        let bundle = try makeRecording(seconds: 1)
        try await writeNarration(to: bundle.microphoneURL, seconds: 1)

        let asset = AVURLAsset(url: bundle.microphoneURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty, "the fixture wrote no audio track")
        let tonePeak = try await Self.peak(of: bundle.microphoneURL)
        XCTAssertGreaterThan(tonePeak, 0.01, "the fixture's tone is silent")

        let found = await StudioAudio.narrationURL(in: bundle)
        XCTAssertNotNil(found, "StudioAudio did not find the narration file")

        let composition = await StudioAudio.composition(
            project: try project(over: bundle, seconds: 1), recording: bundle)
        XCTAssertNotNil(composition, "no audio composition was built")
        let built = try XCTUnwrap(composition)
        let composed = try await built.asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(composed.isEmpty, "the composition has no audio track")
    }

    /// A muted clip must be silent in the file, not merely marked muted in the editor.
    func testAMutedClipIsSilentInTheFile() async throws {
        let bundle = try makeRecording(seconds: 1)
        try await writeNarration(to: bundle.microphoneURL, seconds: 1)
        var manifest = try bundle.readManifest()
        manifest.hasMicrophone = true
        try bundle.write(manifest)

        var muted = try project(over: bundle, seconds: 1)
        muted.timeline.clips[0].isMuted = true

        let destination = directory.appendingPathComponent("muted.mp4")
        try await StudioExporter().export(
            project: muted, events: EventLog(), recording: bundle,
            preset: .web, to: destination, onProgress: { _ in })

        let loudest = try await Self.peak(of: destination)
        XCTAssertLessThan(loudest, 0.01, "a muted clip still has sound in the exported file")
    }

    /// **Narration starts late, and it must be put back where it belongs.**
    ///
    /// An `AVCaptureSession` takes a couple of seconds to come up, so the microphone file begins
    /// that much after the screen — `cameraStartOffset` in the manifest, which is really the
    /// capture session's offset whichever file the sound landed in. The composition read it as if
    /// file time equalled screen time, so every word was heard seconds *before* it was said and
    /// the tail of the recording lost its sound entirely.
    ///
    /// Here the narration covers the last three seconds of a five-second take: the first two
    /// seconds of the finished video must be silent, and the rest must not.
    func testNarrationIsAlignedToWhenItWasActuallySpoken() async throws {
        let bundle = try makeRecording(seconds: 5)
        // Three seconds of tone, recorded starting two seconds into the screen capture.
        try await writeNarration(to: bundle.microphoneURL, seconds: 3)
        var manifest = try bundle.readManifest()
        manifest.hasMicrophone = true
        manifest.cameraStartOffset = 2
        try bundle.write(manifest)

        let destination = directory.appendingPathComponent("aligned.mp4")
        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 5), events: EventLog(),
            recording: bundle, preset: .web, to: destination, onProgress: { _ in })

        let envelope = try await AudioEnvelope.read(url: destination, samplesPerSecond: 10)
        XCTAssertGreaterThan(envelope.count, 30, "the exported audio is too short to judge")

        // **Indexed by proportion, not by an assumed sample rate.** `AudioEnvelope` derives its
        // slice size from the track's natural time scale, so "ten a second" is a request rather
        // than a promise — an earlier version of this test did the arithmetic itself and read the
        // wrong window, then reported a working fix as broken.
        func loudest(betweenFraction from: Double, and to: Double) -> Float {
            let lower = Int(Double(envelope.count) * from)
            let upper = min(envelope.count, Int(Double(envelope.count) * to))
            guard upper > lower else { return 0 }
            return envelope[lower..<upper].max() ?? 0
        }

        // The narration covers the last three seconds of five, so the first third is before the
        // microphone existed and the last third is well inside it.
        XCTAssertLessThan(loudest(betweenFraction: 0, and: 0.3), 0.02,
                          "there is sound before the microphone was running, so narration is early")
        XCTAssertGreaterThan(loudest(betweenFraction: 0.6, and: 0.95), 0.05,
                             "the narration never arrived")
    }

    /// **Where exactly the narration starts.**
    ///
    /// The looser test above — first third silent, last third loud — passes whether the offset is
    /// applied once or twice, which is no use for the bug it was written for. This one pins the
    /// moment: with a two-second offset the sound must arrive at two seconds, not four.
    func testNarrationStartsExactlyWhereTheOffsetSaysItShould() async throws {
        let bundle = try makeRecording(seconds: 6)
        try await writeNarration(to: bundle.microphoneURL, seconds: 4)
        var manifest = try bundle.readManifest()
        manifest.hasMicrophone = true
        manifest.cameraStartOffset = 2
        try bundle.write(manifest)

        let destination = directory.appendingPathComponent("exact.mp4")
        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 6), events: EventLog(),
            recording: bundle, preset: .web, to: destination, onProgress: { _ in })

        let envelope = try await AudioEnvelope.read(url: destination, samplesPerSecond: 10)
        let asset = AVURLAsset(url: destination)
        let seconds = CMTimeGetSeconds(try await asset.load(.duration))
        XCTAssertGreaterThan(envelope.count, 20)
        XCTAssertGreaterThan(seconds, 1)

        /// The first moment carrying signal, in seconds of the finished video.
        let perSecond = Double(envelope.count) / seconds
        let firstSound = envelope.firstIndex { $0 > 0.02 }
            .map { Double($0) / perSecond }

        XCTAssertEqual(try XCTUnwrap(firstSound), 2, accuracy: 0.5,
                       "the narration does not start where the capture offset says it does")
    }

    /// The loudest sample in a file's audio track, 0…1.
    private static func peak(of url: URL) async throws -> Float {
        let envelope = try await AudioEnvelope.read(url: url, samplesPerSecond: 20)
        return envelope.max() ?? 0
    }

    /// A longer export with sound comes out whole — both tracks, the right length.
    ///
    /// **This does not catch the deadlock it was written for, and that is worth recording.** An
    /// `AVAssetWriter` with two open inputs holds `isReadyForMoreMediaData` down to force
    /// interleaving, so writing every frame and then every audio sample hangs — the video input
    /// waits for audio the loop has not reached. A real twenty-second 3024×1964 export sat at zero
    /// bytes for two minutes; five seconds at 640×480 still fits in the writer's queue and passes
    /// either way. I checked, by putting the old ordering back.
    ///
    /// So the guard against it is structural rather than a test: the audio track is written and
    /// closed before a single frame goes in, and the reason is stated at that line. A fixture large
    /// enough to reproduce it would cost minutes per run, which is a poor trade for a rule that is
    /// visible in the code.
    func testALongerExportWithAudioDoesNotStall() async throws {
        let bundle = try makeRecording(seconds: 5, size: CGSize(width: 640, height: 480))
        try await writeNarration(to: bundle.microphoneURL, seconds: 5)
        var manifest = try bundle.readManifest()
        manifest.hasMicrophone = true
        try bundle.write(manifest)

        let destination = directory.appendingPathComponent("long-with-sound.mp4")
        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 5), events: EventLog(),
            recording: bundle, preset: .web, to: destination, onProgress: { _ in })

        let asset = AVURLAsset(url: destination)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(audio.isEmpty, "no audio track")
        XCTAssertFalse(video.isEmpty, "no video track")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 5, accuracy: 0.5)
    }

    func testProgressReachesTheEnd() async throws {
        let bundle = try makeRecording(seconds: 1)
        let destination = directory.appendingPathComponent("out.mp4")

        let progress = LockedBox()
        try await StudioExporter().export(
            project: try project(over: bundle, seconds: 1), events: EventLog(),
            recording: bundle, preset: .web, to: destination,
            onProgress: { progress.set($0.fraction) })
        XCTAssertEqual(progress.value, 1, accuracy: 0.05)
    }

    /// A cancelled export leaves nothing behind. A half-written file that looks finished is worse
    /// than no file.
    func testACancelledExportLeavesNoFile() async throws {
        let bundle = try makeRecording(seconds: 2)
        let destination = directory.appendingPathComponent("out.mp4")
        let exporter = StudioExporter()

        await exporter.cancel()
        do {
            try await exporter.export(
                project: try project(over: bundle, seconds: 2), events: EventLog(),
                recording: bundle, preset: .web, to: destination, onProgress: { _ in })
            XCTFail("a cancelled export should throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    /// The preset decides the size, and it must never be odd — an odd dimension makes the encoder
    /// pad the frame for nothing.
    func testTheExportedSizeMatchesThePreset() async throws {
        let bundle = try makeRecording(seconds: 1)
        let destination = directory.appendingPathComponent("out.mp4")
        let project = try project(over: bundle, seconds: 1)

        try await StudioExporter().export(
            project: project, events: EventLog(), recording: bundle,
            preset: .web, to: destination, onProgress: { _ in })

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let (canvas, _) = StudioRenderer.layout(for: project)
        XCTAssertEqual(size, ExportPreset.web.outputSize(forCanvas: canvas))
        XCTAssertEqual(Int(size.width) % 2, 0)
        XCTAssertEqual(Int(size.height) % 2, 0)
    }
}

/// A box the export's progress callback can write to from whatever executor it runs on.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double = 0

    func set(_ value: Double) { lock.lock(); stored = value; lock.unlock() }
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
}
