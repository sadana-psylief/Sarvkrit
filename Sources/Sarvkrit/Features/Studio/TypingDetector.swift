import Foundation

/// Finding the stretches where somebody was typing.
///
/// The other half of removing dead air, and the half the reference product actually ships:
/// **watching someone type is boring at 1× and fine at 4×.** Reading the keystroke log is enough
/// to find those stretches, so this needs no audio at all.
enum TypingDetector {

    struct Tuning: Equatable {
        /// Keys in a row before it counts as typing rather than a shortcut.
        var minimumKeys: Int = 5
        /// The longest pause allowed inside one run. Beyond this the user stopped to think, and
        /// speeding up a pause is just cutting it badly.
        var maximumGap: TimeInterval = 0.8
        var suggestedSpeed: Double = 4

        init() {}
    }

    /// One stretch worth offering to speed up.
    struct Suggestion: Equatable, Identifiable {
        var id = UUID()
        var start: TimeInterval
        var end: TimeInterval
        var suggestedSpeed: Double

        static func == (a: Suggestion, b: Suggestion) -> Bool {
            a.start == b.start && a.end == b.end && a.suggestedSpeed == b.suggestedSpeed
        }
    }

    /// **Suggestions, never applications.** Each is offered on the timeline with accept, adjust and
    /// dismiss; none is applied on the user's behalf. A speed change that appears in someone's
    /// edit without them asking is the kind of helpfulness that makes a tool untrustworthy.
    static func runs(in keys: [KeyEvent], tuning: Tuning = Tuning()) -> [Suggestion] {
        guard keys.count >= tuning.minimumKeys else { return [] }
        let sorted = keys.sorted { $0.t < $1.t }

        var suggestions: [Suggestion] = []
        var run: [KeyEvent] = [sorted[0]]

        func close() {
            guard run.count >= tuning.minimumKeys,
                  let first = run.first, let last = run.last else { return }
            suggestions.append(Suggestion(start: first.t, end: last.t,
                                          suggestedSpeed: tuning.suggestedSpeed))
        }

        for key in sorted.dropFirst() {
            if key.t - (run.last?.t ?? key.t) <= tuning.maximumGap {
                run.append(key)
            } else {
                close()
                run = [key]
            }
        }
        close()
        return suggestions
    }
}
