import SwiftUI

/// What ⌘/ shows.
///
/// **⌘/ was routed to `break`.** So the editor's keyboard shortcuts — including the only way to add
/// a zoom by hand short of an unlabelled glyph in the transport bar — had no way of being found, and
/// were reported as not existing. Fair: a shortcut nobody can find does not exist.
///
/// The list itself lives in `StudioShortcuts` as data, and a test checks every entry against
/// `StudioKeyRouting`, so this can never promise a key that does nothing.
struct StudioShortcutsSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.system(size: Theme.Typography.title, weight: .semibold))
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(StudioShortcuts.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.name.uppercased())
                                .font(.system(size: Theme.Typography.caption, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.entries) { entry in
                                row(entry)
                            }
                        }
                    }

                    // Said here because the timeline is where people look for it and did not find
                    // it: clicks, pointer highlights, blurs and the camera are all placed from the
                    // timeline's own menu.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RIGHT-CLICK THE TIMELINE")
                            .font(.system(size: Theme.Typography.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Everything that happens at a moment — a zoom, a click, a pointer "
                             + "highlight, a blur, the camera going full-frame — is placed from "
                             + "there, at the point you clicked.")
                            .font(.system(size: Theme.Typography.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 520)
    }

    private func row(_ entry: StudioShortcuts.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.keyLabel)
                .font(.system(size: Theme.Typography.body, weight: .medium, design: .rounded))
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(entry.isUnavailable ? .tertiary : .primary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: Theme.Typography.body))
                        .foregroundStyle(entry.isUnavailable ? .secondary : .primary)
                    if entry.isUnavailable {
                        Text("not built yet")
                            .font(.system(size: Theme.Typography.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let note = entry.note {
                    Text(note)
                        .font(.system(size: Theme.Typography.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
