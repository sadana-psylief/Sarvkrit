import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The recordings already on disk, and the way back into one.
///
/// **The gap this closes.** A recording autosaves its project on every edit and again as its
/// window closes, so closing an editor loses nothing — but until now there was no way to open one
/// again. This is that way, along with the Finder, which can do it too now that a `.sarvrec` is
/// declared as a package.
struct RecordingsList: View {
    @State private var entries: [RecordingLibrary.Entry] = []
    /// Which row is waiting for its second click on Delete. Deleting a take is not undoable.
    @State private var confirmingDelete: URL?

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("Recordings you make appear here. They stay editable — reopen one to change "
                     + "the zooms, add text, or export it again at another size.")
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
            }

            ForEach(entries) { entry in
                row(entry)
            }

            HStack(spacing: Theme.Space.md) {
                Button("Open Recording…") { openPanel() }
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: RecordingBundle.defaultDirectory().path)
                }
                Spacer()
                Button("Refresh") { reload() }
            }
        } header: {
            Text("Your recordings")
        }
        .onAppear(perform: reload)
    }

    private func row(_ entry: RecordingLibrary.Entry) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: entry.needsRecovery
                  ? "exclamationmark.triangle" : "film")
                .foregroundStyle(entry.needsRecovery ? .orange : .secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: Theme.Typography.body))
                HStack(spacing: Theme.Space.sm) {
                    Text(entry.lengthDescription)
                    if entry.hasCamera {
                        Label("Camera", systemImage: "person.crop.circle")
                            .labelStyle(.iconOnly)
                    }
                    if entry.needsRecovery {
                        // The flag was written faithfully all along and read by nothing, so a take
                        // the app died inside was indistinguishable from no take at all.
                        Text("Interrupted — may be incomplete")
                    } else if !entry.canOpen {
                        Text("Unreadable")
                    }
                }
                .font(.system(size: Theme.Typography.caption))
                .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.canOpen {
                Button("Open") { StudioEditorController.shared.open(fileAt: entry.url) }
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")

            // Two clicks, because a take took ten minutes to make and there is no undo here.
            Button {
                if confirmingDelete == entry.url {
                    delete(entry)
                } else {
                    confirmingDelete = entry.url
                }
            } label: {
                if confirmingDelete == entry.url {
                    Text("Really?").font(.system(size: Theme.Typography.caption))
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .help("Move this recording to the Trash")
        }
        .padding(.vertical, 2)
    }

    private func reload() {
        entries = RecordingLibrary.entries()
        confirmingDelete = nil
    }

    /// To the Trash rather than erased, whatever the button says — a mistake here would otherwise
    /// cost somebody a take that took ten minutes to make.
    private func delete(_ entry: RecordingLibrary.Entry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        } catch {
            ToastPresenter.shared.show("Couldn't delete that recording",
                                       symbolName: "exclamationmark.triangle")
        }
        reload()
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // A `.sarvrec` is a package, so the panel treats it as a file the moment the type is
        // declared — but `canChooseDirectories` keeps it selectable on a Mac whose Launch
        // Services database has not caught up with a freshly installed build.
        if let type = UTType(filenameExtension: RecordingBundle.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.directoryURL = RecordingBundle.defaultDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        StudioEditorController.shared.open(fileAt: url)
    }
}
