import AppKit
import SwiftUI

/// The Screenshots pane: the toggle, the destination settings, and the capture history.
///
/// History lives inside this feature's pane rather than being a feature of its own, the same way
/// clipboard history lives inside Clipboard — a top-level switch for "remember what I captured"
/// would be a switch for something that only means anything while capturing is on.
struct ScreenshotDetailView: View {
    @ObservedObject var feature: ScreenshotFeature
    @ObservedObject var store: CaptureHistoryStore
    @EnvironmentObject private var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Screenshots", isOn: app.binding(for: feature))
            } footer: {
                Text("""
                    Capture an area, a window or the whole screen. The screen freezes while you \
                    choose, so menus and tooltips stay put instead of vanishing when you click.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Save to my capture folder", isOn: Binding(
                    get: { feature.savesToDisk }, set: { feature.savesToDisk = $0 }))
                Toggle("Also copy to the clipboard", isOn: Binding(
                    get: { feature.copiesToClipboard }, set: { feature.copiesToClipboard = $0 }))
            } header: {
                Text("After a capture")
            } footer: {
                Text("""
                    With both switched off, captures still go to the clipboard — a shortcut that \
                    appears to do nothing is worse than one that does something unexpected.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Self-timer", selection: Binding(
                    get: { feature.selfTimerSeconds },
                    set: { feature.selfTimerSeconds = $0 })) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
            } header: {
                Text("All-In-One")
            } footer: {
                Text("""
                    ⌃⇧5 opens a picker with every mode, remembering what you chose last so a \
                    retake is one keypress. With a timer set you choose the area first and the \
                    countdown is yours to arrange the screen in — the shot is taken live at the \
                    end, not frozen at the start.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show crosshair", isOn: Binding(
                    get: { feature.showsCrosshair }, set: { feature.showsCrosshair = $0 }))
                Toggle("Show magnifier", isOn: Binding(
                    get: { feature.showsMagnifier }, set: { feature.showsMagnifier = $0 }))
                Toggle("Show dimensions", isOn: Binding(
                    get: { feature.showsDimensions }, set: { feature.showsDimensions = $0 }))
                Toggle("Hide desktop icons", isOn: Binding(
                    get: { feature.hidesDesktopIcons }, set: { feature.hidesDesktopIcons = $0 }))
            } header: {
                Text("While choosing")
            } footer: {
                Text("""
                    The magnifier reads pixels out of the frozen screen, so it costs nothing to \
                    leave on. Desktop icons are left out of the capture itself rather than being \
                    switched off in Finder, so nothing is disturbed if a capture is cancelled.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the capture overlay", isOn: Binding(
                    get: { feature.showsQuickAccess }, set: { feature.showsQuickAccess = $0 }))
                if feature.showsQuickAccess {
                    Picker("Corner", selection: Binding(
                        get: { feature.quickAccessCorner },
                        set: { feature.quickAccessCorner = $0 })) {
                        ForEach(QuickAccessPlacement.Corner.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Close after", selection: Binding(
                        get: { feature.quickAccessAutoCloseSeconds },
                        set: { feature.quickAccessAutoCloseSeconds = $0 })) {
                        Text("4 seconds").tag(4.0)
                        Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0)
                        Text("Never").tag(0.0)
                    }
                }
            } header: {
                Text("Capture overlay")
            } footer: {
                Text("""
                    The thumbnail that appears after a capture. Drag it straight into another app, \
                    or leave the pointer on it to stop the countdown. ⌃⇧Z brings back the last one \
                    you dismissed; ⌃⇧H hides them until the next capture.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keep the window's shadow", isOn: Binding(
                    get: { feature.includesWindowShadow },
                    set: { feature.includesWindowShadow = $0 }))
                Toggle("Transparent background", isOn: Binding(
                    get: { feature.transparentWindowBackground },
                    set: { feature.transparentWindowBackground = $0 }))
            } header: {
                Text("Window captures")
            } footer: {
                Text("""
                    A window capture is taken on its own rather than cut out of the screen, so the \
                    corners can be genuinely transparent instead of showing whatever was behind it.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep captures for", selection: Binding(
                    get: { store.retention }, set: { store.retention = $0 })) {
                    ForEach(CaptureRetention.Window.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Captured") {
                    Text(store.items.isEmpty ? "Nothing yet" : "\(store.items.count)")
                        .foregroundStyle(.secondary)
                }
                if !store.items.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [store.url(for: store.items[0])])
                    }
                    Button("Delete All Captures", role: .destructive) { store.clear() }
                }
            } header: {
                Text("History")
            }

            CaptureShortcutsSection(feature: feature, shortcuts: feature.shortcuts)

            if !store.items.isEmpty {
                Section {
                    CaptureHistoryStrip(store: store)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
    }
}

/// Recent captures, newest first.
struct CaptureHistoryStrip: View {
    @ObservedObject var store: CaptureHistoryStore
    @State private var filter: CaptureMode?

    private var visible: [CaptureHistoryItem] {
        guard let filter else { return store.items }
        return store.items.filter { $0.mode == filter }
    }

    /// Only the modes actually present. Offering a filter that can only ever return nothing is a
    /// dead end the user has to discover by trying it.
    private var availableModes: [CaptureMode] {
        CaptureMode.allCases.filter { mode in store.items.contains { $0.mode == mode } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if availableModes.count > 1 {
                Picker("Show", selection: $filter) {
                    Text("All").tag(CaptureMode?.none)
                    ForEach(availableModes, id: \.self) { Text($0.title).tag(CaptureMode?.some($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.sm) {
                    ForEach(visible) { item in
                        CaptureHistoryTile(store: store, item: item)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct CaptureHistoryTile: View {
    @ObservedObject var store: CaptureHistoryStore
    let item: CaptureHistoryItem
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail = store.thumbnail(for: item, height: 72) {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        // A capture whose file has gone: greyed rather than blank, so it reads as
                        // "this is missing" instead of "this is still loading".
                        Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 72)
                .frame(minWidth: 72)
                .background(.quaternary.opacity(0.4),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))

                if isHovering {
                    Button {
                        store.remove(id: item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .clickableCursor()
                    .help("Delete this capture")
                }
            }

            Text(item.dimensionText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(store.url(for: item))
        }
        .help("\(item.mode.title) · \(item.dimensionText)")
    }
}
