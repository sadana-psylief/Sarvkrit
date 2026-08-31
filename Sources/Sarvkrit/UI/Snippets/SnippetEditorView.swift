import SwiftUI

/// Add or edit one snippet.
struct SnippetEditorView: View {
    @State private var draft: Snippet
    @Environment(\.dismiss) private var dismiss
    private let onSave: (Snippet) -> Void

    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void) {
        _draft = State(initialValue: snippet)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Trigger", text: $draft.trigger, prompt: Text(";addr"))
                        .font(.system(.body, design: .monospaced))

                    Picker("When to expand", selection: $draft.style) {
                        ForEach(Snippet.Style.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Trigger")
                } footer: {
                    Text(draft.style.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $draft.expansion)
                        .font(.system(.body))
                        .frame(minHeight: 90)
                } header: {
                    Text("Expands to")
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(SnippetPattern.documentedTokens, id: \.token) { token, description in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                                Text(token)
                                    .font(.system(size: 11, design: .monospaced))
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    // The token engine is pure, so previewing costs nothing and can't drift from
                    // what will actually be typed.
                    Text(preview)
                        .font(.system(.body))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Preview")
                } footer: {
                    if let problem = draft.validationProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if SnippetPattern.isDynamic(draft.expansion) {
                        Text("Shown as it would expand right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.validationProblem != nil)
            }
            .padding(Theme.Space.md)
        }
        .frame(width: 460, height: 520)
    }

    private var preview: String {
        let expanded = SnippetPattern.expand(draft.expansion)
        return expanded.isEmpty ? "—" : expanded
    }
}
