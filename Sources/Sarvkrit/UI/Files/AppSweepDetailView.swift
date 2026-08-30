import SwiftUI

/// App Sweep's pane: pending offers, each with its candidates listed, sized and individually
/// deselectable. Nothing is ever swept without passing through this screen.
struct AppSweepDetailView: View {
    @ObservedObject var feature: AppSweepFeature
    @EnvironmentObject private var app: AppState

    @State private var deselected: Set<String> = []

    var body: some View {
        Form {
            Section {
                Toggle("Enable App Sweep", isOn: app.binding(for: feature))
            } footer: {
                Text("Sarvkrit will never remove anything without showing you this list first. Everything you approve goes to the Trash, not straight to deletion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if feature.findings.isEmpty {
                Section("Leftovers") {
                    Text("Nothing to clean up. Delete an app and its leftovers will appear here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(feature.findings) { finding in
                    findingSection(finding)
                }
            }

            Section("Watching") {
                LabeledContent("Apps tracked", value: "\(feature.inventory.count)")
                Button("Rescan Applications") { feature.refreshInventory() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("App Sweep")
    }

    @ViewBuilder
    private func findingSection(_ finding: AppSweepFeature.Finding) -> some View {
        Section {
            ForEach(finding.candidates) { candidate in
                HStack(spacing: Theme.Space.sm) {
                    Toggle("", isOn: Binding(
                        get: { !deselected.contains(candidate.id) },
                        set: { keep in
                            if keep { deselected.remove(candidate.id) } else { deselected.insert(candidate.id) }
                        }
                    ))
                    .labelsHidden()

                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.url.lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                        // The parent folder is the useful part — "Caches" versus "Preferences"
                        // tells you what you're about to lose.
                        Text(candidate.url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Theme.Space.sm)
                    Text(ByteCountFormatter.string(fromByteCount: candidate.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Move Selected to Trash") {
                    let selected = Set(finding.candidates.map(\.id)).subtracting(deselected)
                    feature.sweep(finding, selected: selected)
                }
                .disabled(finding.candidates.allSatisfy { deselected.contains($0.id) })

                Button("Keep Everything") { feature.dismiss(finding) }
            }
        } header: {
            HStack {
                Text("\(finding.app.name) was removed")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: finding.totalSize, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
