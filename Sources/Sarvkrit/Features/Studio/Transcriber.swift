import AVFoundation
import Foundation
import Speech
import os

/// Turning the narration into captions, on this Mac and nowhere else.
///
/// **`requiresOnDeviceRecognition = true`, and when the device cannot do it the feature says so
/// and offers nothing.** The README's promise is that the app contains no network code at all, and
/// a caption feature that quietly posts somebody's audio to Apple when the local model is missing
/// would break it in the least visible way possible.
///
/// The reference product bundles Whisper locally and gets better transcripts, particularly on
/// technical vocabulary. It is equally private; the argument against is size — a Core ML Whisper
/// model adds hundreds of megabytes to an app whose whole DMG is a few. That trade is written up
/// in the design doc as an explicit later decision rather than left as a silent limitation, and
/// `contextualStrings` below closes a good part of the gap for free.
enum Transcriber {

    enum TranscriptionError: Error, Equatable {
        /// The local model for this language is not installed, and we will not fall back.
        case onDeviceUnavailable(locale: String)
        case notAuthorised
        case noAudio
        case failed(String)
    }

    /// Locales this Mac can actually run offline.
    ///
    /// Filtered rather than listed: showing a language we cannot run locally would be a promise
    /// broken at the last moment, after the user has waited.
    static func availableLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .filter { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            .sorted { ($0.identifier) < ($1.identifier) }
    }

    static func requestAuthorisation() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// - Parameter vocabulary: words to bias recognition towards — product names, library names,
    ///   jargon. This is the difference between a transcript that says "Sarvkrit" and one that
    ///   says "sav credit", and it costs three lines.
    static func transcribe(url: URL,
                           locale: Locale = .current,
                           vocabulary: [String] = []) async throws -> [Caption] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudio
        }
        guard await requestAuthorisation() else { throw TranscriptionError.notAuthorised }

        guard let recogniser = SFSpeechRecognizer(locale: locale),
              recogniser.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceUnavailable(locale: locale.identifier)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.contextualStrings = vocabulary

        let transcription: SFTranscription = try await withCheckedThrowingContinuation { done in
            var finished = false
            recogniser.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    return done.resume(throwing:
                        TranscriptionError.failed(error.localizedDescription))
                }
                guard let result, result.isFinal else { return }
                finished = true
                done.resume(returning: result.bestTranscription)
            }
        }

        // Per-word `timestamp` and `duration` are the whole reason karaoke highlighting is
        // possible; they are not something the app could work out for itself.
        let words = transcription.segments.map {
            TranscriptWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
        }
        return CaptionGrouper.lines(from: words)
    }

    /// Writes the transcript out beside the video.
    ///
    /// Cheap, and it is what makes a recording accessible somewhere other than the file we made.
    static func subtitles(_ captions: [Caption], format: SubtitleFormat) -> String {
        switch format {
        case .srt:
            return captions.enumerated().map { index, caption in
                "\(index + 1)\n\(srtTime(caption.start)) --> \(srtTime(caption.end))\n"
                    + "\(caption.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            let body = captions.map {
                "\(vttTime($0.start)) --> \(vttTime($0.end))\n\($0.text)\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + body
        }
    }

    enum SubtitleFormat: String, CaseIterable { case srt, vtt }

    private static func srtTime(_ seconds: TimeInterval) -> String {
        clock(seconds, millisecondSeparator: ",")
    }

    private static func vttTime(_ seconds: TimeInterval) -> String {
        clock(seconds, millisecondSeparator: ".")
    }

    private static func clock(_ seconds: TimeInterval, millisecondSeparator: String) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = Int(total) % 60
        let millis = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d\(millisecondSeparator)%03d",
                      hours, minutes, secs, millis)
    }
}
