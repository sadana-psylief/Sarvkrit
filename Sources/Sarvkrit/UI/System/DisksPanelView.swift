import SwiftUI

/// One card per mounted volume: what it holds, how fast it is going, and how to get rid of it.
///
/// The volume list, not the boot disk alone, because "how full is my Mac" and "is my backup drive
/// still plugged in" are the same glance. Machinery volumes — Preboot, VM, the read-only system
/// snapshot, mounted disk images — are filtered out by `VolumeLister`, which asks the same question
/// Finder asks before putting something in its sidebar.
struct DisksPanelView: View {
    @ObservedObject var feature: SystemMonitorFeature

    /// Which volume failed to eject and why. The panel cannot show a dialog — a `MenuBarExtra`
    /// panel dismisses as focus moves — so the reason has to live on the card that offered the
    /// button. Keyed by volume, so ejecting a second disk doesn't inherit the first one's error.
    @State private var ejectFailures: [String: String] = [:]

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            if !isWatched {
                SettingsModule {
                    FootnoteRow(text: "Disk is switched off in Features",
                                symbolName: "internaldrive")
                }
            } else if volumes.isEmpty {
                SettingsModule {
                    FootnoteRow(text: "No volumes to show", symbolName: "internaldrive")
                }
            } else {
                ForEach(volumes) { volume in
                    card(for: volume)
                }
            }
        }
    }

    private var isWatched: Bool { feature.enabledMetrics.contains(.disk) }
    private var snapshot: SystemSnapshot { feature.reading.snapshot }
    private var volumes: [MountedVolume] { snapshot.disk?.volumes ?? [] }

    private func card(for volume: MountedVolume) -> some View {
        SettingsModule {
            header(for: volume)
            storage(for: volume)

            // Throughput is summed across every block-storage driver on the Mac, so it belongs to
            // the machine rather than to one volume. It goes on the internal card, once, rather
            // than being repeated on each — printing the same pair of numbers under every volume
            // would claim a per-volume measurement that isn't being taken.
            if volume.isInternal {
                ModuleSeparator()
                SplitStat(
                    leading: .init(symbolName: "arrow.down", tint: .blue,
                                   value: MetricFormatting.bytesPerSecond(
                                    snapshot.disk?.readPerSecond),
                                   caption: "Read"),
                    trailing: .init(symbolName: "arrow.up", tint: .green,
                                    value: MetricFormatting.bytesPerSecond(
                                        snapshot.disk?.writePerSecond),
                                    caption: "Write"))
            }

            if volume.isEjectable || ejectFailures[volume.id] != nil {
                ModuleSeparator()
                footer(for: volume)
            }
        }
    }

    private func header(for volume: MountedVolume) -> some View {
        HStack(spacing: Theme.Space.md) {
            FeatureIconTile(
                symbolName: volume.isEjectable ? "externaldrive" : "internaldrive", isOn: false)
            VStack(alignment: .leading, spacing: 0) {
                Text(volume.name)
                    .font(.system(size: Theme.Typography.title, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(for: volume))
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.sm)
            smartPill(for: volume)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .padding(.top, Theme.Space.sm)
    }

    private func subtitle(for volume: MountedVolume) -> String {
        let place = volume.isInternal ? "Internal" : "External"
        guard let format = volume.format else { return place }
        return "\(place) · \(format)"
    }

    /// Only where SMART was genuinely read, which today means the internal drive — see
    /// `SMARTReader` for why. A badge that appeared on everything and meant nothing on most of it
    /// would be worse than no badge.
    @ViewBuilder
    private func smartPill(for volume: MountedVolume) -> some View {
        if volume.isInternal, let smart = snapshot.disk?.smart {
            switch smart.status {
            case .ok: StatusPill(text: "SMART", tint: .green)
            case .failing: StatusPill(text: "SMART failing", tint: .red)
            case .unavailable: EmptyView()
            }
        }
    }

    private func storage(for volume: MountedVolume) -> some View {
        VStack(spacing: Theme.Space.xs) {
            MeterBar(value: volume.usagePercent, tint: tint(for: volume))
            HStack {
                Text("Storage")
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(MetricFormatting.bytes(volume.used)) / \(MetricFormatting.bytes(volume.total))")
                    .font(.system(size: Theme.Typography.body, weight: .medium))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .padding(.vertical, Theme.Space.sm)
        .accessibilityElement(children: .combine)
    }

    /// Turns orange past 90% full. Not a warning anyone configured — it is the point at which macOS
    /// itself starts struggling to find room, and the bar alone doesn't say so at a glance.
    private func tint(for volume: MountedVolume) -> Color {
        (volume.usagePercent ?? 0) >= 90 ? .orange : .accentColor
    }

    private func footer(for volume: MountedVolume) -> some View {
        HStack(spacing: Theme.Space.sm) {
            if let failure = ejectFailures[volume.id] {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else if let used = wearNote(for: volume) {
                Text(used)
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.sm)
            if volume.isEjectable {
                Button {
                    ejectFailures[volume.id] = VolumeLister.eject(volume)
                } label: {
                    Label("Eject", systemImage: "eject")
                        .font(.system(size: Theme.Typography.caption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .clickableCursor()
            }
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .padding(.vertical, Theme.Space.sm)
    }

    /// The drive's own estimate of how much of its rated write endurance is gone. Shown only once
    /// it is worth knowing — a drive at 0% or 1% is telling you nothing you need.
    private func wearNote(for volume: MountedVolume) -> String? {
        guard volume.isInternal, let used = snapshot.disk?.smart?.percentageUsed, used >= 5
        else { return nil }
        return "\(used)% of rated write life used"
    }
}
