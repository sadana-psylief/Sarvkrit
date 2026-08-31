import CoreAudio
import SwiftUI

/// The device list shown under the feature's row in the tray.
///
/// A `SettingsRow` can't express this — it has a fixed 52pt height and a 40pt trailing column sized
/// for a switch — so this is a sibling row type inside the same `SettingsModule`, keeping the
/// standard row inset so `ModuleSeparator`'s hairlines still line up.
struct AudioDeviceTrayView: View {
    @ObservedObject var feature: OutputSwitcherFeature

    var body: some View {
        VStack(spacing: 0) {
            ForEach(AudioDevice.Kind.allCases) { kind in
                let devices = feature.selectable(kind)
                if !devices.isEmpty {
                    ModuleSeparator()
                    header(for: kind)
                    ForEach(devices) { device in
                        row(device, kind: kind)
                    }
                }
            }
        }
    }

    private func header(for kind: AudioDevice.Kind) -> some View {
        HStack {
            Text(kind.title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .kerning(0.4)
            Spacer()
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .padding(.top, Theme.Space.sm)
        .padding(.bottom, 2)
    }

    private func row(_ device: AudioDevice, kind: AudioDevice.Kind) -> some View {
        let isCurrent = feature.current(kind) == device.id
        return Button {
            feature.select(device, kind: kind)
        } label: {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 12)
                Text(device.name)
                    .font(.system(size: 12, weight: isCurrent ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if feature.preferredUID(for: kind) == device.uid {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .help("Switches to this automatically when it's connected")
                }
            }
            .padding(.horizontal, Theme.Metrics.rowInset)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickableCursor()
        .accessibilityLabel(device.name)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
