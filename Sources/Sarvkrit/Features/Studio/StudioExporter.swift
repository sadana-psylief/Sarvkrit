import AVFoundation
import VideoToolbox
import CoreGraphics
import Foundation

/// Turning a project into a file.
///
/// **Drives the same `StudioRenderer` the preview does.** There is no second code path, which is
/// the only way "the export matches what I saw" can be true rather than aspirational —
/// `AnnotationRenderer` makes the same promise on the screenshot side with the same structure.
actor StudioExporter {

    struct Progress: Equatable {
        var completed: Int
        var total: Int
        var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    }

    enum ExportError: Error, Equatable {
        case cannotRead
        case cannotWrite
        case cancelled
    }

    private var isCancelled = false

    /// **One exporter, one export.** `export` used to clear this flag on entry, which quietly
    /// dropped any Cancel that arrived while the asset was being read and the writer built — a
    /// window of real duration, and exactly when somebody who mis-clicked Export would press it.
    /// The caller makes a fresh exporter per run instead, so there is no flag to reset and no race
    /// to lose.
    func cancel() { isCancelled = true }

    /// - Parameter onProgress: called on an arbitrary executor; hop to the main actor to show it.
    func export(project: StudioProject,
                events: EventLog,
                recording: RecordingBundle,
                preset: ExportPreset,
                to destination: URL,
                onProgress: @Sendable @escaping (Progress) -> Void) async throws {
        guard !isCancelled else { throw ExportError.cancelled }

        let asset = AVURLAsset(url: recording.screenURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.cannotRead
        }

        let (canvas, _) = StudioRenderer.layout(for: project)
        let output = preset.outputSize(forCanvas: canvas)
        let fps = preset.fps

        // Sequential, so a reader is exactly the right tool here — unlike the preview, which has to
        // seek and therefore cannot use one.
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // **The camera, read the same way.** Forward-only, pulled along to the moment each output
        // frame needs — exactly as the screen is. Until now the exporter never opened this file at
        // all, so a recording with a camera exported without one and nothing said why.
        var cameraReaderOutput: AVAssetReaderTrackOutput?
        var cameraReader: AVAssetReader?
        var cameraStartOffset: TimeInterval = 0
        var cameraDuration: TimeInterval = 0
        var decodedCamera: CGImage?
        var cameraDecodedUntil: TimeInterval = -1

        if let manifest = try? recording.readManifest(), manifest.hasCamera,
           FileManager.default.fileExists(atPath: recording.cameraURL.path) {
            let cameraAsset = AVURLAsset(url: recording.cameraURL)
            if let cameraTrack = try? await cameraAsset.loadTracks(withMediaType: .video).first {
                cameraStartOffset = manifest.cameraStartOffset
                cameraDuration = ((try? await cameraAsset.load(.duration))?.seconds).map {
                    $0.isFinite ? $0 : 0
                } ?? 0
                let reader = try AVAssetReader(asset: cameraAsset)
                let trackOutput = AVAssetReaderTrackOutput(
                    track: cameraTrack,
                    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                        kCVPixelFormatType_32BGRA])
                trackOutput.alwaysCopiesSampleData = false
                reader.add(trackOutput)
                cameraReader = reader
                cameraReaderOutput = trackOutput
            }
        }

        // Resolved once, on the main actor, and by the same helper the live canvas uses — the two
        // disagreeing about a background is a failure this app has already had.
        let wallpaper = await MainActor.run { FrameSources.wallpaper(for: project) }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination,
                                       fileType: preset.codec == .proRes422 ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: settings(preset: preset, size: output))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(output.width),
                kCVPixelBufferHeightKey as String: Int(output.height),
            ])
        guard writer.canAdd(input) else { throw ExportError.cannotWrite }
        writer.add(input)

        guard writer.startWriting(), reader.startReading() else { throw ExportError.cannotWrite }
        if let cameraReader, !cameraReader.startReading() {
            // Not fatal: a camera that cannot be read costs the picture-in-picture, not the export.
            cameraReaderOutput = nil
        }
        writer.startSession(atSourceTime: .zero)

        let duration = project.duration
        let total = max(1, Int(duration * Double(fps)))
        let cache = StudioRenderer.Cache()
        var decoded: CGImage?
        var decodedUntil: TimeInterval = -1

        for index in 0..<total {
            if isCancelled {
                reader.cancelReading()
                input.markAsFinished()
                await writer.finishWriting()
                // A cancelled export leaves nothing behind. A half-written file that looks finished
                // is worse than no file.
                try? FileManager.default.removeItem(at: destination)
                throw ExportError.cancelled
            }

            let outputTime = Double(index) / Double(fps)
            guard let placed = project.timeline.sourceTime(forOutput: outputTime) else { break }

            // The reader hands frames back in order, so it is pulled forward until it reaches the
            // source moment this output frame needs. A speed-up consumes several; a slow-down
            // reuses one.
            while decodedUntil < placed.sourceTime,
                  let sample = readerOutput.copyNextSampleBuffer() {
                decodedUntil = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    decoded = Self.image(from: buffer)
                }
            }

            if let cameraReaderOutput {
                // Nil outside the camera's own span — it starts after the screen and can stop
                // before it — and the renderer draws nothing for a nil image.
                if let wanted = PlaybackClock.cameraTime(forSource: placed.sourceTime,
                                                         startOffset: cameraStartOffset,
                                                         cameraDuration: cameraDuration) {
                    while cameraDecodedUntil < wanted,
                          let sample = cameraReaderOutput.copyNextSampleBuffer() {
                        cameraDecodedUntil = CMTimeGetSeconds(
                            CMSampleBufferGetPresentationTimeStamp(sample))
                        if let buffer = CMSampleBufferGetImageBuffer(sample) {
                            decodedCamera = Self.image(from: buffer)
                        }
                    }
                } else {
                    decodedCamera = nil
                }
            }

            let frame = StudioRenderer.frame(of: project, atSource: placed.sourceTime,
                                             events: events,
                                             sources: FrameSources(screen: decoded,
                                                                   camera: decodedCamera,
                                                                   wallpaper: wallpaper),
                                             cache: cache)
            guard let frame, let buffer = Self.buffer(from: frame, size: output,
                                                      pool: adaptor.pixelBufferPool) else {
                continue
            }

            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            adaptor.append(buffer,
                           withPresentationTime: CMTime(value: CMTimeValue(index),
                                                        timescale: CMTimeScale(fps)))
            onProgress(Progress(completed: index + 1, total: total))
        }

        input.markAsFinished()
        await writer.finishWriting()
        reader.cancelReading()
        guard writer.status == .completed else { throw ExportError.cannotWrite }
    }

    private func settings(preset: ExportPreset, size: CGSize) -> [String: Any] {
        var codec: AVVideoCodecType
        switch preset.codec {
        case .h264: codec = .h264
        case .hevc: codec = .hevc
        case .proRes422: codec = .proRes422
        case .gif: codec = .h264
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        if preset.codec == .h264 || preset.codec == .hevc {
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(size.width * size.height) * 8,
                AVVideoExpectedSourceFrameRateKey: preset.fps,
            ]
        }
        return settings
    }

    private static func image(from buffer: CVPixelBuffer) -> CGImage? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    private static func buffer(from image: CGImage, size: CGSize,
                               pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                                &buffer)
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
