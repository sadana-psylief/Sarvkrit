import SwiftUI

/// "Sarvkrit 1.1.0 is available", in the menu bar dropdown.
///
/// Accent-tinted rather than orange: `PermissionBanner` is a warning about something broken, this
/// is good news. Same shape and padding so the two never look like different apps.
///
/// The button opens the main window rather than doing anything itself, and that is a hard
/// constraint, not a preference: a sheet raised inside the `MenuBarExtra` panel dismisses as
/// focus moves, so there is nowhere in here to put a command the user needs to select and copy.
struct UpdateBanner: View {
    var version: String
    var onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Sarvkrit \(version) is available")
                    .font(.subheadline.weight(.semibold))
                Text("You're running \(Bundle.main.shortVersionString).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("How to update", action: onOpen)
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
        )
        .accessibilityElement(children: .contain)
    }
}

extension Bundle {
    /// The marketing version, which is what users recognise — About shows the build alongside it.
    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
