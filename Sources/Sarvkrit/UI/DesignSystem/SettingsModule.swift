import SwiftUI

/// A Control Center-style grouped module: a rounded container holding related rows flush against
/// each other, separated by inset hairlines.
///
/// Grouping is what carries hierarchy here. The previous dropdown put a uniform 12pt gap between
/// every element, so nothing read as belonging to anything else — modules supply that structure,
/// and the gap *between* modules is the only vertical rhythm left to tune.
struct SettingsModule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.quaternary.opacity(0.4), in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
            .clipShape(shape)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.module, style: .continuous)
    }
}

/// Hairline between rows inside a module, inset past the icon column.
struct ModuleSeparator: View {
    var body: some View {
        Divider().padding(.leading, Theme.Metrics.separatorInset)
    }
}

/// The small uppercase label above a module, the way Control Center titles its groups.
struct SectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
            .padding(.horizontal, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}
