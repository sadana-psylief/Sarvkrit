import Foundation
import SwiftUI
import os

/// Recording the screen, and editing it afterwards.
final class ScreenRecordingFeature: Feature, ObservableObject {
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Recording")

    let id = "screen-recording"
    let category = FeatureCategory.capture
    let title = "Screen Recording"
    let summary = "Record your screen; it edits itself"
    let details = """
        Records your screen — an area, a window, or the whole display — and captures what the \
        mouse and keyboard did alongside it.

        The pointer is not recorded into the video. Its path is logged instead and drawn back in \
        afterwards, which is why it can be resized, smoothed and kept sharp when the frame is \
        zoomed, and why none of those are decisions you have to get right while recording.
        """
    let symbolName = "record.circle"
    var shortcutHint: String? { "⌃⇧R" }

    /// **Screen Recording only.** Not Accessibility: the base recorder watches clicks through a
    /// global monitor, which needs no grant, and `FeatureCategoryTests` asserts that only
    /// `EventTapFeature`s declare it. Keystroke capture asks for Accessibility at the point of use.
    let requirements: Set<Requirement> = [.screenRecording]

    let recorder: SCKScreenRecordingService
    /// What the pre-record bar last had chosen. Shared with it rather than copied.
    let setup: RecordingSetup
    private let defaults: UserDefaults
    private var hotkeys: [GlobalHotkey] = []

    /// Set by `AppDelegate`. Nothing under `Features/` imports the UI layer.
    var startStop: (() -> Void)?
    var recordArea: (() -> Void)?
    var pauseResume: (() -> Void)?
    var markMoment: (() -> Void)?

    @Published private(set) var isRecording = false
    @Published private(set) var failedRegistrations: Set<RecordingAction> = []

    init(recorder: SCKScreenRecordingService = SCKScreenRecordingService(),
         defaults: UserDefaults = .standard) {
        self.recorder = recorder
        self.defaults = defaults
        self.setup = RecordingSetup(defaults: defaults)
    }

    // MARK: - Settings

    /// Hand-rolled over an injected `UserDefaults`, with a same-value guard in the setter. Never
    /// `@Published`: a same-value write through a SwiftUI binding once became notify → invalidate
    /// → write back → notify, and pinned a core until the app was killed. See `AppState`.
    var framesPerSecond: Int {
        get { defaults.object(forKey: "recording.fps") as? Int ?? 60 }
        set {
            guard newValue != framesPerSecond else { return }
            defaults.set(newValue, forKey: "recording.fps")
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

    var hidesDesktopIcons: Bool {
        get { defaults.object(forKey: "recording.hidesDesktopIcons") as? Bool ?? true }
        set {
            guard newValue != hidesDesktopIcons else { return }
            defaults.set(newValue, forKey: "recording.hidesDesktopIcons")
            objectWillChange.send()
        }
    }

    /// Off until asked, like Snap Areas. Watching the keyboard is exactly the thing a
    /// privacy-minded person wants to opt into rather than discover, and it needs Accessibility.
    var showsKeystrokes: Bool {
        get { defaults.object(forKey: "recording.keystrokes") as? Bool ?? false }
        set {
            guard newValue != showsKeystrokes else { return }
            defaults.set(newValue, forKey: "recording.keystrokes")
            MainActor.assumeIsolated { recorder.recordsKeystrokes = newValue }
            objectWillChange.send()
        }
    }

    // MARK: - Lifecycle

    func activate() {
        MainActor.assumeIsolated {
            recorder.recordsKeystrokes = showsKeystrokes
            rebindHotkeys()
        }
    }

    func deactivate() {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
    }

    @MainActor
    func noteRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
    }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(ScreenRecordingDetailView(feature: self))
    }

    /// Registered again after a rebind, because Carbon hot keys are registered rather than matched
    /// — there is no table to update, only a registration to replace.
    @MainActor
    func rebindHotkeys() {
        hotkeys.forEach { $0.unregister() }
        hotkeys = []
        failedRegistrations = []

        for action in RecordingAction.allCases {
            guard let handler = handler(for: action) else { continue }
            let shortcut = action.defaultShortcut
            let hotkey = GlobalHotkey(id: action.hotkeyID)
            let status = hotkey.register(keyCode: UInt32(shortcut.keyCode),
                                         // Carbon masks, not CGEventFlags. Handing over the wrong
                                         // one compiles and registers a different combination.
                                         modifiers: CarbonModifiers.from(shortcut.flags)) {
                MainActor.assumeIsolated { handler() }
            }
            if status == noErr {
                hotkeys.append(hotkey)
                // The successes are logged too, not only the refusals, matching `ScreenshotFeature`
                // — "did this combination actually get claimed on this Mac" is otherwise
                // unanswerable without a debugger, and when these shortcuts went missing the launch
                // log could not say so.
                log.info("registered \(action.rawValue, privacy: .public) keyCode \(shortcut.keyCode, privacy: .public)")
            } else {
                // Another app holding a combination is ordinary. Recorded so settings can say so,
                // rather than offering a shortcut that quietly does nothing.
                failedRegistrations.insert(action)
                log.error("couldn't register \(action.rawValue, privacy: .public): \(status, privacy: .public)")
            }
        }
        objectWillChange.send()
    }

    /// Internal rather than private so `ScreenRecordingHotkeyBindingTests` can pin the late
    /// binding this returns — the launch-order bug it documents had no other observable surface.
    func handler(for action: RecordingAction) -> (() -> Void)? {
        // **Read at fire time, not here.** `rebindHotkeys()` runs from `AppState.sync()`, which
        // happens during `AppState.shared`'s initialiser — four lines before `wireRecording()`
        // assigns any of these. Returning the stored closure meant returning nil four times, and
        // `guard let handler … else { continue }` then registered nothing at all. Worse, it never
        // recovered: `sync()` skips features already in `activeFeatureIDs`, so the only cure was
        // toggling the feature off and on. `ScreenshotFeature` has done it this way all along.
        switch action {
        case .startStop: return { [weak self] in self?.startStop?() }
        case .recordArea: return { [weak self] in self?.recordArea?() }
        case .pauseResume: return { [weak self] in self?.pauseResume?() }
        case .flag: return { [weak self] in self?.markMoment?() }
        }
    }
}
