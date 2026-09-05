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

    /// Which panel is showing, resolved from the persisted id on every read.
    ///
    /// Deliberately *not* mirrored into `@State`. Doing that meant the first frame drew whatever
    /// the state was initialised to and only jumped to the remembered panel once `onAppear` had
    /// run — a visible flash of the wrong panel each time the menu opened, and a half-updated
    /// frame in anything that photographs it. Resolving on read also means a panel disappearing
    /// underneath the selection needs no `onChange` to notice: `resolve` simply stops finding it
    /// and falls back.
    ///
    /// Writing straight through costs nothing. `AppState.selectedTrayTabID`'s setter is guarded,
    /// so a same-value write from a two-way binding publishes exactly zero times.
    private var selection: Binding<String> {
        Binding(
            get: { TrayPanel.resolve(storedID: app.selectedTrayTabID, available: panels) },
            set: { app.selectedTrayTabID = $0 }
        )
    }

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

            // Below the permission banners and above the strip, for the same reason those are
            // where they are: it's an app-level message, not something belonging to one panel.
            if case .available(let release) = app.updates.state {
                UpdateBanner(version: release.version?.description ?? release.tagName) {
                    MainWindowController.shared.show(selecting: SidebarItem.generalID)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TrayPanelStrip(panels: panels, selection: selection)

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
        // The panel opening is the trigger that matters most for the update check. Sarvkrit runs
        // as an accessory app, so opening this panel does not make it active and
        // `didBecomeActive` never fires — without this, someone who lives in the menu bar and
        // never opens the window would never see an update notice at all.
        //
        // Safe to sit in this chain: `refresh()` reads a file and publishes only when the answer
        // changes, so it adds no height of its own. See the warning immediately below.
        .onAppear { app.updates.refresh() }
        // **Nothing here may animate this panel's height.** The window animates; the content
        // does not. `MenuBarWindowAnchor` owns the one and `TopPinnedContentView` holds the other
        // still while it moves.
        //
        // There used to be a `.standardMotion` per height-bearing value, on the theory that the
        // anchor could follow the content through a SwiftUI animation. It does follow it, and
        // SwiftUI overwrites the result: SwiftUI sizes this window from the content's *settled*
        // height, so on a grow it jumps straight to the final height and re-asserts it on every
        // content change, while the anchor drags it back to whatever height the animation is at.
        // One instrumented Keyboard → Files switch, logged as `before -> after` window heights:
        //
        //     533 -> 338   533 -> 341   341 -> 341   533 -> 343   343 -> 343   533 -> 345  …
        //
        // Twenty-five of those inside 150ms and 195pt of travel on the bottom edge — two writers,
        // alternating, which is the panel "moving and resetting" as you change tabs. With the
        // animation moved to the window there is one writer and one animation.
        //
        // The strip still animates its own selection pill in `TrayPanelStrip`, on a view of fixed
        // height, so nothing there can move the panel's bottom edge.
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
        if let panel = panels.first(where: { $0.id == selection.wrappedValue }) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // The strip is icons only, so unlike the old labelled tabs it does not name what
                // you are looking at. This is the only thing that does — except on Features, which
                // is the one panel with headers of its own, and where this put FEATURES directly
                // above KEYBOARD in the same style forty points apart.
                if panel.id != TrayPanel.featuresID {
                    SectionHeader(panel.title)
                }
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
