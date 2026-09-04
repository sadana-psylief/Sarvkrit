import SwiftUI

/// Written once, renders any `Feature`. Adding a feature never touches this file.
///
/// Deliberately observes nothing. It used to hold an `@EnvironmentObject` on `AppState` for the
/// generic pane's sake, which meant every unrelated AppState change — including a tray tab click
/// in the other window — re-ran this body and rebuilt whichever custom pane was open. The generic
/// pane keeps the observation it actually needs; the wrapper doesn't.
struct FeatureDetailView: View {
    let feature: any Feature

    var body: some View {
        // A feature may substitute its own pane when the generic one can't express it — a rules
        // editor, say. Most features return nil and get the generic one for free.
        if let custom = feature.makeDetailView() {
            custom
                // `makeDetailView` hands back a fresh `AnyView` each call, which erases the view's
                // static type. Keying on the feature gives SwiftUI something stable to match on.
                .id(feature.id)
                .navigationTitle(feature.title)
        } else {
            GenericFeatureDetailView(feature: feature)
        }
    }
}

/// Title, toggle, prose and permission status — everything a feature needs when it has no special
/// controls of its own.
private struct GenericFeatureDetailView: View {
    @EnvironmentObject private var app: AppState
    let feature: any Feature

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Space.lg) {
                    FeatureIconTile(
                        symbolName: feature.symbolName,
                        isOn: app.isEnabled(feature) && !app.isBlocked(feature),
                        size: 44
                    )
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(feature.title).font(.title2.weight(.semibold))
                        Text(feature.summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Space.sm)
            }

            Section {
                Toggle("Enable", isOn: app.binding(for: feature))
                    .disabled(app.isBlocked(feature))
            } footer: {
                if app.isBlocked(feature) {
                    Text(app.blockingRequirement(for: feature).map {
                        "Grant \($0.title) below to turn this on."
                    } ?? "Grant the permission below to turn this on.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("How it works") {
                Text(feature.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = feature.shortcutHint {
                    LabeledContent("Try it") {
                        Text(hint).font(.callout.monospaced())
                    }
                }
            }

            // Driven by `requirements`, not by a hardcoded Accessibility check. A feature that
            // needs Screen Recording used to render here as "Accessibility access: Not granted",
            // which is worse than saying nothing — it sends the user to the wrong settings pane.
            // Only queryable grants appear: one we cannot ask about has no honest answer to show.
            let shown = feature.requirements.filter(\.isQueryable).sorted { $0.sortOrder < $1.sortOrder }
            if !shown.isEmpty {
                Section("Requirements") {
                    ForEach(shown, id: \.self) { requirement in
                        let granted = app.permissions.isGranted(requirement)
                        LabeledContent(requirement.title) {
                            HStack(spacing: Theme.Space.sm) {
                                Image(systemName: granted
                                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(granted ? .green : .orange)
                                    .accessibilityHidden(true)
                                Text(granted ? "Granted" : "Not granted")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !granted {
                            Button(requirement.isRequestable
                                   ? "Allow \(requirement.title)…" : "Open System Settings") {
                                app.permissions.request(requirement)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
    }
}
