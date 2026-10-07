import SwiftUI

/// The Fan Control pane in the main window.
struct FanControlDetailView: View {
    @ObservedObject var feature: FanControlFeature
    @EnvironmentObject private var app: AppState

    /// The picker's selection, kept separate from `FanMode` because that carries the speed and
    /// the curve with it — binding a picker straight to it would rebuild the associated values on
    /// every redraw and lose whatever the user had dialled in.
    private enum Choice: String, CaseIterable, Identifiable {
        case watch, manual, automatic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .watch: return "Watch only"
            case .manual: return "Set a speed"
            case .automatic: return "Speed up when hot"
            }
        }
    }

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

                Section("What Sarvkrit does") {
                    Picker("", selection: choice) {
                        ForEach(Choice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if case .manual = feature.mode { manualControls }
                    if case .automatic = feature.mode { rampControls }

                    if feature.controlWasLost {
                        Label(
                            "Fan control stopped, and the fans are back on macOS. "
                            + "Choose a speed again to restart it.",
                            systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text(costOfControl)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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

    // MARK: - Controls

    @ViewBuilder
    private var manualControls: some View {
        LabeledContent("Speed") {
            HStack {
                Slider(value: manualPercent, in: 0...100, step: 5)
                    .frame(width: 180)
                Text("\(Int(currentManualPercent))%").monospacedDigit().frame(width: 44)
            }
        }
        Text("0% is each fan's slowest, not stopped. Sarvkrit cannot stop a fan.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var rampControls: some View {
        LabeledContent("Above") {
            HStack {
                Slider(value: threshold, in: 50...90, step: 1).frame(width: 180)
                Text("\(Int(currentCurve.thresholdCelsius)) °C").monospacedDigit().frame(width: 52)
            }
        }
        LabeledContent("Run the fans at") {
            HStack {
                Slider(value: rampTarget, in: 0...100, step: 5).frame(width: 180)
                Text("\(Int(currentCurve.targetPercent))%").monospacedDigit().frame(width: 44)
            }
        }
        Text("Below that, the fans go back to macOS. Above \(Int(FanPolicy.hardCeilingCelsius)) °C "
             + "they do too, whatever is set here — macOS knows more than Sarvkrit does when a Mac "
             + "is that hot.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// The bargain, stated where the user is about to accept it rather than buried in the README.
    private var costOfControl: String {
        if case .monitor = feature.mode {
            return "Reading the fans needs no password. Setting their speed does: macOS only lets "
                + "a program running as root write to the fan controller."
        }
        return "Sarvkrit asked for your password once to start a small background program that "
            + "sets the fan speed. It hands the fans back to macOS the moment Sarvkrit quits, "
            + "crashes or is switched off — and a restart resets them regardless."
    }

    // MARK: - Bindings

    private var currentManualPercent: Double {
        if case let .manual(percent) = feature.mode { return percent }
        return 50
    }

    private var currentCurve: FanCurve {
        if case let .automatic(curve) = feature.mode { return curve }
        return FanCurve()
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                switch feature.mode {
                case .monitor: return .watch
                case .manual: return .manual
                case .automatic: return .automatic
                }
            },
            set: { new in
                switch new {
                case .watch: feature.mode = .monitor
                case .manual: feature.mode = .manual(percent: currentManualPercent)
                case .automatic: feature.mode = .automatic(currentCurve)
                }
            })
    }

    private var manualPercent: Binding<Double> {
        Binding(get: { currentManualPercent }, set: { feature.mode = .manual(percent: $0) })
    }

    private var threshold: Binding<Double> {
        Binding(get: { currentCurve.thresholdCelsius },
                set: { var curve = currentCurve; curve.thresholdCelsius = $0
                       feature.mode = .automatic(curve) })
    }

    private var rampTarget: Binding<Double> {
        Binding(get: { currentCurve.targetPercent },
                set: { var curve = currentCurve; curve.targetPercent = $0
                       feature.mode = .automatic(curve) })
    }
}
