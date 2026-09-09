import AVFoundation
import VideoToolbox
import CoreGraphics
import Foundation
import os

/// Turning a project into a file.
///
/// **Drives the same `StudioRenderer` the preview does.** There is no second code path, which is
/// the only way "the export matches what I saw" can be true rather than aspirational —
/// `AnnotationRenderer` makes the same promise on the screenshot side with the same structure.
actor StudioExporter {

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Studio")

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
        // **The recording's own rate unless the preset insists otherwise.** This used to be
        // `preset.fps` outright and `manifest.fps` was read nowhere, so a 30fps take was exported
        // at 60 with every frame duplicated — twice the bitrate for the same pictures.
        let recordingFPS = (try? recording.readManifest())?.fps ?? 60
        let fps = preset.frameRate(forRecording: recordingFPS)

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
        // Loaded once, before the loop. The store caches, so the canvas and the export share the
        // same decoded pictures rather than each holding their own copy.
        let media = MediaStore.shared.images(for: project, in: recording)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination,
                                       fileType: preset.fileType)
        let input = AVAssetWriterInput(mediaType: .video,
                                       outputSettings: settings(preset: preset, size: output, fps: fps))
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

        // **The soundtrack.** Added before writing starts, because an `AVAssetWriter` will not take
        // a new input once it has. Nil when the recording genuinely has no sound, so a screen-only
        // take does not gain an empty track.
        let audio = await StudioAudio.composition(project: project, recording: recording)
        var audioInput: AVAssetWriterInput?
        log.info("export: audio composition \(audio == nil ? "absent" : "built", privacy: .public)")
        if audio != nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            // **True, and not for the usual reason.** With this false the writer holds
            // `isReadyForMoreMediaData` down on *every* input to force interleaving between them,
            // and since this track is written in one pass rather than alternating with the video,
            // that is a deadlock: the audio waits for video that has not started. True tells the
            // writer not to hold data back for another track's sake.
            track.expectsMediaDataInRealTime = true
            if writer.canAdd(track) {
                writer.add(track)
                audioInput = track
            } else {
                log.error("export: the writer refused an audio input")
            }
        }

        guard writer.startWriting(), reader.startReading() else { throw ExportError.cannotWrite }

        if let cameraReader, !cameraReader.startReading() {
            // Not fatal: a camera that cannot be read costs the picture-in-picture, not the export.
            cameraReaderOutput = nil
        }
        writer.startSession(atSourceTime: .zero)

        // **Written first, and finished before a single frame goes in.** An `AVAssetWriter` with two
        // open inputs will not let either run ahead of the other, so writing every frame and then
        // every sample deadlocks: the video input spins on `isReadyForMoreMediaData` waiting for
        // audio that the loop below has not reached yet. Closing this track first leaves the video
        // pass with nothing to wait for. Found by an export that sat at zero bytes for two minutes.
        if let audioInput, let audio {
            try await writeAudio(audio, to: audioInput)
        }

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
                                                                   wallpaper: wallpaper,
                                                                   media: media),
                                             cache: cache,
                                             clipSource: placed.clip.sourceEnd
                                                 > placed.clip.sourceStart
                                                 ? placed.clip.sourceStart..<placed.clip.sourceEnd
                                                 : nil,
                                             outputTime: outputTime,
                                             cameraStart: cameraStartOffset)
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

    /// Reads the mixed composition and hands its samples to the writer.
    ///
    /// `AVAssetReaderAudioMixOutput` applies the per-clip gain and the time-scaling the composition
    /// describes, so nothing here has to touch PCM — which is the point of building a composition
    /// rather than re-timing samples by hand.
    private func writeAudio(_ audio: (asset: AVAsset, mix: AVAudioMix),
                            to input: AVAssetWriterInput) async throws {

        let tracks = try await audio.asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
            input.markAsFinished()
            return
        }

        let reader = try AVAssetReader(asset: audio.asset)
        // **Asked for in the writer's own format.** Narration is mono and system audio is stereo,
        // and the writer input is configured for stereo at 44.1 kHz — so the conversion is asked of
        // the mix output, which will do it, rather than left to the writer, which will not: a mono
        // buffer appended to a stereo input is simply dropped and the file comes out silent.
        var stereo = AudioChannelLayout()
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layout = withUnsafeBytes(of: stereo) { Data($0) }

        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layout,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.audioMix = audio.mix
        // Every early exit marks the input finished. An `AVAssetWriter` will not finish while an
        // input it was given is still open, so a silent bail here would hang the export rather
        // than merely lose the sound.
        guard reader.canAdd(output) else {
            log.error("export audio: the reader refused a mix output")
            input.markAsFinished()
            return
        }
        reader.add(output)
        guard reader.startReading() else {
            let why = reader.error.map { String(describing: $0) } ?? "no error given"
            log.error("export audio: the reader would not start — \(why, privacy: .public)")
            input.markAsFinished()
            return
        }

        var appended = 0
        while let sample = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            if input.append(sample) { appended += 1 }
        }
        input.markAsFinished()
        // **Said out loud, because silence is this feature's failure mode.** Every export shipped
        // without sound until now, and it did so quietly; an audio pass that reads nothing should
        // never again be indistinguishable from one that worked.
        if appended == 0 {
            let why = reader.error.map { String(describing: $0) } ?? "the reader simply ended"
            log.error("export audio: nothing was written — \(why, privacy: .public)")
        } else {
            log.info("export audio: \(appended, privacy: .public) buffers written")
        }
        reader.cancelReading()
    }

    private func settings(preset: ExportPreset, size: CGSize, fps: Int) -> [String: Any] {
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
                AVVideoAverageBitRateKey: ExportPreset.videoBitrate(size: size, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
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
