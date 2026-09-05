import AppKit
import SwiftUI

/// The update notice, in Settings.
///
/// It hands over a command rather than installing anything, and that is the design, not a
/// shortcut. Until there is a paid Apple Developer account the DMG is signed but not notarized,
/// so a browser download arrives quarantined and hits "System Settings → Privacy & Security →
/// Open Anyway" on *every* update. `curl` sets no quarantine attribute, so the install script
/// never meets that wall — and it already checks the signature and the team itself, quits the
/// running copy, and replaces the app in place.
struct UpdateNoticeView: View {
    var release: LatestRelease
    var onSkip: () -> Void

    static let installCommand = "curl -fsSL https://sarvkrit.com/install | sh"

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Sarvkrit \(release.version?.description ?? release.tagName) is available")
                .font(.subheadline.weight(.semibold))
            Text("You're running \(Bundle.main.shortVersionString).")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let notes = release.displayNotes() {
                ScrollView {
                    // Inline-only: these are GitHub release notes, and full-document Markdown
                    // parsing renders headings and lists badly inside a grouped Form.
                    Text(attributed(notes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }

            Text("To update, run this in Terminal:")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: Theme.Space.sm) {
                Text(Self.installCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy") { copy() }
                    .controlSize(.small)
            }
            .padding(Theme.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack(spacing: Theme.Space.md) {
                if let notesURL = release.notesURL {
                    Link("Release notes", destination: notesURL)
                        .font(.caption)
                }
                Button("Skip This Version", action: onSkip)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }

    private func copy() {
        // A deliberate user action, so no nspasteboard.org "transient" marker: they asked for
        // this to be on the clipboard and it should behave like anything else they copied.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.installCommand, forType: .string)
        copied = true
        ToastPresenter.shared.show("Copied", symbolName: "doc.on.doc")
    }
}
