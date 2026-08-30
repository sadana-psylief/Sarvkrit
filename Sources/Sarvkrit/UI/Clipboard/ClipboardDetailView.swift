import AppKit
import SwiftUI

struct ClipboardDetailView: View {
    @ObservedObject var feature: ClipboardFeature
    @ObservedObject var store: ClipboardStore
    @EnvironmentObject private var app: AppState

    @State private var newIgnoredApp = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Clipboard History", isOn: app.binding(for: feature))
            } footer: {
                Text("⌘⇧C opens the list at your cursor, then ⌘1–5 pick an entry. ⌃⌥1–5 paste the first five without opening it — ⌘1–5 can't work globally because your browser uses it for tabs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Text", isOn: binding(\.storeText))
                Toggle("Images", isOn: binding(\.storeImages))
                Toggle("Files", isOn: binding(\.storeFiles))
            } header: {
                Text("What to keep")
            }

            Section {
                Stepper(value: binding(\.maxItemSizeMB), in: 0...1_024, step: 8) {
                    Text(feature.settings.maxItemSizeMB > 0
                         ? "Skip items over \(feature.settings.maxItemSizeMB) MB"
                         : "No size limit")
                }
                Stepper(value: binding(\.historyLimit), in: 10...1_000, step: 10) {
                    Text("Keep \(feature.settings.historyLimit) items")
                }
            } header: {
                Text("Limits")
            } footer: {
                Text(feature.settings.maxItemSizeMB > 0
                     ? "Copying a folder is allowed while a size limit is set."
                     : "With no size limit, copying a folder is skipped — only individual files are kept. Pinned items are never removed to make room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Sort by", selection: binding(\.sortMode)) {
                    ForEach(ClipboardSortMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Search", selection: binding(\.searchMode)) {
                    ForEach(ClipboardSearch.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Pinned items", selection: binding(\.pinnedPosition)) {
                    ForEach(PinnedPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("List")
            } footer: {
                Text(feature.settings.searchMode == .fuzzy
                     ? "Fuzzy matching finds “invoice-2026.pdf” when you type “invpdf”."
                     : "Exact matching looks for what you typed, in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show app icons", isOn: binding(\.showAppIcons))
                Toggle("Highlight search matches", isOn: binding(\.highlightMatches))
                Stepper(value: binding(\.imageRowHeight), in: 20...120, step: 10) {
                    Text("Image height: \(feature.settings.imageRowHeight) pt")
                }
                Stepper(value: binding(\.previewDelayMilliseconds), in: 0...5_000, step: 250) {
                    Text(feature.settings.previewDelayMilliseconds > 0
                         ? "Preview after \(feature.settings.previewDelayMilliseconds) ms"
                         : "Preview immediately")
                }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Hovering a row for the preview delay shows its full contents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Paste immediately", isOn: binding(\.pasteImmediately))
            } footer: {
                Text(feature.settings.pasteImmediately
                     ? "Choosing an entry pastes it into whatever you were using."
                     : "Choosing an entry puts it on the clipboard; press ⌘V yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ignoredApps

            Section {
                LabeledContent("Stored", value: "\(store.items.count) items")
                Button("Clear History…", role: .destructive) { confirmClear = true }
            } header: {
                Text("History")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard History")
        .confirmationDialog("Clear the whole clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items go too. This can't be undone.")
        }
    }

    private var ignoredApps: some View {
        Section {
            ForEach(Array(feature.settings.ignoredBundleIDs).sorted(), id: \.self) { bundleID in
                HStack {
                    Text(bundleID).font(.system(size: 12).monospaced())
                    Spacer()
                    Button {
                        feature.update { $0.ignoredBundleIDs.remove(bundleID) }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop ignoring \(bundleID)")
                }
            }

            HStack {
                TextField("com.example.app", text: $newIgnoredApp)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addIgnoredApp() }
                    .disabled(newIgnoredApp.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Choose App…") { chooseApp() }
            }
        } header: {
            Text("Never record from")
        } footer: {
            // The reason this list exists, stated plainly — it isn't obvious why you'd need it.
            Text("Copies marked confidential by a password manager are already skipped automatically. This list is for apps that don't mark them — passwords copied from browser extensions often aren't.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addIgnoredApp() {
        let trimmed = newIgnoredApp.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        feature.update { $0.ignoredBundleIDs.insert(trimmed) }
        newIgnoredApp = ""
    }

    /// Picking the app is far more reliable than expecting someone to know its bundle identifier.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        feature.update { $0.ignoredBundleIDs.insert(bundleID) }
    }

    private func binding<Value: Equatable>(
        _ keyPath: WritableKeyPath<ClipboardSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { feature.settings[keyPath: keyPath] },
            set: { newValue in feature.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}
