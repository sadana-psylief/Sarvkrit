import SwiftUI

// The pieces a menu bar panel is built from.
//
// Every one of these is a *layout* over stock controls and semantic colours, per `Tokens.swift`:
// there is no `ButtonStyle`, `ToggleStyle` or `SliderStyle` in this file and there should not be.
// What they add is the one thing the design system was missing — a vocabulary for showing a
// reading, as opposed to showing a setting, which is all `SettingsRow` could ever do.
//
// They share `Theme.Metrics.rowInset` throughout, so a meter row and a toggle row put their text
// in the same column whether or not they are in the same card.

/// A horizontal measure: a filled track, rounded at both ends.
///
/// Deliberately thin. Anything thicker reads as a slider, and nothing here is draggable — a control
/// that invites a drag and ignores it is worse than a plain rectangle.
struct MeterBar: View {
    let value: Double?
    var ceiling: Double = 100
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: Theme.Metrics.meterHeight)
        // The number beside it says everything this conveys, and says it precisely.
        .accessibilityHidden(true)
    }

    /// Clamped at both ends. Tick-delta arithmetic overshoots 100% as a core comes online, and a
    /// fill wider than its own track spills past the rounded end.
    private var fraction: CGFloat {
        guard let value, ceiling > 0 else { return 0 }
        return CGFloat(min(1, max(0, value / ceiling)))
    }
}

/// A named reading: title, an optional meter, and the number.
///
/// The number is the point, so it is the largest thing in the row and always monospaced — a value
/// that changes every two seconds must not shuffle the row's contents as its digits change width.
struct StatRow: View {
    let title: String
    let value: String
    var symbolName: String?
    var meter: Double?
    var ceiling: Double = 100
    var tint: Color = .accentColor
    /// Dims the whole row for a reading that is switched off, rather than hiding it. A missing row
    /// implies a reading that doesn't exist; a dimmed one says it isn't being taken.
    var isMuted: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: Theme.Typography.body))
                    .foregroundStyle(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .frame(width: Theme.Metrics.iconColumn, alignment: .center)
            }
            Text(title)
                .font(.system(size: Theme.Typography.body))
                .foregroundStyle(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(1)

            if meter != nil || !isMuted {
                MeterBar(value: meter, ceiling: ceiling, tint: isMuted ? .secondary : tint)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
            }

            Text(value)
                .font(.system(size: Theme.Typography.metric, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isMuted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                // A fixed column, so the meters above and below each other end at the same x
                // whatever their numbers happen to be.
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.panelRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

/// A boxed headline number with a small label above it — a temperature, a wattage.
///
/// Sits in a row of two or three. Each takes an equal share of the width so the numbers line up
/// vertically, which is what makes three of them read as one instrument rather than three.
struct StatTile: View {
    let label: String
    let value: String
    var symbolName: String?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: Theme.Space.xs) {
                if let symbolName {
                    Image(systemName: symbolName).font(.system(size: 10))
                }
                Text(label).font(.system(size: Theme.Typography.caption))
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: Theme.Typography.stat, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

/// Two readings that only mean something as a pair: down and up, read and written.
///
/// One row, split by a rule, because they are two halves of one measurement. Shown as two separate
/// `StatRow`s they read as unrelated numbers that happen to be adjacent.
struct SplitStat: View {
    struct Half {
        let symbolName: String
        let tint: Color
        let value: String
        let caption: String
    }

    let leading: Half
    let trailing: Half

    var body: some View {
        HStack(spacing: 0) {
            half(leading)
            Divider().frame(height: 34)
            half(trailing)
        }
        .padding(.horizontal, Theme.Metrics.rowInset)
        .padding(.vertical, Theme.Space.sm)
    }

    private func half(_ half: Half) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: half.symbolName)
                .font(.system(size: Theme.Typography.title, weight: .medium))
                .foregroundStyle(half.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(half.value)
                    .font(.system(size: Theme.Typography.metric, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(half.caption)
                    .font(.system(size: Theme.Typography.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(half.caption), \(half.value)")
    }
}

/// A short status in a capsule with a filled dot: SMART, Normal, Mac awake.
///
/// The dot carries the state as well as the colour does, so the pill still says which state it is
/// in for anyone who cannot tell the tints apart.
struct StatusPill: View {
    let text: String
    var tint: Color = .green

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: Theme.Typography.caption, weight: .medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// A quiet line at the foot of a card: uptime, session totals, a note about what isn't readable.
struct FootnoteRow<Trailing: View>: View {
    let text: String
    var symbolName: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            if let symbolName {
                Image(systemName: symbolName).font(.system(size: 10))
            }
            Text(text).font(.system(size: Theme.Typography.caption))
            Spacer(minLength: Theme.Space.sm)
            trailing
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Metrics.rowInset)
        .frame(height: Theme.Metrics.menuRowHeight)
    }
}

extension FootnoteRow where Trailing == EmptyView {
    init(text: String, symbolName: String? = nil) {
        self.init(text: text, symbolName: symbolName) { EmptyView() }
    }
}
