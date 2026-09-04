import SwiftUI

/// The System Monitor pane.
///
/// Shaped like every other detail pane here — a grouped `Form`, the enable toggle bound through
/// `AppState`, every other setting bound to a guarded property on the feature. It needs no ticker
/// of its own: the feature publishes each reading, and this observes the feature directly.
///
/// The charts are this app's first `import Charts`. That follows the house rule rather than
/// breaking it — `Tokens.swift` says never hand-roll a control the system already provides, and a
/// hand-drawn sparkline would be exactly that. Percentages get a stock `Gauge` for the same reason.
struct SystemMonitorDetailView: View {
    @ObservedObject var feature: SystemMonitorFeature
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("System Monitor", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Nothing is sampled until you switch this on, and switching it off stops \
                    immediately and discards the history.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if feature.isRunning {
                readingsSection
            }

            metricsSection
            menuBarSection
        }
        .formStyle(.grouped)
        .navigationTitle("System Monitor")
    }

    // MARK: - Readings

    private var readingsSection: some View {
        Section {
            // Declaration order, not the user's menu bar order: the pane is a reference list, and
            // a list that reorders itself as you change a menu bar setting is hard to read.
            ForEach(MetricKind.allCases) { kind in
                if feature.enabledMetrics.contains(kind) {
                    LabeledContent {
                        HStack(spacing: Theme.Space.sm) {
                            Text(value(for: kind))
                                // The house style for a number that changes: monospaced digits in a
                                // fixed frame, so the row doesn't twitch on every sample.
                                .monospacedDigit()
                                .frame(width: 132, alignment: .trailing)
                            sparkline(for: kind)
                        }
                    } label: {
                        Label(kind.title, systemImage: kind.symbolName)
                    }
                }
            }
        } header: {
            Text("Readings")
        }
    }

    /// The y-axis ceiling. Percentages are pinned to 100 so the line means the same thing from one
    /// glance to the next; rates have no natural maximum and scale to their own window.
    private func ceiling(for kind: MetricKind) -> Double {
        switch kind {
        case .cpu, .gpu, .memory, .battery:
            return 100
        case .disk, .network, .power:
            return max(1, feature.reading.history[kind]?.peak ?? 1)
        }
    }

    private func sparkline(for kind: MetricKind) -> some View {
        MetricSparkline(
            window: feature.reading.history[kind] ?? MetricHistory(),
            ceiling: ceiling(for: kind)
        )
        // The chart spans its card on a menu panel and sits inline beside the number here, so the
        // width belongs to the caller. 110 is what this row has always given it.
        .frame(width: 110)
    }

    private func value(for kind: MetricKind) -> String {
        let snapshot = feature.reading.snapshot
        switch kind {
        case .cpu:
            guard let cpu = snapshot.cpu else { return MetricFormatting.placeholder }
            return "\(MetricFormatting.percent(cpu.usage ?? nil)) · \(cpu.coreCount) cores"
        case .gpu:
            return MetricFormatting.percent(snapshot.gpu?.usage)
        case .memory:
            guard let memory = snapshot.memory else { return MetricFormatting.placeholder }
            return "\(MetricFormatting.bytes(memory.used)) of \(MetricFormatting.bytes(memory.total))"
        case .disk:
            guard let disk = snapshot.disk else { return MetricFormatting.placeholder }
            return "\(MetricFormatting.bytes(disk.used)) of \(MetricFormatting.bytes(disk.total))"
        case .network:
            let down = MetricFormatting.bytesPerSecond(snapshot.network?.downloadPerSecond)
            let up = MetricFormatting.bytesPerSecond(snapshot.network?.uploadPerSecond)
            return "\u{2193}\(down)  \u{2191}\(up)"
        case .battery:
            guard let battery = snapshot.battery, battery.isPresent else {
                return MetricFormatting.placeholder
            }
            let charge = MetricFormatting.percent(battery.percent)
            let remaining = MetricFormatting.duration(minutes: battery.minutesRemaining)
            return remaining == MetricFormatting.placeholder ? charge : "\(charge) · \(remaining)"
        case .power:
            guard let power = snapshot.power else { return MetricFormatting.placeholder }
            return MetricFormatting.watts(power.watts)
        }
    }

    // MARK: - Which metrics

    private var metricsSection: some View {
        Section {
            ForEach(MetricKind.allCases) { kind in
                Toggle(isOn: binding(for: kind)) {
                    Label(kind.title, systemImage: kind.symbolName)
                }
            }
        } header: {
            Text("Watch")
        } footer: {
            Text("A reading you switch off here is not sampled at all.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for kind: MetricKind) -> Binding<Bool> {
        Binding(
            get: { feature.enabledMetrics.contains(kind) },
            set: { isOn in
                var metrics = feature.enabledMetrics
                if isOn { metrics.insert(kind) } else { metrics.remove(kind) }
                feature.enabledMetrics = metrics
            }
        )
    }

    // MARK: - Menu bar and cadence

    private var menuBarSection: some View {
        Section {
            Toggle("Show live data in the menu bar", isOn: Binding(
                get: { feature.showsLiveDataInMenuBar },
                set: { feature.showsLiveDataInMenuBar = $0 }
            ))
            ForEach(MetricKind.allCases) { kind in
                if feature.enabledMetrics.contains(kind) {
                    Toggle(isOn: menuBarBinding(for: kind)) {
                        Label(kind.title, systemImage: kind.symbolName)
                    }
                }
            }
            Picker("Refresh", selection: Binding(
                get: { feature.interval },
                set: { feature.interval = $0 }
            )) {
                ForEach(MonitorInterval.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Menu Bar")
        } footer: {
            Text("""
                The readings appear beside the Sarvkrit icon. With live data off — or with none of \
                these chosen — the icon is left alone, and every reading is still there in the \
                Sarvkrit menu under System. Changing how often the monitor refreshes clears the \
                graphs, since a graph can only show one cadence at a time.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Preserves the order metrics were added in, so the menu bar readout is stable rather than
    /// jumping to declaration order the moment anything is toggled.
    private func menuBarBinding(for kind: MetricKind) -> Binding<Bool> {
        Binding(
            get: { feature.menuBarMetrics.contains(kind) },
            set: { isOn in
                var metrics = feature.menuBarMetrics
                if isOn {
                    if !metrics.contains(kind) { metrics.append(kind) }
                } else {
                    metrics.removeAll { $0 == kind }
                }
                feature.menuBarMetrics = metrics
            }
        )
    }
}
