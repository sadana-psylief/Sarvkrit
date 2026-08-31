import SwiftUI

/// Trash Cleanup's own pane. Carries the Full Disk Access status, which `PermissionsManager`
/// deliberately knows nothing about — there is no API to query FDA, so the only honest signal is
/// whether the last read of the Trash actually worked.
struct TrashCleanupDetailView: View {
    @ObservedObject var feature: TrashCleanupFeature
    @EnvironmentObject private var app: AppState

    @State private var days: Int
    @State private var capMB: Int
    @State private var preview: [TrashPolicy.Item] = []
    @State private var hasPreviewed = false

    init(feature: TrashCleanupFeature) {
        self.feature = feature
        _days = State(initialValue: feature.deleteAfterDays)
        _capMB = State(initialValue: feature.sizeCapMB)
    }

    /// Read straight from the feature. This used to be mirrored into `@State`, which shadowed the
    /// published value and meant the permission status only ever updated when a button was pressed.
    private var access: TrashCleanupFeature.Access { feature.access }

    var body: some View {
        Form {
            // Surfaced immediately, not hidden behind the preview button. macOS never prompts for
            // Full Disk Access, so without this the feature just appears to do nothing.
            if access == .denied {
                Section { fullDiskAccessNotice }
            }

            Section {
                Toggle("Enable Trash Cleanup", isOn: app.binding(for: feature))
            } footer: {
                Text("This permanently removes items — things in the Trash have nowhere further to go. Every removal is written to the log.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // No `Section(_:content:footer:)` exists — a string title and a footer can't be
            // combined, so the header goes in its own builder.
            Section {
                Stepper(value: $days, in: 0...365) {
                    Text(days > 0 ? "Delete items after \(days) days" : "Don’t delete by age")
                }
                .onChange(of: days) { _, new in feature.deleteAfterDays = new }

                Stepper(value: $capMB, in: 0...102_400, step: 512) {
                    Text(capMB > 0 ? "Keep the Trash under \(capMB) MB" : "No size limit")
                }
                .onChange(of: capMB) { _, new in feature.sizeCapMB = new }
            } header: {
                Text("Rules")
            } footer: {
                Text("When the Trash is over its size limit, the oldest items go first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                Button {
                    preview = feature.run(dryRun: true)
                    hasPreviewed = true
                } label: {
                    Label("Show what would be removed", systemImage: "eye")
                }

                if access == .granted, hasPreviewed {
                    LabeledContent("In the Trash", value: "\(feature.trashItemCount) item(s)")
                    if preview.isEmpty {
                        // Distinguishes "working, nothing qualifies yet" from "broken".
                        Text("Nothing is old enough to remove yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(preview.prefix(20).enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text(item.url.lastPathComponent).font(.caption).lineLimit(1)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if preview.count > 20 {
                            Text("…and \(preview.count - 20) more").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let last = feature.lastRunDate {
                Section("Last Run") {
                    LabeledContent("When", value: last.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Removed", value: "\(feature.lastRemovalCount) item(s)")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Trash Cleanup")
        // Probe on sight so the permission problem is visible before anything is clicked —
        // off the main thread, so opening the pane doesn't stall on stat-ing every item.
        .onAppear { feature.probe() }
    }

    private var fullDiskAccessNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("Needs Full Disk Access", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            // Unlike the Accessibility grant, macOS shows no prompt for this one — the user has to
            // add the app by hand, so saying so is the difference between "broken" and "one step".
            Text("macOS doesn’t ask for this one. Open System Settings, then drag Sarvkrit into the Full Disk Access list or add it with the + button.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { feature.openFullDiskAccessSettings() }
        }
        .padding(.vertical, Theme.Space.xs)
    }
}
