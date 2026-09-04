import SwiftUI

/// One text preset, drawn the way it will actually appear.
///
/// Shares nothing with `AnnotationRenderer` on purpose — that draws into a `CGContext` at image
/// scale, this is a 13pt SwiftUI label — but it reads the same `TextPreset`, so a style added to
/// the table shows up here without a second edit.
struct TextStyleSwatch: View {
    let preset: TextPreset
    var accent: RGBAColour = .red

    private var font: Font {
        switch preset.typeface {
        case .standard, .custom: return .system(size: 13, weight: .bold)
        case .rounded: return .system(size: 13, weight: .bold, design: .rounded)
        case .monospaced: return .system(size: 13, weight: .semibold, design: .monospaced)
        }
    }

    private var accentColour: Color { Color(cgColor: accent.cgColor) }

    var body: some View {
        Text(preset.title)
            .font(font)
            .foregroundStyle(foreground)
            .shadow(color: preset.hasHalo ? .white : .clear, radius: 0.5)
            .shadow(color: preset.hasHalo ? .white : .clear, radius: 1.5)
            .padding(.horizontal, preset.hasBackground ? 7 : 2)
            .padding(.vertical, preset.hasBackground ? 3 : 1)
            .background(background)
            .fixedSize()
    }

    private var foreground: Color {
        guard preset.hasBackground else { return preset.hasHalo ? .black : accentColour }
        return preset == .monospacedBoxed ? .black : Color(cgColor: accent.readableForeground.cgColor)
    }

    @ViewBuilder private var background: some View {
        if preset.hasBackground {
            // The capsule preset's radius runs past half the height, which is what makes it a
            // capsule rather than a rounded rectangle.
            let shape = RoundedRectangle(cornerRadius: preset == .roundedBoxed ? 20 : 4,
                                         style: .continuous)
            shape
                .fill(preset == .monospacedBoxed ? Color.white : accentColour)
                .overlay(shape.strokeBorder(preset.hasBorder ? Color.black.opacity(0.55) : .clear,
                                            lineWidth: 1))
        }
    }
}
