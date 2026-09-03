import AppKit
import SwiftUI

/// The `sarvkrit://` commands, listed where somebody might find them.
///
/// A URL scheme nobody can discover is a URL scheme nobody uses, and this is the seam Raycast,
/// Alfred, Shortcuts and Stream Deck hang off. Each row copies its own URL, because the one thing
/// anybody wants from this list is the string in their clipboard.
struct CaptureAutomationSection: View {
    @State private var copied: String?

    private var commands: [CaptureURLCommand] {
        // Cancel last: it is the escape hatch, not a capture mode.
        CaptureURLCommand.all.filter { $0 != .cancel } + [.cancel]
    }

    var body: some View {
        Section {
            ForEach(commands, id: \.name) { command in
                LabeledContent(title(for: command)) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url(for: command), forType: .string)
                        copied = command.name
                    } label: {
                        HStack(spacing: Theme.Space.xs) {
                            Text(url(for: command))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Image(systemName: copied == command.name
                                  ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .clickableCursor()
                    .help("Copy this URL")
                }
            }
        } header: {
            Text("Automation")
        } footer: {
            Text("""
                Run any of these from a script, Shortcuts, Raycast or a Stream Deck key with \
                `open sarvkrit://…`. The last one puts every overlay, countdown and pinned window \
                away — the same thing ⌃⇧⎋ does, for when a script needs to clean up after itself.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func title(for command: CaptureURLCommand) -> String {
        switch command {
        case .cancel: return "Dismiss Everything"
        case .openAnnotate: return "Annotate Last Capture"
        case .openFromClipboard: return "Annotate Clipboard Image"
        case .openSettings: return "Open Settings"
        case .captureRect: return "Capture Area"
        case .action(let action): return action.title
        }
    }

    private func url(for command: CaptureURLCommand) -> String {
        "\(CaptureURLCommand.scheme)://\(command.name)"
    }
}
