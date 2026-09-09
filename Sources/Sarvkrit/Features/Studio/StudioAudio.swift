import AVFoundation
import Foundation
import os

/// The edited soundtrack, as something the exporter can read.
///
/// **Every export was silent.** `StudioExporter` wrote a single video input and read only the
/// screen's video track — while the recorder captured narration, the manifest recorded
/// `hasMicrophone` and `hasSystemAudio`, and every `Clip` carried `volume`, `systemAudioVolume` and
/// `isMuted`. All of those controls were editing a track that never reached a file.
///
/// **Built as an `AVComposition` rather than by hand.** The hard parts here are time-scaling a
/// speed-changed clip and mixing two sources with per-clip gain, and AVFoundation already does both
/// correctly. Re-timing PCM by hand would mean owning a resampler, and getting that subtly wrong
/// sounds like a broken app rather than an off-by-one.
enum StudioAudio {

    private static let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Studio")

    /// The narration and system tracks a bundle actually has.
    ///
    /// Narration lands in `camera.mov` when a camera was recording — one `AVCaptureSession` with
    /// both inputs writes one file — and in `mic.m4a` when it was the microphone alone. Rather than
    /// infer that from the manifest, both are asked whether they have an audio track.
    static func narrationURL(in recording: RecordingBundle) async -> URL? {
        for url in [recording.microphoneURL, recording.cameraURL] where
            FileManager.default.fileExists(atPath: url.path) {
            let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            if tracks?.isEmpty == false { return url }
        }
        return nil
    }

    /// System audio rides in `screen.mov` alongside the picture — one writer, one fragment
    /// interval, and a raw recording that plays with sound.
    static func systemAudioURL(in recording: RecordingBundle) async -> URL? {
        for url in [recording.screenURL, recording.systemAudioURL] where
            FileManager.default.fileExists(atPath: url.path) {
            let tracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
            if tracks?.isEmpty == false { return url }
        }
        return nil
    }

    /// The project's audio, cut and gain-staged to match the timeline.
    ///
    /// Nil when the recording has no sound at all, which is an ordinary answer — a screen-only take
    /// should not gain an empty audio track.
    static func composition(project: StudioProject,
                            recording: RecordingBundle) async -> (asset: AVAsset,
                                                                  mix: AVAudioMix)? {
        let narration = await narrationURL(in: recording)
        let system = await systemAudioURL(in: recording)
        guard narration != nil || system != nil else { return nil }

        let composition = AVMutableComposition()
        var parameters: [AVMutableAudioMixInputParameters] = []
        // **The assets are held, not just their tracks.** `AVAssetTrack.asset` is a weak reference,
        // so building one inline and keeping only the track lets the asset go — and then
        // `insertTimeRange` fails with `-12780` and the export comes out silent, which is exactly
        // the bug this file exists to fix.
        var retained: [AVURLAsset] = []

        for source in [(narration, false), (system, true)] {
            guard let url = source.0 else { continue }
            let asset = AVURLAsset(url: url)
            retained.append(asset)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }

            let gain = AVMutableAudioMixInputParameters(track: track)
            // A tape-style pitch shift on a sped-up clip is what a speed change is expected to
            // sound like; the alternative is owning a time-stretcher.
            gain.audioTimePitchAlgorithm = .varispeed

            var cursor = CMTime.zero
            for clip in project.timeline.clips {
                let range = CMTimeRange(
                    start: CMTime(seconds: clip.sourceStart, preferredTimescale: 600),
                    duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600))
                guard range.duration.seconds > 0 else { continue }

                do {
                    try track.insertTimeRange(range, of: sourceTrack, at: cursor)
                } catch {
                    // A clip whose source range runs past the end of the audio is ordinary: the
                    // microphone can stop before the screen does. Silence is the right answer —
                    // but it is logged, because "the export is silent" was the bug this whole
                    // file exists to fix and a swallowed insert would recreate it exactly.
                    let why = String(describing: error)
                    log.error("audio: could not insert a clip's range: \(why, privacy: .public)")
                    cursor = cursor + CMTime(seconds: clip.outputDuration, preferredTimescale: 600)
                    continue
                }

                let inserted = CMTimeRange(start: cursor, duration: range.duration)
                if clip.speed != 1 {
                    track.scaleTimeRange(inserted,
                                         toDuration: CMTime(seconds: clip.outputDuration,
                                                            preferredTimescale: 600))
                }

                // Set at the clip's own start, so each clip's gain holds until the next changes it.
                let level = clip.isMuted ? 0 : (source.1 ? clip.systemAudioVolume : clip.volume)
                gain.setVolume(Float(max(0, min(1, level))), at: cursor)
                cursor = cursor + CMTime(seconds: clip.outputDuration, preferredTimescale: 600)
            }
            parameters.append(gain)
        }

        // An `AVMutableCompositionTrack` exists the moment it is added, empty or not, so the
        // presence of a track says nothing. Duration is what says whether anything went in.
        guard composition.duration.seconds > 0 else {
            log.error("audio: the composition came out empty, so the export would be silent")
            return nil
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        _ = retained
        return (composition, mix)
    }
}
