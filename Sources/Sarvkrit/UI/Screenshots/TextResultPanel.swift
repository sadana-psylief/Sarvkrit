import AppKit
import SwiftUI

/// What text recognition actually read, shown rather than summarised.
///
/// **The toast it replaces said "Copied 3 lines" and vanished.** That announces an event without
/// answering the only question anybody has — *what* did it read — so the feature worked and still
/// left people unsure whether it had. Showing the text is also the only way to notice that the
/// wrong region was picked, which a line count can never tell you.
@MainActor
final class TextResultController {
    static let shared = TextResultController()

    private var panel: FloatingPanel?
    private var escapeMonitor: Any?

    func show(text: String, isBarcode: Bool) {
        dismiss()
        guard !text.isEmpty else {
            ToastPresenter.shared.show("No text found", symbolName: "text.viewfinder")
            return
        }

        let content = TextResultView(text: text,
                                     isBarcode: isBarcode,
                                     onClose: { [weak self] in self?.dismiss() })
        let hosting = NSHostingView(rootView: content)
        let size = CGSize(width: 460, height: min(max(hosting.fittingSize.height, 180), 460))

        let visible = ScreenPlacement.screenUnderPointer()?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = FloatingPanel(
            contentRect: NSRect(x: visible.midX - size.width / 2,
                                y: visible.midY - size.height / 2,
                                width: size.width, height: size.height),
            // Key, because Escape closes it and the text is selectable.
            style: .init(level: .modalPanel, acceptsKey: true, clickThrough: false,
                         joinsAllSpaces: true, hasShadow: true))
        panel.contentView = NSHostingView(rootView: content)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // Escape
            self?.dismiss()
            return nil
        }
    }

    func dismiss() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct TextResultView: View {
    let text: String
    let isBarcode: Bool
    let onClose: () -> Void

    @State private var copiedAgain = false

    /// A URL in the payload, when there is exactly one and it is the whole of it.
    ///
    /// Deliberately strict: offering "Open Link" for a URL buried in a paragraph invites a click
    /// on something the user did not read. And it is only ever an *offer* — a link scanned off the
    /// screen is opened because a person chose to, never automatically, which is the rule the QR
    /// path has always followed.
    private var link: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    private var lineCount: Int {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: isBarcode ? "qrcode" : "text.viewfinder")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isBarcode ? "Code copied" : "Text copied")
                        .font(.subheadline.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            // Selectable, so a part of it can be taken without recognising the region again.
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: isBarcode ? .monospaced : .default))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.sm)
            }
            .frame(maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))

            HStack(spacing: Theme.Space.sm) {
                if let link {
                    Button("Open Link") { NSWorkspace.shared.open(link) }
                        .help(link.absoluteString)
                }
                Spacer(minLength: 0)
                Button(copiedAgain ? "Copied" : "Copy Again") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copiedAgain = true
                }
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .background(.regularMaterial)
        .background(WindowDragHandle())
    }

    private var summary: String {
        let characters = text.count
        if isBarcode { return "\(characters) character\(characters == 1 ? "" : "s")" }
        return "\(lineCount) line\(lineCount == 1 ? "" : "s") · "
            + "\(characters) character\(characters == 1 ? "" : "s")"
    }
}
