import SwiftUI

/// The Fan Control pane in the main window.
struct FanControlDetailView: View {
    @ObservedObject var feature: FanControlFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Fan Control", isOn: app.binding(for: feature))
                    .disabled(feature.hardware == .fanless)
                if feature.hardware == .fanless {
                    Text("This Mac has no fans, so there is nothing to show or set.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if case let .fans(fans) = feature.hardware {
                Section("Fans") {
                    ForEach(fans) { fan in
                        LabeledContent(FanFormatting.name(of: fan.index, outOf: fans.count)) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(FanFormatting.rpm(fan.rpm)).monospacedDigit()
                                Text(FanFormatting.range(fan))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }

            Section {
                Text(feature.details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
