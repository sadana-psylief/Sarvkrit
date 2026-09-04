import Foundation

/// How long captures are kept.
///
/// Pure, so "an item exactly on the boundary" and "the clock went backwards" are tests rather
/// than things you find out a month later when someone's screenshots have gone.
enum CaptureRetention {

    /// How long history is kept. Raw values are persisted.
    enum Window: String, Codable, CaseIterable, Equatable {
        case week
        case month
        case forever

        var title: String {
            switch self {
            case .week: return "1 week"
            case .month: return "1 month"
            case .forever: return "Forever"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .week: return 7 * 24 * 60 * 60
            case .month: return 30 * 24 * 60 * 60
            case .forever: return nil
            }
        }
    }

    /// Which items have aged out.
    ///
    /// - An item exactly at the boundary is **kept**. Deleting on the tick is an off-by-one the
    ///   user experiences as "it said a month and it was gone in a month", and keeping is the
    ///   forgiving direction.
    /// - An item dated in the *future* is kept regardless. That happens with clock skew and
    ///   timezone changes, and deleting someone's newest screenshot because their clock jumped
    ///   is a far worse failure than keeping one too long.
    static func expired(items: [(id: UUID, createdAt: Date)],
                        now: Date,
                        window: Window) -> [UUID] {
        guard let seconds = window.seconds else { return [] }
        let cutoff = now.addingTimeInterval(-seconds)
        return items.filter { $0.createdAt < cutoff }.map(\.id)
    }
}
