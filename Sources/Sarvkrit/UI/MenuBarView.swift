import SwiftUI

/// The dropdown: a tab per feature category, then the selected category's toggles.
///
/// A real SwiftUI window (`.menuBarExtraStyle(.window)`) rather than an `NSMenu`, because `NSMenu`
/// can't host live switches.
struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    /// Explicit observation of the Keep Awake feature, for the same reason `MenuBarLabel` needs it.
    @ObservedObject var keepAwakeFeature: KeepAwakeFeature

    /// Mirrors the persisted selection. Held locally so switching tabs is instant, and written back
    /// to `AppState` — whose guarded setter makes a same-value write genuinely free.
    @State private var selection: TrayTab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header

            // Above the tabs on purpose: this reports an app-level condition, and burying it inside
            // one tab would mean the user can't see why a feature isn't working unless they happen
            // to be looking at the right one.
            // One banner per missing grant, in a stable order: two features can be blocked by two
            // different permissions at once, and a single banner would have to pick one to lie about.
            ForEach(app.unmetRequirementsInOrder, id: \.self) { requirement in
                PermissionBanner(requirement: requirement) {
                    app.permissions.openSystemSettings(for: requirement)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TrayTabBar(tabs: app.trayTabs, selection: $selection)

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
        // Grow and shrink the panel rather than snapping it — Keyboard is one row, Files is three.
        //
        // This used to be unsafe, and the comment here used to say so: a height change would leave
        // the panel floating away from the menu bar, and animating walked it through many
        // intermediate heights. The measured reason turned out to be that SwiftUI does not resize
        // this window on a *shrink* at all — it keeps the tallest height of the presentation and
        // centres the smaller content inside it. `MenuBarWindowAnchor` now does that resize, on
        // every height change including each frame of an animated one.
        .standardMotion(value: selection)
        .standardMotion(value: app.unmetRequirementsInOrder)
        .onAppear {
            selection = TrayTab.resolve(storedID: app.selectedTrayTabID, available: app.trayTabs)
        }
        .onChange(of: selection) { _, new in app.selectedTrayTabID = new.id }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selection {
        case .category(let category):
            // No SectionHeader here: the selected tab already names the group, and repeating it
            // would be the same label twice in 40 points of vertical space.
            SettingsModule {
                let features = app.features(in: category)
                ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { ModuleSeparator() }
                    FeatureRow(
                        feature: feature,
                        isOn: app.binding(for: feature),
                        isBlocked: app.isBlocked(feature)
                    )
                    // Some features are operated from the tray rather than merely switched on
                    // there — picking an output device, say. Only while enabled: controls for a
                    // feature that is off would do nothing.
                    if app.isEnabled(feature), !app.isBlocked(feature),
                       let tray = feature.makeTrayView() {
                        tray
                    }
                }
            }
        case .general:
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
    }

    /// Observed directly, not through `AppState` — nested `ObservableObject` changes don't
    /// propagate, so the status line would otherwise only update on an unrelated redraw.
    private var keepAwake: KeepAwakeFeature? { keepAwakeFeature }

    private var header: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Sarvkrit")
                .font(.system(size: 13, weight: .semibold))
            if let keepAwake, let status = MenuBarIconState.statusLine(
                state: keepAwake.iconState, remaining: keepAwake.remainingTime) {
                // Says why the Mac isn't sleeping, right where you'd look for it.
                Label(status, systemImage: keepAwake.iconState.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .labelStyle(.titleAndIcon)
            }
            Spacer()
            Button { openMainWindow() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
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
