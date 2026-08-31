import AppKit
import SwiftUI

struct SnippetDetailView: View {
    @ObservedObject var feature: SnippetFeature
    @ObservedObject var store: SnippetStore
    @EnvironmentObject private var app: AppState

    @State private var selection: UUID?
    @State private var editing: Snippet?
    @State private var excludedExpanded = false

    var body: some View {
        Form {
            Section {
                Toggle("Text Snippets", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Type a trigger and it's replaced with the full text. Nothing expands until you \
                    type one of your own triggers.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            snippetsSection
            privacySection
            excludedSection
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { snippet in
            SnippetEditorView(snippet: snippet) { edited in
                if store.snippets.contains(where: { $0.id == edited.id }) {
                    store.update(edited)
                } else {
                    store.add(edited)
                }
            }
        }
    }

    // MARK: - Snippets

    @ViewBuilder
    private var snippetsSection: some View {
        Section {
            if store.snippets.isEmpty {
                Text("No snippets yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.snippets) { snippet in
                    row(snippet)
                }
            }

            HStack {
                Button("Add Snippet…") {
                    editing = Snippet(trigger: "", expansion: "")
                }
                Spacer()
                if let selection, store.snippets.contains(where: { $0.id == selection }) {
                    Button("Delete", role: .destructive) {
                        store.delete(id: selection)
                        self.selection = nil
                    }
                }
            }
        } header: {
            Text("Snippets")
        }
    }

    private func row(_ snippet: Snippet) -> some View {
        HStack(spacing: Theme.Space.md) {
            Toggle("", isOn: Binding(
                get: { snippet.isEnabled },
                set: { store.setEnabled($0, id: snippet.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 1) {
                Text(snippet.trigger.isEmpty ? "(no trigger)" : snippet.trigger)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(preview(of: snippet))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Space.sm)

            if let problem = snippet.validationProblem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(problem)
            }
            Text(snippet.style == .prefix ? "immediate" : "on space")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editing = snippet }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection == snippet.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .clickableCursor()
    }

    /// The expansion as it would actually be typed, so a token shows its value rather than its name.
    private func preview(of snippet: Snippet) -> String {
        let expanded = SnippetPattern.expand(snippet.expansion)
        return expanded.replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    // MARK: - Privacy

    @ViewBuilder
    private var privacySection: some View {
        Section {
            LabeledContent("Characters held") {
                Text(heldDescription)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What this feature sees")
        } footer: {
            // Said plainly and in the UI, not only in a commit message. A feature that watches
            // typing should explain itself where the user can read it.
            Text("""
                To notice a trigger, Sarvkrit has to watch what you type. It is built to hold as \
                little as possible: only the last few characters, never more than your longest \
                trigger, never written to disk, and never logged.

                What you've typed is thrown away the moment you switch apps, click, press Return \
                or Tab, use a keyboard shortcut, or pause. It stands down completely while you're \
                typing in a password field.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var heldDescription: String {
        let longest = store.snippets
            .filter { $0.isEnabled && $0.validationProblem == nil }
            .map(\.trigger.count).max() ?? 0
        guard longest > 0 else { return "None — no snippets are active" }
        return "At most \(longest + 2), your longest trigger plus two"
    }

    // MARK: - Excluded apps

    @ViewBuilder
    private var excludedSection: some View {
        Section {
            CollapsibleHeader(
                title: "Never expand in these apps",
                caption: "\(feature.excludedBundleIDs.count)",
                isExpanded: excludedExpanded
            ) {
                withAnimation(Theme.Motion.standard) { excludedExpanded.toggle() }
            }

            if excludedExpanded {
                ForEach(feature.excludedBundleIDs.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(displayName(for: bundleID))
                        Spacer()
                        Button {
                            var updated = feature.excludedBundleIDs
                            updated.remove(bundleID)
                            feature.excludedBundleIDs = updated
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .clickableCursor()
                        .accessibilityLabel("Stop excluding \(displayName(for: bundleID))")
                    }
                }
                Button("Add App…", action: chooseApp)
            }
        } footer: {
            Text("""
                Terminals and password managers are excluded out of the box — a trigger expanding \
                inside a shell command is at best surprising.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        var updated = feature.excludedBundleIDs
        updated.insert(bundleID)
        feature.excludedBundleIDs = updated
    }
}
