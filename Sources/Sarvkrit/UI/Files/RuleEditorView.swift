import AppKit
import SwiftUI

/// Edits one rule.
///
/// Works on a **draft copy**, committed only on Save. Binding TextFields straight to the persisted
/// rule would write and re-publish on every keystroke — the churn this app already had to hunt down
/// once — and would leave no way to cancel.
struct RuleEditorView: View {
    @State private var draft: Rule
    @State private var preview: [RuleEngine.Report] = []
    @State private var hasPreviewed = false
    @Environment(\.dismiss) private var dismiss

    private let feature: FileRulesFeature
    private let onSave: (Rule) -> Void

    init(rule: Rule, feature: FileRulesFeature, onSave: @escaping (Rule) -> Void) {
        _draft = State(initialValue: rule)
        self.feature = feature
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    folderPicker
                }

                Section("When a file matches") {
                    Picker("Match", selection: $draft.matchMode) {
                        Text("all of these").tag(MatchMode.all)
                        Text("any of these").tag(MatchMode.any)
                    }
                    .pickerStyle(.segmented)

                    ForEach($draft.conditions) { $condition in
                        ConditionEditor(condition: $condition) {
                            draft.conditions.removeAll { $0.id == condition.id }
                        }
                    }
                    Button {
                        draft.conditions.append(
                            Condition(attribute: .fileExtension, comparison: .isExactly, value: .text(""))
                        )
                    } label: { Label("Add Condition", systemImage: "plus") }
                }

                Section("Do this") {
                    ForEach(Array(draft.actions.enumerated()), id: \.offset) { index, _ in
                        ActionEditor(action: $draft.actions[index]) {
                            draft.actions.remove(at: index)
                        }
                    }
                    Menu {
                        ForEach(Action.allTemplates, id: \.id) { template in
                            Button(template.title) { draft.actions.append(template) }
                        }
                    } label: { Label("Add Action", systemImage: "plus") }
                }

                previewSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(width: 560, height: 620)
    }

    // MARK: - Folder

    private var folderPicker: some View {
        LabeledContent("Watch folder") {
            HStack(spacing: Theme.Space.sm) {
                Text(folderPath ?? "Not chosen")
                    .foregroundStyle(folderPath == nil ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Choose…") { chooseFolder() }
            }
        }
    }

    private var folderPath: String? {
        guard let bookmark = draft.folderBookmark,
              let url = ActionRunner().resolveFolder(bookmark) else { return nil }
        return url.path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        // Reading this folder is what triggers macOS's folder-access prompt; the reason string
        // comes from the NS*FolderUsageDescription keys in Info.plist.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.folderBookmark = ActionRunner.bookmark(for: url)
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSection: some View {
        Section("Preview") {
            Button {
                preview = feature.preview(rule: draft)
                hasPreviewed = true
            } label: {
                Label("Show what this would do", systemImage: "eye")
            }
            .disabled(!draft.isRunnable)

            if hasPreviewed {
                if preview.isEmpty {
                    Text("Nothing in that folder matches.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(preview.enumerated()), id: \.offset) { _, report in
                        PreviewRow(report: report)
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let problem = draft.validationProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            // A rule that can't run is savable but not enable-able; blocking Save would strand
            // half-finished work.
        }
        .padding(Theme.Space.md)
    }
}

private struct PreviewRow: View {
    let report: RuleEngine.Report

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: matched ? "arrow.right.circle.fill" : "minus.circle")
                .foregroundStyle(matched ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.url.lastPathComponent).font(.caption.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var matched: Bool {
        if case .acted = report.verdict { return true }
        return false
    }

    private var detail: String {
        switch report.verdict {
        case .acted(_, let summaries): return summaries.joined(separator: ", ")
        case .failed(_, let reason): return "Would fail: \(reason)"
        default: return "No match"
        }
    }
}

// MARK: - Condition row

private struct ConditionEditor: View {
    @Binding var condition: Condition
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Picker("", selection: Binding(
                get: { condition.attribute },
                // Retargeting repairs the operator and value together, so switching from Size to
                // Name can't leave a byte count behind in a text field.
                set: { condition = condition.retargeted(to: $0) }
            )) {
                ForEach(Attribute.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)

            Picker("", selection: Binding(
                get: { condition.comparison },
                set: { condition = condition.withComparison($0) }
            )) {
                ForEach(condition.attribute.supportedOperators, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)

            ConditionValueEditor(condition: $condition)

            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove condition")
        }
    }
}

private struct ConditionValueEditor: View {
    @Binding var condition: Condition

    var body: some View {
        switch condition.value {
        case .text(let text):
            TextField("value", text: Binding(
                get: { text },
                set: { condition.value = .text($0) }
            ))
        case .number(let bytes):
            HStack(spacing: 4) {
                TextField("MB", value: Binding(
                    get: { Double(bytes) / 1_048_576 },
                    set: { condition.value = .number(Int64($0 * 1_048_576)) }
                ), format: .number.precision(.fractionLength(0...2)))
                Text("MB").font(.caption).foregroundStyle(.secondary)
            }
        case .days(let days):
            HStack(spacing: 4) {
                TextField("days", value: Binding(
                    get: { days },
                    set: { condition.value = .days($0) }
                ), format: .number)
                .frame(width: 50)
                Text("days").font(.caption).foregroundStyle(.secondary)
            }
        case .date(let date):
            DatePicker("", selection: Binding(
                get: { date },
                set: { condition.value = .date($0) }
            ), displayedComponents: .date)
            .labelsHidden()
        case .kind(let kind):
            Picker("", selection: Binding(
                get: { kind },
                set: { condition.value = .kind($0) }
            )) {
                ForEach(FileKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
    }
}

// MARK: - Action row

private struct ActionEditor: View {
    @Binding var action: Action
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(action.title)
                .font(.system(size: 12))
                .frame(width: 150, alignment: .leading)

            parameterEditor

            Spacer(minLength: 0)
            Button {
                remove()
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove action")
        }
    }

    @ViewBuilder
    private var parameterEditor: some View {
        switch action {
        case .rename(let pattern):
            PatternField(pattern: pattern) { action = .rename(pattern: $0) }
        case .sortIntoSubfolder(let pattern):
            PatternField(pattern: pattern) { action = .sortIntoSubfolder(pattern: $0) }
        case .addTag(let tag):
            TextField("tag", text: Binding(get: { tag }, set: { action = .addTag($0) }))
        case .notify(let message):
            TextField("message", text: Binding(get: { message }, set: { action = .notify(message: $0) }))
        case .setColorLabel(let label):
            Picker("", selection: Binding(get: { label }, set: { action = .setColorLabel($0) })) {
                ForEach(ColorLabel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        case .move, .copy:
            DestinationField(action: $action)
        case .moveToTrash:
            EmptyView()
        }
    }
}

/// A pattern field with its token vocabulary attached, so `{date:yyyy-MM}` is discoverable rather
/// than something you have to already know.
private struct PatternField: View {
    let pattern: String
    let onChange: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextField("pattern", text: Binding(get: { pattern }, set: onChange))
            Menu {
                ForEach(RenamePattern.documentedTokens, id: \.token) { entry in
                    Button("\(entry.token) — \(entry.description)") { onChange(pattern + entry.token) }
                }
            } label: {
                Image(systemName: "curlybraces")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("Insert a token")
        }
    }
}

private struct DestinationField: View {
    @Binding var action: Action

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(path ?? "Not chosen")
                .font(.caption)
                .foregroundStyle(path == nil ? Color.orange : Color.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Button("Choose…") { choose() }
        }
    }

    private var path: String? {
        let data: Data
        switch action {
        case .move(let d), .copy(let d): data = d
        default: return nil
        }
        guard !data.isEmpty, let url = ActionRunner().resolveFolder(data) else { return nil }
        return url.path
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = ActionRunner.bookmark(for: url) else { return }
        switch action {
        case .move: action = .move(destinationBookmark: bookmark)
        case .copy: action = .copy(destinationBookmark: bookmark)
        default: break
        }
    }
}
