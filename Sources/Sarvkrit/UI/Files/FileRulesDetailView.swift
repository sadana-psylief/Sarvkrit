import SwiftUI

/// The Files detail pane: the rule list, plus recent activity.
///
/// Observes the `RuleStore` **directly** rather than reaching through `AppState`. SwiftUI does not
/// observe through a nested `ObservableObject`, and routing it via AppState is what previously left
/// the onboarding checkmark refusing to update.
struct FileRulesDetailView: View {
    // Observed, not held plainly: "Recent Activity" comes from the feature, and without this the
    // section never appears no matter how many files a rule files.
    @ObservedObject var feature: FileRulesFeature
    @ObservedObject var store: RuleStore
    @EnvironmentObject private var app: AppState

    @State private var editing: Rule?
    @State private var selection: UUID?

    var body: some View {
        Form {
            Section {
                Toggle("Enable File Rules", isOn: app.binding(for: feature))
            } footer: {
                Text("Rules are checked in order and only the first one that matches a file runs, so the order below decides what happens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rules") {
                if store.rules.isEmpty {
                    Text("No rules yet.")
                        .foregroundStyle(.secondary)
                } else {
                    List(selection: $selection) {
                        ForEach(store.rules) { rule in
                            RuleSummaryRow(rule: rule, store: store) { editing = rule }
                                .tag(rule.id)
                        }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { offsets in
                            offsets.map { store.rules[$0].id }.forEach(store.delete(id:))
                        }
                    }
                    .frame(minHeight: 140, maxHeight: 260)
                    .listStyle(.inset)
                }

                Button {
                    // Pre-pointed at Downloads: a rule with no folder can be neither run nor
                    // previewed, and starting from that state makes the editor look broken.
                    editing = Rule(
                        name: "New Rule",
                        isEnabled: false,
                        folderBookmark: FileManager.default
                            .urls(for: .downloadsDirectory, in: .userDomainMask).first
                            .flatMap { ActionRunner.bookmark(for: $0) }
                    )
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }

            if !feature.lastReports.isEmpty {
                Section("Recent Activity") {
                    ForEach(Array(feature.lastReports.prefix(8).enumerated()), id: \.offset) { _, report in
                        ActivityRow(report: report)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("File Rules")
        .sheet(item: $editing) { rule in
            RuleEditorView(rule: rule, feature: feature) { edited in
                if store.rules.contains(where: { $0.id == edited.id }) {
                    store.update(edited)
                } else {
                    store.add(edited)
                }
            }
        }
    }
}

private struct RuleSummaryRow: View {
    let rule: Rule
    @ObservedObject var store: RuleStore
    let edit: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { store.setEnabled($0, id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            // A rule that can't run must not look armed.
            .disabled(!rule.isRunnable)

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .medium))
                if let problem = rule.validationProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(rule.summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Theme.Space.sm)
            Button("Edit", action: edit).buttonStyle(.link).font(.caption)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

private struct ActivityRow: View {
    let report: RuleEngine.Report

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.url.lastPathComponent).font(.caption.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch report.verdict {
        case .acted: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        default: return "minus.circle"
        }
    }

    private var tint: Color {
        switch report.verdict {
        case .acted: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var detail: String {
        switch report.verdict {
        case .acted(let rule, let summaries): return "\(rule): \(summaries.joined(separator: ", "))"
        case .failed(let rule, let reason): return "\(rule) failed: \(reason)"
        case .skippedAlreadyProcessed(let rule): return "Already handled by \(rule)"
        case .skippedUnstable: return "Still being written"
        case .noMatch: return "No rule matched"
        }
    }
}

extension Rule {
    /// One-line description for the list, e.g. "2 conditions → Sort into subfolder".
    var summaryLine: String {
        let conditionText = conditions.count == 1 ? "1 condition" : "\(conditions.count) conditions"
        let actionText = actions.first?.title ?? "no actions"
        let extra = actions.count > 1 ? " +\(actions.count - 1)" : ""
        return "\(conditionText) → \(actionText)\(extra)"
    }
}
