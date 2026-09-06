import Foundation

/// What to put in the toast when a recording will not start.
///
/// Separate and pure so the wording is testable, and because "Couldn't start recording" — which is
/// all this used to say, for every cause — is the least useful sentence the app can produce. A
/// recording that fails silently or generically is indistinguishable from a shortcut that does
/// nothing, and both were reported as the same bug.
enum RecordingFailureMessage {

    /// - Returns: a sentence naming what went wrong, and the symbol to show beside it.
    static func describe(_ error: Error) -> (text: String, symbolName: String) {
        guard let recording = error as? RecordingError else {
            // Anything from AVFoundation or ScreenCaptureKit that we have no case for. Its own
            // description is still better than a generic line, and the log carries the rest.
            let described = (error as NSError).localizedDescription
            return (described.isEmpty ? "Couldn't start recording" : described,
                    "exclamationmark.triangle")
        }

        switch recording {
        case .noDisplays:
            return ("Sarvkrit can't see the screen yet", "display.trianglebadge.exclamationmark")
        case .displayGone:
            return ("That display has gone", "display.trianglebadge.exclamationmark")
        case .windowGone:
            return ("That window has gone", "macwindow.badge.plus")
        case .cannotWrite:
            return ("Couldn't write the recording", "externaldrive.badge.exclamationmark")
        case .alreadyRecording:
            return ("A recording is already starting", "record.circle")
        case .outOfSpace(let free):
            let gigabytes = Double(free) / 1_000_000_000
            return (String(format: "Only %.1f GB free", gigabytes),
                    "externaldrive.badge.exclamationmark")
        case .cancelled:
            return ("Recording cancelled", "xmark.circle")
        }
    }
}
