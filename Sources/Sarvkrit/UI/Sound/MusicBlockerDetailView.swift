import SwiftUI

struct MusicBlockerDetailView: View {
    @ObservedObject var feature: MusicBlockerFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Music Blocker", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Closes Apple Music when it opens itself after headphones or a speaker connect. \
                    Opening it yourself still works.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Times closed") {
                    Text("\(feature.blockedCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if feature.blockedCount > 0 {
                    Button("Reset the count") { feature.resetCount() }
                }
            } header: {
                Text("So far")
            } footer: {
                Text("""
                    Sarvkrit only steps in when Music appears within a few seconds of an audio \
                    device connecting — that's what a self-launch looks like, and what opening it \
                    deliberately doesn't. You'll see a brief message each time, so an app closing \
                    is never a mystery.

                    Other players are left alone. Spotify opening on connect is Spotify's business.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
