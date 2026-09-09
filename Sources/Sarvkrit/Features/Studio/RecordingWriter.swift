import AVFoundation
import CoreMedia
import Foundation

/// Everything the sample-buffer callback touches.
///
/// **Deliberately not main-actor, and that is the whole point of this type existing.** `SCStream`
/// delivers frames on its own serial queue. The first version of the recorder wrapped the handler
/// in `MainActor.assumeIsolated` — which is an *assertion*, not a hop — so the first frame of the
/// first recording trapped with `EXC_BREAKPOINT` and recording looked impossible to switch on.
///
/// Hopping to the main actor per frame would have been the wrong fix as well as a slow one: at 60
/// fps that is sixty context switches a second to call one `append`. So the writing state lives
/// here, is mutated only from the stream's own queue, and is guarded by a lock for the two
/// counters the HUD reads while frames are still arriving.
final class RecordingWriter: @unchecked Sendable {

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    /// System audio, when the recording asked for it.
    ///
    /// **In the same file as the picture, deliberately.** One writer means one fragment interval
    /// and therefore the same crash survivability for both tracks, and it makes the raw recording
    /// directly playable with sound rather than something only this app can assemble.
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()

    /// The presentation time of the first frame. Everything is measured from it, so the events and
    /// the picture cannot drift apart.
    private var firstFrame: CMTime?
    private var lastFrame: CMTime = .zero
    /// Accumulated across pauses, so elapsed means *recorded* time.
    private var pausedFor: CMTime = .zero
    private var pausedAt: CMTime?
    private var paused = false
    private var dropped = 0

    /// `systemUptime` at the instant the first frame landed.
    ///
    /// The event log is rebased against this rather than against a time taken when capture was
    /// asked for: the gap between `startCapture()` returning and the first frame arriving is tens
    /// of milliseconds, and that is enough to put the cursor visibly behind what it clicked.
    private var anchorHostTime: TimeInterval?

    /// - Parameter capturesAudio: whether to make room for system audio. `SCStream` will not
    ///   deliver any unless an `.audio` output is added, which is why this was silently absent:
    ///   `capturesAudio` was set on the configuration and nothing ever asked for the buffers.
    init(url: URL, size: CGSize, fps: Int, capturesAudio: Bool = false) throws {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw RecordingError.cannotWrite
        }
        // **Fragments are what make a crash survivable.** The writer flushes a self-contained
        // fragment every two seconds, so a file whose `finishWriting` never ran is still playable
        // up to the last one rather than a header-less block nothing can open.
        writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.9,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.cannotWrite }
        writer.add(input)
        var audio: AVAssetWriterInput?
        if capturesAudio {
            let track = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            track.expectsMediaDataInRealTime = true
            if writer.canAdd(track) {
                writer.add(track)
                audio = track
            }
        }

        guard writer.startWriting() else { throw RecordingError.cannotWrite }

        self.writer = writer
        self.input = input
        self.audioInput = audio
    }

    // MARK: - Reading, from anywhere

    var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let firstFrame else { return 0 }
        return CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(lastFrame, firstFrame), pausedFor))
    }

    var droppedFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return dropped
    }

    var firstFrameHostTime: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return anchorHostTime
    }

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    // MARK: - Writing, from the stream queue only

    /// System audio, from `SCStream`'s own queue.
    ///
    /// **Dropped until the first video frame has landed.** The session is anchored on that frame,
    /// so audio arriving before it has no timeline to sit on — and appending it would either fail
    /// or, worse, shift the whole soundtrack earlier than the picture.
    func appendAudio(_ buffer: CMSampleBuffer?) {
        guard let buffer, buffer.isValid, let audioInput else { return }
        lock.lock()
        let started = firstFrame != nil
        let isPaused = paused
        lock.unlock()

        guard started, !isPaused, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(buffer)
    }

    func append(_ buffer: CMSampleBuffer?) {
        guard let buffer, buffer.isValid else { return }

        lock.lock()
        if firstFrame == nil {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
            firstFrame = timestamp
            anchorHostTime = ProcessInfo.processInfo.systemUptime
            lock.unlock()
            writer.startSession(atSourceTime: timestamp)
            lock.lock()
        }
        let isPaused = paused
        lastFrame = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.unlock()

        guard !isPaused else { return }
        guard input.isReadyForMoreMediaData else {
            // Dropped at the tail rather than blocking the stream, counted, and reported when the
            // recording stops. Producing a stuttering file in silence is the failure to avoid.
            countDrop()
            return
        }
        if !input.append(buffer) { countDrop() }
    }

    private func countDrop() {
        lock.lock(); dropped += 1; lock.unlock()
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        guard !paused else { return }
        paused = true
        pausedAt = lastFrame
    }

    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard paused, let pausedAt else { return }
        paused = false
        // Rebased rather than left as a gap: a gap means every downstream time — zoom segments,
        // captions, the timeline — would have to know about it, and none of them should.
        pausedFor = CMTimeAdd(pausedFor, CMTimeSubtract(lastFrame, pausedAt))
        self.pausedAt = nil
    }

    func finish() async {
        input.markAsFinished()
        // The writer will not finish while an input it was given is still open.
        audioInput?.markAsFinished()
        await writer.finishWriting()
    }
}
