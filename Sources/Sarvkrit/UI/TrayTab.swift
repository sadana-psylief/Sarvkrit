import Foundation

/// A tab in the menu bar dropdown.
///
/// Deliberately **not** an extra `FeatureCategory` case. `FeatureCategory` describes what a
/// *feature* is, and General owns no features — putting it there would create a category that has
/// to be permanently filtered out of `populatedCategories` and every other category-driven list.
enum TrayTab: Hashable, Identifiable {
    case category(FeatureCategory)
    case general

    var id: String {
        switch self {
        case .category(let category): return category.rawValue
        case .general: return "general"
        }
    }

    var title: String {
        switch self {
        case .category(let category): return category.title
        case .general: return "General"
        }
    }

    var symbolName: String {
        switch self {
        case .category(let category): return category.symbolName
        case .general: return "gearshape"
        }
    }

    /// Tabs for the categories that actually contain features, then General — always last.
    ///
    /// Takes the categories as a parameter rather than reaching for `AppState`, so ordering and the
    /// "an empty category never gets a tab" rule are testable without building an app state.
    static func tabs(for categories: [FeatureCategory]) -> [TrayTab] {
        categories.map(TrayTab.category) + [.general]
    }

    // MARK: - Persistence

    /// Stored as the raw `id`, so a tab that stops existing — a category emptied by a future
    /// change — simply fails to resolve rather than persisting a dangling case.
    init?(id: String) {
        if id == TrayTab.general.id {
            self = .general
        } else if let category = FeatureCategory(rawValue: id) {
            self = .category(category)
        } else {
            return nil
        }
    }

    /// Resolves a remembered selection against what's actually available.
    ///
    /// A stored tab whose category no longer has features would otherwise show an empty panel.
    /// Falling back to the first available tab is the only state that's always coherent.
    static func resolve(storedID: String?, available: [TrayTab]) -> TrayTab {
        guard let storedID,
              let stored = TrayTab(id: storedID),
              available.contains(stored)
        else { return available.first ?? .general }
        return stored
    }
}
