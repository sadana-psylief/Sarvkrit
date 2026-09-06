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
    private func makeRecording(seconds: Double) throws -> RecordingBundle {
        let bundle = try RecordingBundle.create(at: directory.appendingPathComponent("r.sarvrec"))
        let size = CGSize(width: 160, height: 120)
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
