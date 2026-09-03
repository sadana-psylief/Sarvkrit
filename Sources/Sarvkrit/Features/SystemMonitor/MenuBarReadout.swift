import Foundation

/// Turns a snapshot into the short symbol-and-number pairs the second menu bar item displays.
///
/// This is `MenuBarIconState`'s counterpart for the monitor, and it exists for the same reason:
/// the arrangement decision is worth asserting rather than squinting at. Two properties matter and
/// neither is obvious from a view body.
///
/// **Order is the user's**, taken from the persisted list rather than `MetricKind.allCases`, or the
/// pane's ordering control would look broken rather than unimplemented.
///
/// **A missing reading keeps its place.** Every rate is briefly unavailable after a wake, by
/// design; dropping the segment would reflow the whole menu bar each time, shoving every item to
/// its right. A placeholder holds the slot instead.
enum MenuBarReadout {
    struct Segment: Equatable, Identifiable {
        let symbolName: String
        let text: String

        var id: String { symbolName }
    }

    static func segments(for snapshot: SystemSnapshot, metrics: [MetricKind]) -> [Segment] {
        var seen: Set<MetricKind> = []
        return metrics.compactMap { kind in
            // A duplicate in the persisted list would put the same number in the menu bar twice.
            guard seen.insert(kind).inserted else { return nil }
            return Segment(symbolName: kind.symbolName, text: text(for: kind, in: snapshot))
        }
    }

    private static func text(for kind: MetricKind, in snapshot: SystemSnapshot) -> String {
        switch kind {
        case .cpu:
            return MetricFormatting.percent(snapshot.cpu?.usage ?? nil)
        case .gpu:
            return MetricFormatting.percent(snapshot.gpu?.usage)
        case .power:
            return MetricFormatting.watts(snapshot.power?.watts)
        case .battery:
            // `isPresent` is what separates a desktop with no battery from a battery at 0%.
            guard let battery = snapshot.battery, battery.isPresent else {
                return MetricFormatting.placeholder
            }
            return MetricFormatting.percent(battery.percent)
        case .memory:
            // A share of installed RAM rather than an absolute: "9.2 GB" needs three more
            // characters of menu bar to say less than "57%".
            return MetricFormatting.percent(snapshot.memory?.usagePercent)
        case .disk:
            return MetricFormatting.percent(snapshot.disk?.usagePercent)
        case .network:
            // Download only. Showing both directions doubles the width of the widest segment for a
            // number most people glance at to answer "is something downloading".
            return MetricFormatting.bytesPerSecond(snapshot.network?.downloadPerSecond)
        }
    }
}
