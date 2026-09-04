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
                LabeledContent("Also save to") {
                    HStack(spacing: Theme.Space.sm) {
                        Text(feature.exportFolder?.lastPathComponent ?? "Nowhere")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                        if feature.exportFolderPath != nil {
                            Button("Clear") { feature.exportFolderPath = nil }
                        }
                    }
                }
                if feature.exportFolderPath != nil {
                    TextField("Name", text: Binding(
                        get: { feature.filenamePattern },
                        set: { feature.filenamePattern = $0 }))
                    Text(CaptureFilename.make(pattern: feature.filenamePattern,
                                              mode: .area, date: Date()) + ".png")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Where captures go")
            } footer: {
                Text("""
                    Captures are always kept in Sarvkrit's own history. A folder here gets a \
                    second, readable copy. Tokens: \(CaptureFilename.tokens.joined(separator: ", ")).
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
                        Text("Stays until I dismiss it").tag(0.0)
                        Text("4 seconds").tag(4.0)
                        Text("8 seconds").tag(8.0)
                        Text("15 seconds").tag(15.0)
                    }
                }
            } header: {
                Text("Capture overlay")
            } footer: {
                Text("""
                    The thumbnail that appears after a capture. Drag it straight into another \
                    app, or hover it to copy, annotate or pin. It stays put until you deal with \
                    it — ⌃⇧Z brings back the last one you dismissed, ⌃⇧H hides them all until the \
                    next capture.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Choose windows from a list", isOn: Binding(
                    get: { feature.choosesWindowFromList },
                    set: { feature.choosesWindowFromList = $0 }))
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
                    A list reaches a window that is behind something else and can be driven from \
                    the keyboard; leave it off to point at the window you can already see.

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

            Section {
                Text("""
                    ⌃⇧S draws an area, then captures it each time you pause while scrolling, and \
                    stitches the frames into one tall image. Scroll slowly and in one direction. \
                    It needs no extra permission — Sarvkrit watches your scrolling rather than \
                    doing the scrolling for you.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                    Vertical scrolling is what this is tested against. A full-width sticky header \
                    or footer is detected and written once; a floating button that sits in the \
                    middle of a row will repeat.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Scrolling capture")
            }

            CaptureShortcutsSection(feature: feature, shortcuts: feature.shortcuts)
            CaptureAutomationSection()

            Section {
                Button("Browse Captures…") {
                    CaptureHistoryWindowController.shared.show()
                }
                if store.items.count > 1 {
                    Button("Combine the Last Two…") {
                        let recent = Array(store.items.prefix(2)).reversed()
                        let images = recent.compactMap { item -> CGImage? in
                            guard let data = try? Data(contentsOf: store.url(for: item)) else {
                                return nil
                            }
                            return CaptureDocumentFile.image(from: data)
                        }
                        guard images.count == 2 else { return }
                        ScreenshotEditorController.shared.open(combining: images)
                    }
                }
            } footer: {
                Text("""
                    ⌃⇧Y opens the browser: everything you have captured, grouped by when, with \
                    each one draggable straight into another app.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .navigationTitle(feature.title)
    }

    /// The app is not sandboxed, so a plain path is enough — no security-scoped bookmark needed.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Where should Sarvkrit also save screenshots?"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        feature.exportFolderPath = url.path
    }
}

/// Recent captures, newest first.
