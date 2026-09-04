import SwiftUI

struct DisplaysDetailView: View {
    @ObservedObject var feature: DisplaysFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Displays", isOn: app.binding(for: feature))
            } footer: {
                Text(feature.details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if feature.displays.isEmpty {
                    Text("No displays found.").foregroundStyle(.secondary)
                }
                ForEach(feature.displays) { display in
                    LabeledContent(display.name) {
                        Text(describe(feature.channel(for: display)))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Connected displays")
            } footer: {
                Text("Sarvkrit uses the best channel each display answers on. "
                     + "Dimming the picture is the fallback where there is no backlight it can set.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
        .onAppear { feature.refresh() }
    }

    private func describe(_ channel: BrightnessChannel) -> String {
        switch channel {
        case .displayServices: return "Backlight"
        case .ddc: return "Monitor controls (DDC)"
        case .gamma: return "Dims the picture"
        case .unavailable: return "Not adjustable"
        }
    }
}
