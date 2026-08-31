import SwiftUI

struct KeepAwakeDetailView: View {
    @ObservedObject var feature: KeepAwakeFeature
    @EnvironmentObject private var app: AppState

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            // First, because it means the machine is currently unable to sleep and the user may
            // have no idea why.
            if feature.hasStrandedFlag {
                Section { strandedNotice }
            }

            Section {
                Toggle("Keep Awake", isOn: app.binding(for: feature))
                Toggle("Also keep the display on", isOn: Binding(
                    get: { feature.keepDisplayOn },
                    set: { feature.keepDisplayOn = $0 }
                ))
            } footer: {
                Text("Prevents your Mac idling to sleep. Turning this off restores normal behaviour straight away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Stay awake for", selection: Binding(
                    get: { feature.duration },
                    set: { feature.duration = $0 }
                )) {
                    ForEach(KeepAwakeDuration.allCases) { Text($0.title).tag($0) }
                }
                if let remaining = feature.remainingTime {
                    LabeledContent("Time remaining", value: format(remaining))
                }
            } header: {
                Text("Duration")
            }

            Section {
                Toggle("Keep awake with the lid closed", isOn: Binding(
                    get: { feature.lidClosed },
                    set: { feature.lidClosed = $0 }
                ))
                LabeledContent("System sleep") {
                    Text(feature.lidClosedActive ? "Disabled" : "Normal")
                        .foregroundStyle(feature.lidClosedActive ? Color.orange : Color.secondary)
                }
            } header: {
                Text("Lid Closed")
            } footer: {
                // Said plainly, because it's a machine-wide change and it asks for a password.
                Text("""
                    This changes a system-wide setting, so macOS will ask for your password. It's the \
                    only way to keep working with the lid shut.

                    Sarvkrit starts a background task at the same time that restores normal sleep as \
                    soon as Sarvkrit quits — including if it crashes — so your Mac can't be left \
                    awake in a bag. A restart is the one case it can't cover; you'll be told here if \
                    that happens.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Keep Awake")
        .onAppear { feature.reconcile() }
        // Guarded, the way MenuBarLabel already guards its own tick: `now` exists only to drive
        // the countdown, and writing it unconditionally re-rendered the whole Form once a second
        // even with nothing counting down.
        .onReceive(tick) { instant in
            guard feature.remainingTime != nil else { return }
            now = instant
        }
    }

    private var strandedNotice: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("Sleep is still disabled from last session", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Your Mac restarted while the lid-closed option was on, which stopped the background task that would have restored normal sleep. It's safe to fix now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Restore Normal Sleep") { feature.restoreSleep() }
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
