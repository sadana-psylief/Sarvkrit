import SwiftUI

/// The one custom element in the app: a rounded, accent-tinted square holding a feature's
/// SF Symbol. It carries the on/off colour signal so the `Toggle` beside it can stay
/// completely stock.
///
/// Decorative by design — the row's title and caption already say everything, so this is
/// hidden from VoiceOver to keep each row from being read twice.
struct FeatureIconTile: View {
    let symbolName: String
    var isOn: Bool
    var size: CGFloat = Theme.Size.iconTile

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.iconTile, style: .continuous)
            .fill(isOn ? Color.accentColor.opacity(0.18) : Color(nsColor: .quaternaryLabelColor).opacity(0.5))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .standardMotion(value: isOn)
            .accessibilityHidden(true)
    }
}
