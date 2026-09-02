import SwiftUI

struct PrivacyGuardDetailView: View {
    @ObservedObject var feature: PrivacyGuardFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Privacy Guard", isOn: app.binding(for: feature))
            } footer: {
                Text("Keeps your microphone off, and tells you when the camera comes on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusSection
            microphoneSection
            cameraSection
            historySection
        }
        .formStyle(.grouped)
    }

    // MARK: - Now

    @ViewBuilder
    private var statusSection: some View {
        Section {
            LabeledContent("Microphone") {
                Label(
                    feature.isMicrophoneMuted ? "Muted" : "Live",
                    systemImage: feature.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill"
                )
                .foregroundStyle(feature.isMicrophoneMuted ? Color.secondary : Color.orange)
            }
            LabeledContent("Camera") {
                Label(
                    feature.isCameraOn ? "On" : "Off",
                    systemImage: feature.isCameraOn ? "video.fill" : "video.slash"
                )
                .foregroundStyle(feature.isCameraOn ? Color.orange : Color.secondary)
            }
            if feature.isMicrophoneInUse {
                Label("Something is using the microphone right now", systemImage: "waveform")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        } header: {
            Text("Now")
        }
    }

    // MARK: - Microphone

    @ViewBuilder
    private var microphoneSection: some View {
        Section {
            Toggle("Keep the microphone muted", isOn: Binding(
                get: { feature.keepMuted },
                set: { feature.keepMuted = $0 }
            ))
            Toggle("Mute at login", isOn: Binding(
                get: { feature.muteAtLogin },
                set: { feature.muteAtLogin = $0 }
            ))
            Toggle("Mute when the Mac sleeps or locks", isOn: Binding(
                get: { feature.muteOnSleep },
                set: { feature.muteOnSleep = $0 }
            ))
            Toggle("Warn when something starts listening", isOn: Binding(
                get: { feature.warnWhenListening },
                set: { feature.warnWhenListening = $0 }
            ))
        } header: {
            Text("Microphone")
        } footer: {
            Text("""
                With the lock on, anything that unmutes your microphone — an app, System Settings, \
                or the Mute Microphone switch — is put straight back. Turn the lock off to change \
                it normally.

                The warning is useful even while muted: it shows you what's trying to listen.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Camera

    @ViewBuilder
    private var cameraSection: some View {
        Section {
            Toggle("Warn when the camera turns on", isOn: Binding(
                get: { feature.warnAboutCamera },
                set: { feature.warnAboutCamera = $0 }
            ))
            Button("Open Camera Privacy Settings") {
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
        } header: {
            Text("Camera")
        } footer: {
            // Said outright. Promising a kill switch this cannot deliver would be worse than the
            // feature simply not existing.
            Text("""
                **Sarvkrit can't switch your camera off.** macOS gives no app a way to do that, so \
                anything claiming to is either using a private trick or, like this, just showing \
                you a warning. To actually stop an app using the camera, take away its access in \
                System Settings.

                Checking whether the camera is on is a question about the device — Sarvkrit never \
                opens the camera, and no video ever reaches it.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        Section {
            if feature.activity.entries.isEmpty {
                Text("Nothing recorded yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(feature.activity.entries) { entry in
                    LabeledContent(entry.device.title) {
                        Text(describe(entry))
                            .foregroundStyle(entry.isOngoing ? Color.orange : Color.secondary)
                            .font(.callout)
                    }
                }
            }
        } header: {
            Text("Recently")
        } footer: {
            Text("""
                Which app was using it isn't shown, because macOS doesn't report that — a name here \
                would be a guess, and wrong exactly when it mattered.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func describe(_ entry: DeviceActivityLog.Entry) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let started = formatter.string(from: entry.startedAt)
        guard let endedAt = entry.endedAt else { return "since \(started)" }
        return "\(started) – \(formatter.string(from: endedAt))"
    }
}
