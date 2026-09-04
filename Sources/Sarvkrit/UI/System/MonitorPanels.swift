import SwiftUI

// The system monitor's four panels.
//
// One view was seven rows of "name … number", which is what fits *underneath* a switch and not what
// anyone opens a menu to look at. Split four ways because a 420pt window holds one card comfortably
// and four badly, and grouped the way the readings are actually used: what the machine is doing,
// what the network is doing, what the disk holds, and where the power is going.
//
// A metric the user has switched off renders dimmed with a dash rather than disappearing. That rule
// predates these panels and is the honest one: a missing row implies a reading that doesn't exist,
// where a dash says it isn't being taken. Every panel is present whenever the monitor is on, for a
// mechanical reason as well as a design one — which metrics are enabled is state inside
// `SystemMonitorFeature`, and SwiftUI does not observe through a nested `ObservableObject`, so a
// strip that hid tabs per metric would go stale the moment one was toggled in the window.

/// Shared plumbing: every panel observes the feature directly, never through `AppState`.
private protocol MonitorPanel: View {
    var feature: SystemMonitorFeature { get }
}

extension MonitorPanel {
    var snapshot: SystemSnapshot { feature.reading.snapshot }

    func isWatched(_ kind: MetricKind) -> Bool { feature.enabledMetrics.contains(kind) }

    func history(_ kind: MetricKind) -> MetricHistory {
        feature.reading.history[kind] ?? MetricHistory()
    }

    /// A percentage chart always runs 0–100 so the line means the same thing at every glance; a
    /// rate has no natural ceiling and scales to its own peak.
    func ceiling(_ kind: MetricKind) -> Double {
        switch kind {
        case .cpu, .gpu, .memory, .battery: return 100
        case .disk, .network, .power: return max(1, history(kind).peak ?? 1)
        }
    }

    @ViewBuilder
    func chart(_ kind: MetricKind, tint: Color) -> some View {
        if isWatched(kind) {
            MetricSparkline(window: history(kind), ceiling: ceiling(kind), tint: tint)
                .padding(.horizontal, Theme.Metrics.rowInset)
                .padding(.bottom, Theme.Space.sm)
        }
    }
}

// MARK: - System

/// Temperatures, then what the chips and the memory are doing.
struct SystemPanelView: View, MonitorPanel {
    @ObservedObject var feature: SystemMonitorFeature

    /// Uptime moves once a minute and the snapshot never carries it; without a tick of its own the
    /// line would show whatever it said when the panel was built.
    @State private var uptime = UptimeFormatting.current()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                StatTile(label: "CPU", value: temperature(snapshot.cpu?.celsius),
                         symbolName: "cpu")
                StatTile(label: "GPU", value: temperature(snapshot.gpu?.celsius),
                         symbolName: "display")
                StatTile(label: "Battery", value: temperature(snapshot.battery?.celsius),
                         symbolName: "battery.100")
            }

            SettingsModule {
                StatRow(title: "CPU", value: MetricFormatting.percent(cpuUsage),
                        symbolName: "cpu", meter: cpuUsage,
                        isMuted: !isWatched(.cpu))
                chart(.cpu, tint: .accentColor)

                ModuleSeparator()
                StatRow(title: "GPU", value: MetricFormatting.percent(snapshot.gpu?.usage),
                        symbolName: "display", meter: snapshot.gpu?.usage, tint: .blue,
                        isMuted: !isWatched(.gpu))
                chart(.gpu, tint: .blue)

                ModuleSeparator()
                memoryRow
                chart(.memory, tint: .teal)

                ModuleSeparator()
                FootnoteRow(text: "Up for \(uptime)", symbolName: "clock")
            }
        }
        .onReceive(tick) { _ in uptime = UptimeFormatting.current() }
    }

    private var cpuUsage: Double? { snapshot.cpu?.usage }

    /// Memory leads with pressure rather than the percentage. A Mac at 90% used under normal
    /// pressure is behaving correctly — macOS fills spare RAM with cache and hands it back — and
    /// the bare percentage reliably alarms people about exactly that case.
    private var memoryRow: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: "memorychip")
                .font(.system(size: Theme.Typography.body))
                .foregroundStyle(isWatched(.memory) ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(.tertiary))
                .frame(width: Theme.Metrics.iconColumn, alignment: .center)
            Text("Memory")
                .font(.system(size: Theme.Typography.body))
                .foregroundStyle(isWatched(.memory) ? AnyShapeStyle(.primary)
                                                    : AnyShapeStyle(.tertiary))
            if let pressure = snapshot.memory?.pressure, isWatched(.memory) {
                StatusPill(text: pressure.title, tint: tint(for: pressure))
            }
            Spacer(minLength: Theme.Space.sm)
            Text(memoryValue)
                .font(.system(size: Theme.Typography.body, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isWatched(.memory) ? AnyShapeStyle(.primary)
                                                    : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.panelRowHeight)
        .accessibilityElement(children: .combine)
    }

    private func tint(for pressure: MemoryPressure) -> Color {
        switch pressure {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var memoryValue: String {
        guard isWatched(.memory), let memory = snapshot.memory else {
            return MetricFormatting.placeholder
        }
        return "\(MetricFormatting.bytes(memory.used)) / \(MetricFormatting.bytes(memory.total))"
    }

    /// Whole degrees. A tenth of a degree on a die sensor is noise, and it makes the number
    /// change width as it crosses ten.
    private func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return MetricFormatting.placeholder }
        return "\(Int(celsius.rounded())) °C"
    }
}

// MARK: - Network

struct NetworkPanelView: View, MonitorPanel {
    @ObservedObject var feature: SystemMonitorFeature

    var body: some View {
        SettingsModule {
            SplitStat(
                leading: .init(symbolName: "arrow.down", tint: .blue,
                               value: MetricFormatting.bytesPerSecond(download),
                               caption: "Download"),
                trailing: .init(symbolName: "arrow.up", tint: .green,
                                value: MetricFormatting.bytesPerSecond(upload),
                                caption: "Upload"))

            chart(.network, tint: .blue)

            ModuleSeparator()
            FootnoteRow(text: "This session") {
                Text(sessionTotals)
                    .font(.system(size: Theme.Typography.caption))
                    .monospacedDigit()
            }
        }
    }

    private var download: Double? {
        isWatched(.network) ? snapshot.network?.downloadPerSecond : nil
    }

    private var upload: Double? {
        isWatched(.network) ? snapshot.network?.uploadPerSecond : nil
    }

    private var sessionTotals: String {
        guard isWatched(.network), let network = snapshot.network else {
            return MetricFormatting.placeholder
        }
        return "↓\(MetricFormatting.bytes(network.sessionDownloaded))"
            + "  ↑\(MetricFormatting.bytes(network.sessionUploaded))"
    }
}

// MARK: - Power

struct PowerPanelView: View, MonitorPanel {
    @ObservedObject var feature: SystemMonitorFeature

    var body: some View {
        SettingsModule {
            StatRow(title: "System", value: MetricFormatting.watts(watts),
                    symbolName: "bolt.fill", meter: watts.map(abs), ceiling: wattCeiling,
                    tint: .orange, isMuted: !isWatched(.power))
            chart(.power, tint: .orange)

            ModuleSeparator()
            adapterRow

            ModuleSeparator()
            batteryRow

            ModuleSeparator()
            healthRow
        }
    }

    private var watts: Double? { isWatched(.power) ? snapshot.power?.watts : nil }

    /// Scaled to the adapter's rating where there is one, so the meter means "how much of what this
    /// charger can supply". With no adapter there is no such reference and it falls back to the
    /// window's own peak.
    private var wattCeiling: Double {
        if let rated = snapshot.power?.adapterWatts, rated > 0 { return Double(rated) }
        return max(1, history(.power).peak ?? 1)
    }

    private var adapterRow: some View {
        FootnoteRow(text: adapterText, symbolName: "powerplug") {
            Text(snapshot.power?.adapterWatts.map { "\($0) W" } ?? MetricFormatting.placeholder)
                .font(.system(size: Theme.Typography.body, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private var adapterText: String {
        guard isWatched(.power) else { return "Adapter" }
        return snapshot.power?.adapterWatts == nil ? "Adapter — not connected" : "Adapter"
    }

    private var batteryRow: some View {
        StatRow(title: "Battery",
                value: isWatched(.battery) ? MetricFormatting.percent(batteryPercent)
                                           : MetricFormatting.placeholder,
                symbolName: batterySymbol,
                meter: batteryPercent, tint: .green,
                isMuted: !isWatched(.battery))
    }

    private var batteryPercent: Double? {
        guard isWatched(.battery), let battery = snapshot.battery, battery.isPresent
        else { return nil }
        return battery.percent
    }

    private var batterySymbol: String {
        (snapshot.battery?.isCharging ?? false) ? "battery.100.bolt" : "battery.100"
    }

    /// Health and cycles share a line: neither changes while you are looking at it, and each is
    /// only interesting beside the other.
    private var healthRow: some View {
        FootnoteRow(text: cycles, symbolName: "heart") {
            Text(health)
                .font(.system(size: Theme.Typography.body, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }

    private var cycles: String {
        guard isWatched(.battery), let count = snapshot.battery?.cycleCount else {
            return "Battery health"
        }
        return "Battery health · \(count) cycles"
    }

    private var health: String {
        guard isWatched(.battery), let percent = snapshot.battery?.healthPercent else {
            return MetricFormatting.placeholder
        }
        return "\(Int(percent.rounded()))%"
    }
}
