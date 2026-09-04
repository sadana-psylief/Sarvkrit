import SwiftUI

/// One tab in the menu bar panel, and the content behind it.
///
/// A *panel*, not a category. The tabs used to be `FeatureCategory` — one per group of features,
/// with the group's switches behind it — which worked while the panel was a switchboard. It stops
/// working the moment a tab has to show live data: System alone would carry Keep Awake, Displays
/// and all seven monitor readings, some 700pt of content in a 420pt window.
///
/// So the unit is the screen rather than the group. One feature can contribute several — System
/// Monitor supplies System, Network, Disks and Power — and several features can contribute to one,
/// which is what `merged(_:)` is for.
struct TrayPanel: Identifiable {
    /// Persisted as the remembered selection, so it is a stable string rather than a case: a panel
    /// that stops existing fails to resolve and falls back, instead of persisting a dangling case.
    let id: String
    /// Shown in the tooltip and read by VoiceOver. The tabs are icon-only, so this is the only
    /// place the name appears — load-bearing, not decoration.
    let title: String
    let symbolName: String
    let content: () -> AnyView

    init(
        id: String,
        title: String,
        symbolName: String,
        @ViewBuilder content: @escaping () -> some View
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.content = { AnyView(content()) }
    }
}

extension TrayPanel {
    /// The two panels the app always shows, whatever is switched on.
    static let featuresID = "features"
    static let generalID = "general"

    /// Collapses panels that share an id into one, stacking their content in the order given.
    ///
    /// The five Sound features are one screen, not five: the mixer, the output switcher and the
    /// microphone controls all declare `id: "sound"`, and the tab appears when *any* of them is on
    /// holding only the parts that are. First title and symbol win, so the panel is named by the
    /// earliest contributor in `FeatureRegistry.makeAll()` order rather than by whichever feature
    /// happened to be switched on last.
    ///
    /// Order is otherwise preserved exactly: a merged panel sits where its *first* contributor sat,
    /// not where its last one did, so switching a feature on can never reshuffle the strip.
    static func merged(_ panels: [TrayPanel]) -> [TrayPanel] {
        var order: [String] = []
        var grouped: [String: [TrayPanel]] = [:]

        for panel in panels {
            if grouped[panel.id] == nil { order.append(panel.id) }
            grouped[panel.id, default: []].append(panel)
        }

        return order.map { id in
            let group = grouped[id]!
            guard let first = group.first, group.count > 1 else { return group[0] }
            return TrayPanel(id: id, title: first.title, symbolName: first.symbolName) {
                VStack(spacing: Theme.Space.md) {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, panel in
                        panel.content()
                    }
                }
            }
        }
    }

    /// The whole strip: what the features contribute, then Features, then General — always last.
    ///
    /// Takes the two built-ins as parameters rather than building them, so the ordering and merge
    /// rules are testable without a view or an app state behind them.
    static func strip(
        contributed: [TrayPanel],
        features: TrayPanel,
        general: TrayPanel
    ) -> [TrayPanel] {
        merged(contributed) + [features, general]
    }

    /// Resolves a remembered selection against what is actually on the strip.
    ///
    /// A stored panel whose feature has since been switched off would otherwise show nothing.
    /// Falling back to the first available panel is the only state that is always coherent.
    static func resolve(storedID: String?, available: [TrayPanel]) -> String {
        let ids = available.map(\.id)
        guard let storedID, ids.contains(storedID) else {
            return ids.first ?? generalID
        }
        return storedID
    }
}
