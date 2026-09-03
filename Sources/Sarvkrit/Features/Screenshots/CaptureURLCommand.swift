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

    static let scheme = "sarvkrit"

    /// The command name as it appears in a URL, for the settings pane to list.
    var name: String {
        switch self {
        case .cancel: return "cancel"
        case .captureRect: return "capture-area"
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
        ScreenshotAction.allCases.map { .action($0) } + [.cancel]
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

    static func parse(_ url: URL) -> CaptureURLCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // `sarvkrit://capture-area` puts the name in `host`; `sarvkrit:capture-area` and
        // `sarvkrit:///capture-area` put it in the path. Accept all three rather than making the
        // number of slashes load-bearing.
        let raw = url.host ?? url.path.split(separator: "/").first.map(String.init) ?? ""
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !name.isEmpty else { return nil }

        if name == "cancel" { return .cancel }
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
