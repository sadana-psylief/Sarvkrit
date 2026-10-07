import SwiftUI

/// The Fans tab in the menu bar panel.
struct FanPanelView: View {
    @ObservedObject var feature: FanControlFeature

    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            switch feature.hardware {
            case .fanless:
                SettingsModule {
                    FootnoteRow(text: "This Mac has no fans.", symbolName: "wind")
                }
            case .unreadable:
                SettingsModule {
                    FootnoteRow(text: "No fan readings from this Mac.", symbolName: "fan")
                }
            case let .fans(fans):
                if feature.controlWasLost {
                    SettingsModule {
                        FootnoteRow(
                            text: "Fan control stopped. The fans are back on macOS.",
                            symbolName: "exclamationmark.triangle")
                    }
                }
                tiles(fans)
                SettingsModule {
                    ForEach(Array(fans.enumerated()), id: \.element.id) { position, fan in
                        if position > 0 { ModuleSeparator() }
                        StatRow(
                            title: FanFormatting.name(of: fan.index, outOf: fans.count),
                            value: FanFormatting.rpm(fan.rpm),
                            symbolName: "fan",
                            meter: fan.rpm,
                            ceiling: fan.maximum ?? 1)
                    }
                    ModuleSeparator()
                    FootnoteRow(text: footnote(fans), symbolName: "gauge.with.dots.needle.67percent")
                }
            }
        }
    }

    @ViewBuilder
    private func tiles(_ fans: [FanReading]) -> some View {
        HStack(spacing: Theme.Space.sm) {
            ForEach(fans) { fan in
                StatTile(
                    label: FanFormatting.name(of: fan.index, outOf: fans.count),
                    value: FanFormatting.percentOfRange(fan),
                    symbolName: "fan")
            }
        }
    }

    /// Says who is driving. A fan the SMC is managing is the normal case and worth stating, so
    /// that a fan somebody else has taken over reads as the exception it is.
    private func footnote(_ fans: [FanReading]) -> String {
        if fans.contains(where: { $0.isForced == true }) {
            switch feature.mode {
            case .monitor:
                // Not ours. Macs Fan Control, TG Pro, somebody's script — and not ours to undo.
                return "Held at a set speed by something other than macOS or Sarvkrit."
            case .manual:
                return "Sarvkrit is holding the fans at a set speed."
            case .automatic:
                return "Sarvkrit is speeding the fans up because the Mac is hot."
            }
        }
        if fans.allSatisfy({ $0.isForced == nil }) {
            return "This Mac does not say who is driving the fans."
        }
        return "macOS is choosing the speed."
    }
}
