import SwiftUI

struct WindowDetailView: View {
    @ObservedObject var feature: WindowFeature
    @EnvironmentObject private var app: AppState

    @State private var expandedGroups: Set<WindowAction.Group> = [.halves, .size]
    @State private var zonesExpanded = false

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
            snapAreaSection
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

    // MARK: - Snap areas

    @ViewBuilder
    private var snapAreaSection: some View {
        Section {
            Toggle("Snap by dragging to an edge", isOn: Binding(
                get: { feature.snapSettings.snapByDragging },
                set: {
                    feature.setSnapByDragging($0)
                    // The mask itself changes, not just the behaviour, so the tap must be rebuilt.
                    app.resyncEventTap()
                }
            ))

            if feature.snapSettings.snapByDragging {
                Toggle("Restore size when dragged away", isOn: Binding(
                    get: { feature.snapSettings.restoreSizeOnUnsnap },
                    set: { feature.setRestoreSizeOnUnsnap($0) }
                ))
                Toggle("Haptic feedback", isOn: Binding(
                    get: { feature.snapSettings.hapticFeedback },
                    set: { feature.setHapticFeedback($0) }
                ))
                Toggle("Animate the preview", isOn: Binding(
                    get: { feature.snapSettings.animateFootprint },
                    set: { feature.setAnimateFootprint($0) }
                ))
            }
        } header: {
            Text("Snap Areas")
        } footer: {
            Text("""
                Drag a window to a screen edge or corner and a preview shows where it will land. \
                Only the edges and corners react — dragging across the middle of the screen does \
                nothing, so ordinary window moves are unaffected.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if feature.snapSettings.snapByDragging {
            Section {
                // Collapsed by default, and that is a performance decision as much as a tidiness
                // one: nine zones each carrying a picker over ~39 actions is roughly 350 Text
                // views, and they were being built on every render of this pane whether or not
                // anyone had opened them.
                CollapsibleHeader(
                    title: "Zones",
                    caption: customZoneCount,
                    isExpanded: $zonesExpanded
                )

                if zonesExpanded {
                    ForEach(SnapZone.allCases) { zone in
                        LabeledContent(zone.title) {
                            Picker("", selection: Binding(
                                get: { feature.snapSettings.customAction(for: zone) },
                                set: { feature.setSnapAction($0, for: zone) }
                            )) {
                                // Nil means "whatever suits the display", which is not the same as
                                // any one action: it resolves to thirds on an ultrawide and halves
                                // elsewhere, per screen.
                                Text("Default").tag(WindowAction?.none)
                                Divider()
                                ForEach(WindowAction.assignableToZone) {
                                    Text($0.title).tag(WindowAction?.some($0))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                        }
                    }
                    Button("Reset Zones") { feature.resetSnapZones() }
                }
            }
        }
    }

    // MARK: - Shortcuts

    @ViewBuilder
    private var shortcutSections: some View {
        ForEach(WindowAction.Group.allCases) { group in
            Section {
                CollapsibleHeader(
                    title: group.title,
                    caption: boundCount(in: group),
                    isExpanded: expansion(for: group)
                )

                if expandedGroups.contains(group) {
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

    private func expansion(for group: WindowAction.Group) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(group) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(group) } else { expandedGroups.remove(group) }
            }
        )
    }

    private func actions(in group: WindowAction.Group) -> [WindowAction] {
        WindowAction.grouped[group] ?? []
    }

    private var customZoneCount: String {
        let custom = SnapZone.allCases.filter { feature.snapSettings.customAction(for: $0) != nil }
        return custom.isEmpty ? "All default" : "\(custom.count) changed"
    }

    private func boundCount(in group: WindowAction.Group) -> String {
        let actions = actions(in: group)
        let bound = actions.filter { feature.shortcuts.shortcut(for: $0) != nil }.count
        return "\(bound) of \(actions.count)"
    }
}
