import CoreGraphics
import Foundation

/// The `sarvkrit://` URL scheme: every capture mode, reachable from a script.
///
/// This is the seam Raycast, Alfred, Shortcuts, a Stream Deck key or a shell script hang off, and
/// the reference app has had one for years — a capture tool that can only be started by a
/// keystroke is a capture tool nothing else can automate.
///
/// Command names follow the reference's where they overlap, so anything already written against
/// `cleanshot://capture-area` needs only its scheme changed. Two are ours: `hide-overlays`, and
/// `cancel`, which is the scriptable form of the ⌃⇧⎋ escape hatch. `pin` is the one that is not a
/// drop-in — the reference's takes a `filepath`, ours pins whatever image is on the clipboard.
///
/// **Parsing is pure and total.** An unknown command returns nil rather than throwing or
/// defaulting to something — a typo in a script must do nothing, not silently take a screenshot.
enum CaptureURLCommand: Equatable {
    case action(ScreenshotAction)
    /// `capture-area` with all four coordinates: take this rect now, no overlay.
    ///
    /// **Points from the lower-left corner of the chosen screen**, which is the reference's
    /// convention and therefore the one scripts are already written in. Note *screen*, not the
    /// global desktop: the two are the same thing on the main display and differ on every other,
    /// and picking the global reading would silently capture the wrong monitor.
    ///
    /// `displayIndex` is 1 for the main display, 2 for the next, matching the reference — a
    /// script author has no way to learn a `CGDirectDisplayID`. Nil means the display the pointer
    /// is on.
    case captureRect(CGRect, displayIndex: Int?)
    /// Puts every overlay, panel, countdown and pinned window away. See `CaptureOverlayGuard`.
    case cancel
    /// Reopens the overlay on the last area that was captured, ready to retake or adjust.
    case capturePreviousArea
    /// Opens an image in the annotation editor. Nil means the most recent capture, which is the
    /// thing anybody binding this to a key actually wants — "annotate the one I just took".
    case openAnnotate(URL?)
    /// Opens whatever image is on the clipboard in the editor.
    case openFromClipboard
    /// Sarvkrit's own window, on the Capture pane.
    /// Opens the settings window, optionally on a named pane — a feature's own id, `general` or
    /// `about`. Without one it lands wherever the window was last left.
    case openSettings(pane: String?)
    /// Starts a recording, skipping the pre-record bar — camera, microphone and countdown are
    /// whatever the settings already say.
    ///
    /// **The window selector is the point.** Recording a *window* is the case that has been
    /// hardest to diagnose, and without a way to name one from a script it can only be reached by
    /// hand. Nil with `.window` means the frontmost window that is not one of ours.
    case record(RecordingSource, windowID: CGWindowID?)
    /// Stops the recording in progress and opens it in the editor.
    case stopRecording
    /// Moves the open editor's playhead, in seconds.
    ///
    /// **The scriptable form of dragging the scrubber**, which is otherwise unreachable without a
    /// mouse — and therefore untestable on a machine that refuses synthetic input.
    case seek(TimeInterval)
    /// Starts or stops playback in the open editor.
    case playPause
    /// Exports the open editor to a file, skipping the save panel.
    case exportEditor(URL)
    /// Performs one of the editor's own actions by name — the same ones the keyboard routes.
    case editorCommand(StudioEditorCommand)
    /// Brings a picture into the open editor at the playhead.
    case addPicture(URL)
    /// Raises the pre-record bar, as ⌃⇧R does.
    ///
    /// **The bar and the aiming overlay are the two surfaces a script could not reach**, and both
    /// have now been reported against — "I cannot close it until I record something" and "it
    /// should be a rectangle already on screen". `record` deliberately skips both, so neither
    /// could be looked at without a keyboard this machine will not let anything synthesise.
    case showRecordBar
    /// Raises the aiming surface for whatever source is currently chosen: the area overlay, the
    /// window list, or straight to the countdown for a whole display.
    case aimRecording

    static let scheme = "sarvkrit"

    /// The command name as it appears in a URL, for the settings pane to list.
    var name: String {
        switch self {
        case .cancel: return "cancel"
        case .capturePreviousArea: return "capture-previous-area"
        case .openAnnotate: return "open-annotate"
        case .openFromClipboard: return "open-from-clipboard"
        case .openSettings: return "open-settings"
        case .captureRect: return "capture-area"
        case .record: return "record"
        case .stopRecording: return "stop-recording"
        case .seek: return "seek"
        case .playPause: return "play"
        case .exportEditor: return "export"
        case .editorCommand: return "editor"
        case .addPicture: return "picture"
        case .showRecordBar: return "record-bar"
        case .aimRecording: return "aim"
        case .action(let action): return Self.names[action] ?? action.rawValue
        }
    }

    private static let names: [ScreenshotAction: String] = [
        .area: "capture-area",
        .window: "capture-window",
        .fullscreen: "capture-fullscreen",
        .allInOne: "all-in-one",
        .scrolling: "scrolling-capture",
        .textRecognition: "capture-text",
        .history: "open-history",
        .restoreOverlay: "restore-recently-closed",
        .pinClipboard: "pin",
        .hideOverlays: "hide-overlays",
    ]

    /// Every command, for documentation and for the test that proves none is unreachable.
    ///
    /// `captureRect` is not listed: it is `capture-area` with parameters, not a separate command,
    /// and a settings row offering a URL with somebody else's coordinates in it would be noise.
    static var all: [CaptureURLCommand] {
        ScreenshotAction.allCases.map { .action($0) }
            + [.capturePreviousArea, .openAnnotate(nil), .openFromClipboard, .openSettings(pane: nil),
               .cancel, .record(.display, windowID: nil), .stopRecording, .seek(0), .playPause,
               .exportEditor(URL(fileURLWithPath: "/tmp/Recording.mp4")),
               .editorCommand(.split), .addPicture(URL(fileURLWithPath: "/tmp/logo.png")),
               .showRecordBar, .aimRecording]
    }

    private static func rect(from url: URL) -> CGRect? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func number(_ name: String) -> CGFloat? {
            guard let raw = items.first(where: { $0.name.lowercased() == name })?.value,
                  let value = Double(raw) else { return nil }
            return CGFloat(value)
        }
        guard let x = number("x"), let y = number("y"),
              let width = number("width"), let height = number("height"),
              width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// A `filepath` parameter, as a file URL.
    ///
    /// Accepts a plain path as well as a `file://` URL, because a shell script interpolating
    /// `$HOME/Desktop/shot.png` is the common case and rejecting it would be pedantry.
    private static func filepath(from url: URL) -> URL? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.lowercased() == "filepath" })?.value,
              !raw.isEmpty
        else { return nil }
        if raw.hasPrefix("file://") { return URL(string: raw) }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// 1-based, as the reference documents it. Zero and negatives are refused rather than
    /// clamped: a script that computed an index wrongly should capture nothing, not the wrong
    /// screen.
    private static func displayIndex(from url: URL) -> Int? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.lowercased() == "display" })?.value,
              let index = Int(raw), index >= 1
        else { return nil }
        return index
    }

    /// Absent means the whole display, which is the right default for an unattended script.
    /// A source we do not have returns nil rather than falling back — a typo should record
    /// nothing, the same rule the rest of this parser follows.
    private static func recordingSource(from url: URL) -> RecordingSource? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.lowercased() == "source" })?.value, !raw.isEmpty
        else { return .display }
        return RecordingSource(rawValue: raw.lowercased())
    }

    private static func windowID(from url: URL) -> CGWindowID? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.lowercased() == "window" })?.value,
              let value = UInt32(raw)
        else { return nil }
        return CGWindowID(value)
    }

    /// Refused rather than clamped when absent or negative: a script that computed a time wrongly
    /// should move nothing, the same rule the rest of this parser follows.
    private static func pane(from url: URL) -> String? {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "pane" }?.value?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return raw?.isEmpty == false ? raw : nil
    }

    private static func seconds(from url: URL) -> TimeInterval? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name.lowercased() == "t" })?.value,
            let value = Double(raw), value >= 0, value.isFinite
        else { return nil }
        return value
    }

    static func parse(_ url: URL) -> CaptureURLCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // `sarvkrit://capture-area` puts the name in `host`; `sarvkrit:capture-area` and
        // `sarvkrit:///capture-area` put it in the path. Accept all three rather than making the
        // number of slashes load-bearing.
        let raw = url.host ?? url.path.split(separator: "/").first.map(String.init) ?? ""
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !name.isEmpty else { return nil }

        if name == "cancel" { return .cancel }
        if name == "capture-previous-area" { return .capturePreviousArea }
        if name == "open-annotate" { return .openAnnotate(filepath(from: url)) }
        if name == "open-from-clipboard" { return .openFromClipboard }
        if name == "open-settings" { return .openSettings(pane: pane(from: url)) }
        if name == "stop-recording" { return .stopRecording }
        if name == "record-bar" { return .showRecordBar }
        if name == "aim" { return .aimRecording }
        if name == "seek" { return seconds(from: url).map { .seek($0) } }
        if name == "play" { return .playPause }
        if name == "export" { return filepath(from: url).map { .exportEditor($0) } }
        if name == "picture" { return filepath(from: url).map { .addPicture($0) } }
        if name == "editor" {
            guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name.lowercased() == "do" })?.value,
                let command = StudioEditorCommand(rawValue: raw.lowercased())
            else { return nil }
            return .editorCommand(command)
        }
        if name == "record" {
            guard let source = recordingSource(from: url) else { return nil }
            return .record(source, windowID: windowID(from: url))
        }
        if let match = names.first(where: { $0.value == name })?.key {
            // All four or none. Three of them is a script with a bug in it, and guessing the
            // fourth would take a screenshot of the wrong thing rather than saying so.
            if match == .area, let rect = rect(from: url) {
                return .captureRect(rect, displayIndex: displayIndex(from: url))
            }
            return .action(match)
        }
        // The action's own raw value as a fallback, so `sarvkrit://area` works too.
        if let action = ScreenshotAction(rawValue: raw) { return .action(action) }
        return nil
    }
}
