import SwiftUI

/// Where one app's audio goes: the system output, or a device of its own.
///
/// Shared by the tray row, where it is a speaker icon, and the Settings pane, where it reads as the
/// device's name. A route to a device that isn't connected stays selected and says so, because the
/// app will move back to it on its own when it returns — offering it as if it were gone would
/// suggest the setting had been lost.
struct MixerOutputMenu: View {
    @ObservedObject var feature: VolumeMixerFeature
    let bundleID: String
    let appName: String
    var compact = false

    var body: some View {
        let route = feature.route(for: bundleID)
        let available = feature.isRouteAvailable(for: bundleID)

        Menu {
            Button {
                feature.setOutput(nil, for: bundleID)
            } label: {
                check("System Output", selected: route == nil)
            }
            Divider()
            ForEach(feature.outputDevices) { device in
                Button {
                    feature.setOutput(device, for: bundleID)
                } label: {
                    check(device.name, selected: route?.uid == device.uid)
                }
            }
            if let route, !available {
                Button {} label: { check("\(route.name) (not connected)", selected: true) }
                    .disabled(true)
            }
        } label: {
            if compact {
                Image(systemName: route == nil ? "hifispeaker" : "hifispeaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(route == nil ? AnyShapeStyle(.secondary)
                                                  : AnyShapeStyle(Color.accentColor))
                    .frame(width: 18)
            } else {
                Text(title(route: route, available: available))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(compact ? .hidden : .visible)
        .fixedSize()
        .clickableCursor()
        .help(title(route: route, available: available))
        .accessibilityLabel("Output for \(appName): \(title(route: route, available: available))")
    }

    private func title(route: MixerRoutes.Route?, available: Bool) -> String {
        guard let route else { return "System Output" }
        return available ? route.name : "\(route.name) (not connected)"
    }

    @ViewBuilder
    private func check(_ text: String, selected: Bool) -> some View {
        if selected {
            Label(text, systemImage: "checkmark")
        } else {
            Text(text)
        }
    }
}
