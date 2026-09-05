import AVFoundation
import Foundation

/// What the user chose before pressing Record.
///
/// **Remembered between launches on purpose.** The costliest failure this feature has is finishing
/// a ten-minute take and discovering the camera was off, or the microphone was the wrong one. The
/// pre-record bar's live preview is the main defence; remembering last time's choice is the rest,
/// because the setting somebody deliberately chose yesterday is almost always the one they want
/// today.
///
/// Hand-rolled over an injected `UserDefaults` with a same-value guard, like every other settings
/// object in the app — never `@Published`, for the reason `AppState` records at length.
final class RecordingSetup: ObservableObject {

    /// Long enough to reach the window you are about to demonstrate, and short enough that nobody
    /// has to think about which to pick.
    static let countdownChoices = [0, 3, 5, 10]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var source: RecordingSource {
        get {
            (defaults.string(forKey: "recording.source")
                .flatMap(RecordingSource.init(rawValue:))) ?? .display
        }
        set {
            guard newValue != source else { return }
            defaults.set(newValue.rawValue, forKey: "recording.source")
            objectWillChange.send()
        }
    }

    /// Nil means no camera. **Nothing is switched on for you** — a recorder that films somebody by
    /// default is a recorder that has filmed them without their deciding to be filmed.
    var cameraID: String? {
        get { defaults.string(forKey: "recording.camera") }
        set {
            guard newValue != cameraID else { return }
            defaults.set(newValue, forKey: "recording.camera")
            objectWillChange.send()
        }
    }

    var microphoneID: String? {
        get { defaults.string(forKey: "recording.microphone") }
        set {
            guard newValue != microphoneID else { return }
            defaults.set(newValue, forKey: "recording.microphone")
            objectWillChange.send()
        }
    }

    var capturesSystemAudio: Bool {
        get { defaults.object(forKey: "recording.systemAudio") as? Bool ?? false }
        set {
            guard newValue != capturesSystemAudio else { return }
            defaults.set(newValue, forKey: "recording.systemAudio")
            objectWillChange.send()
        }
    }

    var countdownSeconds: Int {
        get {
            let stored = defaults.object(forKey: "recording.countdown") as? Int ?? 0
            // A value this build does not offer falls back rather than showing a countdown nobody
            // chose — the same forward-compatibility rule the documents follow.
            return Self.countdownChoices.contains(stored) ? stored : 0
        }
        set {
            guard newValue != countdownSeconds else { return }
            defaults.set(newValue, forKey: "recording.countdown")
            objectWillChange.send()
        }
    }

    /// Forgets devices that are no longer attached.
    ///
    /// Without this the bar offers a camera that was unplugged last week, and Record produces a
    /// recording with no camera track and no explanation.
    func reconcile(cameraIDs: [String], microphoneIDs: [String]) {
        if let cameraID, !cameraIDs.contains(cameraID) { self.cameraID = nil }
        if let microphoneID, !microphoneIDs.contains(microphoneID) { self.microphoneID = nil }
    }

    func request(fps: Int, hidesDesktopIcons: Bool, destination: URL) -> RecordingRequest {
        var request = RecordingRequest(source: source, destination: destination)
        request.fps = fps
        request.capturesSystemAudio = capturesSystemAudio
        request.hidesDesktopIcons = hidesDesktopIcons
        return request
    }
}
