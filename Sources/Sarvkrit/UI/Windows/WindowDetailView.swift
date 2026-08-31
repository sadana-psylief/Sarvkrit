import SwiftUI

struct WindowDetailView: View {
    @ObservedObject var feature: WindowFeature
    @EnvironmentObject private var app: AppState

    @State private var expandedGroups: Set<WindowAction.Group> = [.halves, .size]

    var body: some View {
        Form {
            Section {
                Toggle("Window Management", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Snap the focused window with the keyboard. Shortcuts only fire while this is \
                    on, and the keys go back to the app you're using the moment you turn it off.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ultrawideSection
            shortcutSections
        }
        .formStyle(.grouped)
    }

    // MARK: - Ultrawide

    @ViewBuilder
    private var ultrawideSection: some View {
        Section {
            Toggle("Optimize for ultrawide displays", isOn: Binding(
                get: { feature.ultrawideEnabled },
                set: { feature.ultrawideEnabled = $0 }
            ))

            if feature.ultrawideEnabled {
                // Whole percent, so the slider lands on values that mean something.
                LabeledContent("Maximize fills") {
                    HStack(spacing: Theme.Space.sm) {
                        Slider(
                            value: Binding(
                                get: { Double(feature.ultrawideMaxWidthPercent) },
                                set: { feature.ultrawideMaxWidthPercent = Int($0.rounded()) }
                            ),
                            in: 40...100,
                            step: 5
                        )
                        .frame(width: 160)
                        Text("\(feature.ultrawideMaxWidthPercent)%")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Ultrawide")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("""
                    On a very wide display a half is wider than anyone wants a window. With this on, \
                    ⌃⌥← and ⌃⌥→ give thirds instead — press the same one again to cycle through a \
                    third, a half and two-thirds — and Maximize stops short of filling the screen.
                    """)
                // The per-screen rule is the part worth stating: it's what makes the setting safe
                // to leave on with a laptop attached.
                Text("""
                    This applies per display. A laptop alongside an ultrawide keeps its halves.
                    """)
                if feature.hasUltrawideDisplay && !feature.ultrawideEnabled {
                    Label("An ultrawide display is connected.", systemImage: "sparkles")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var shortcutSections: some View {
        ForEach(WindowAction.Group.allCases) { group in
            Section {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedGroups.contains(group) },
                        set: { isOpen in
                            if isOpen { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
                        }
                    )
                ) {
                    // Bindings are built fresh on every render rather than cached. A shared cached
                    // Binding across view trees is exactly what once made toggles revert.
                    ForEach(actions(in: group)) { action in
                        LabeledContent(action.title) {
                            ShortcutRecorderView(
                                action: action,
                                current: feature.shortcuts.shortcut(for: action),
                                existing: feature.shortcuts.bindings,
                                onRecord: { feature.bind(action, to: $0) },
                                onRecordingChanged: { feature.isRecording = $0 }
                            )
                        }
                    }
                } label: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text(boundCount(in: group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section {
            Button("Reset All Shortcuts") { feature.resetShortcuts() }
        } footer: {
            Text("Click a shortcut to change it. ⌫ clears one, ⎋ cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func actions(in group: WindowAction.Group) -> [WindowAction] {
        WindowAction.allCases.filter { $0.group == group }
    }

    private func boundCount(in group: WindowAction.Group) -> String {
        let actions = actions(in: group)
        let bound = actions.filter { feature.shortcuts.shortcut(for: $0) != nil }.count
        return "\(bound) of \(actions.count)"
    }
}
