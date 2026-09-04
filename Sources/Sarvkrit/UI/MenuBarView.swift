import SwiftUI

/// The dropdown: an icon strip of panels, then the selected panel.
///
/// A real SwiftUI window (`.menuBarExtraStyle(.window)`) rather than an `NSMenu`, because `NSMenu`
/// can't host live switches.
///
/// The panel used to be a switchboard — a tab per feature category, each holding that category's
/// switches, with live content tucked underneath whichever switch turned it on. It is a dashboard
/// now: a tab per *screen*, leading with what the feature actually shows. The switches all still
/// exist, in the Features panel; see `TrayPanel` for why the unit changed.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    /// Explicit observation of the Keep Awake feature, for the same reason `MenuBarLabel` needs it.
    @ObservedObject var keepAwakeFeature: KeepAwakeFeature

    /// Mirrors the persisted selection. Held locally so switching panels is instant, and written
    /// back to `AppState` — whose guarded setter makes a same-value write genuinely free.
    @State private var selection: String = TrayPanel.generalID

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header

            // Above the strip on purpose: this reports an app-level condition, and burying it
            // inside one panel would mean the user can't see why a feature isn't working unless
            // they happen to be looking at the right one.
            // One banner per missing grant, in a stable order: two features can be blocked by two
            // different permissions at once, and a single banner would have to pick one to lie about.
            ForEach(app.unmetRequirementsInOrder, id: \.self) { requirement in
                PermissionBanner(requirement: requirement) {
                    app.permissions.request(requirement)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TrayPanelStrip(panels: panels, selection: $selection)

            selectedContent

            VStack(spacing: 2) {
                if let shelf, app.isEnabled(shelf) {
                    MenuActionRow(title: "Open Shelf", shortcut: "⌃⌥S") { openShelf() }
                }
                MenuActionRow(title: "Open Sarvkrit…", shortcut: "⌘,") { openMainWindow() }
                MenuActionRow(title: "Quit Sarvkrit", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
        }
        .padding(Theme.Space.md)
        .frame(width: Theme.Size.dropdownWidth)
        // Reaches the panel's own NSWindow, which `MenuBarExtra` does not hand out. A background,
        // so it takes the panel's size without contributing any of its own.
        .background(
            MenuBarWindowProbe(
                onWindow: { MenuBarWindowAnchor.shared.attach(to: $0) },
                onHeight: { MenuBarWindowAnchor.shared.note(contentHeight: $0) }
            )
        )
        // Grow and shrink the panel rather than snapping it — Keep Awake is two rows, System is a
        // dozen.
        //
        // This used to be unsafe, and the comment here used to say so: a height change would leave
        // the panel floating away from the menu bar, and animating walked it through many
        // intermediate heights. The measured reason turned out to be that SwiftUI does not resize
        // this window on a *shrink* at all — it keeps the tallest height of the presentation and
        // centres the smaller content inside it. `MenuBarWindowAnchor` now does that resize, on
        // every height change including each frame of an animated one.
        .standardMotion(value: selection)
        .standardMotion(value: app.unmetRequirementsInOrder)
        .onAppear { resolveSelection() }
        // The strip is no longer fixed: switching a feature off in the Features panel removes its
        // panel while you are standing on it. Without this you'd be left on a tab that no longer
        // exists, looking at nothing.
        .onChange(of: panels.map(\.id)) { _, _ in resolveSelection() }
        .onChange(of: selection) { _, new in app.selectedTrayTabID = new }
    }

    /// The whole strip. Features and General are built here rather than in `AppState` because they
    /// have no feature behind them and their content is a view, which Core has no business owning.
    private var panels: [TrayPanel] {
        TrayPanel.strip(
            contributed: app.contributedTrayPanels,
            features: TrayPanel(
                id: TrayPanel.featuresID,
                title: "Features",
                symbolName: "switch.2"
            ) {
                FeaturesPanelView()
            },
            general: TrayPanel(
                id: TrayPanel.generalID,
                title: "General",
                symbolName: "gearshape"
            ) {
                generalPanel
            }
        )
    }

    @ViewBuilder
    private var selectedContent: some View {
        if let panel = panels.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // The strip is icons only, so unlike the old labelled tabs it does not name what
                // you are looking at. This is the only thing that does.
                SectionHeader(panel.title)
                panel.content()
            }
        }
    }

    private var generalPanel: some View {
        SettingsModule {
            SettingsRow(
                symbolName: "power",
                title: "Launch at Login",
                // Every toggle row carries a caption, which is what keeps one row height
                // uniform across every module.
                caption: "Start Sarvkrit when you log in",
                isHighlighted: app.launchAtLogin
            ) {
                Toggle("", isOn: $app.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            // "Show Menu Bar Icon" deliberately stays in the main window only: switching it off
            // from in here would delete the panel you're standing in, and the window's version
            // has a confirmation explaining how to get back. A confirmation sheet inside a
            // MenuBarExtra panel doesn't work — the panel dismisses as focus moves.
        }
    }

    private func resolveSelection() {
        let resolved = TrayPanel.resolve(storedID: app.selectedTrayTabID, available: panels)
        // Guarded, because this runs on every strip change and an unguarded write would push a
        // same-value selection back through `onChange` on each one.
        if selection != resolved { selection = resolved }
    }

    /// Observed directly, not through `AppState` — nested `ObservableObject` changes don't
    /// propagate, so the status line would otherwise only update on an unrelated redraw.
    private var keepAwake: KeepAwakeFeature? { keepAwakeFeature }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Sarvkrit")
                .font(.system(size: Theme.Typography.title, weight: .semibold))
            if let keepAwake, let status = MenuBarIconState.statusLine(
                state: keepAwake.iconState, remaining: keepAwake.remainingTime) {
                // Says why the Mac isn't sleeping, right where you'd look for it.
                Label(status, systemImage: keepAwake.iconState.symbolName)
                    .font(.system(size: Theme.Typography.section, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Button { openMainWindow() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: Theme.Typography.title))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .clickableCursor()
            .accessibilityLabel("Open Sarvkrit settings")
        }
        .padding(.horizontal, Theme.Space.xs)
    }

    /// Only shown when the Shelf is switched on — a menu entry for a feature that is off would do
    /// nothing.
    private var shelf: ShelfFeature? {
        app.features.compactMap { $0 as? ShelfFeature }.first
    }

    private func openShelf() {
        ShelfController.shared.show()
    }

    private func openMainWindow() {
        MainWindowController.shared.show()
    }
}
