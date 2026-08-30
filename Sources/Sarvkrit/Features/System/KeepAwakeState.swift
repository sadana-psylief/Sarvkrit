import Foundation

/// Decides what to do about the system-wide `SleepDisabled` flag.
///
/// Pure, because this is the logic that decides whether to touch a setting belonging to the whole
/// machine. Getting it wrong either strands sleep disabled forever or stamps on a flag somebody else
/// set deliberately — and neither failure announces itself.
enum KeepAwakeState {

    /// What the app knows and what the system reports.
    struct Situation: Equatable {
        /// We recorded setting the flag ourselves, in a previous session or this one.
        var weSetIt: Bool
        /// The user wants the lid-closed option on right now.
        var wantsLidClosed: Bool
        /// What `pmset -g` actually reports.
        var flagIsOn: Bool
    }

    enum Action: Equatable {
        /// Set the flag — needs the password dialog, and the user just asked for it.
        case set
        /// Someone should clear it, but that costs a password, so surface it rather than ambush.
        case offerToRestore
        case doNothing
    }

    static func action(for situation: Situation) -> Action {
        switch (situation.wantsLidClosed, situation.flagIsOn, situation.weSetIt) {

        // Wanted and already on — whoever set it, the machine is in the state the user asked for.
        case (true, true, _):
            return .doNothing

        // Wanted but not on. Either first activation, or a watchdog cleared it while the toggle
        // stayed on. Setting it is what the user asked for, so the prompt is expected.
        case (true, false, _):
            return .set

        // Not wanted, and on, and ours: the watchdog should have handled this, so a reboot killed
        // it. Offer to fix rather than firing an unexplained password dialog at launch.
        case (false, true, true):
            return .offerToRestore

        // Not wanted, on, and NOT ours. Somebody disabled sleep on purpose — possibly by hand, in a
        // terminal, for a reason we know nothing about. Leave it alone.
        case (false, true, false):
            return .doNothing

        case (false, false, _):
            return .doNothing
        }
    }

    /// Whether the pane should show the "still disabled from last session" banner.
    static func showsStrandedWarning(for situation: Situation) -> Bool {
        action(for: situation) == .offerToRestore
    }

    // MARK: - Parsing what the system reports

    /// Reads `SleepDisabled` out of `pmset -g` output.
    ///
    /// Returns nil when the key isn't listed at all — which is a real case, and must not be
    /// mistaken for "sleep is enabled", since that would make us think a flag we set had vanished.
    static func parseSleepDisabled(_ pmsetOutput: String) -> Bool? {
        for line in pmsetOutput.split(separator: "\n") {
            // Split on any whitespace, not just spaces: `pmset -g` separates the key from its value
            // with tabs, so splitting on " " alone leaves "SleepDisabled\t\t1" as a single token
            // and the key is never found.
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard let keyIndex = parts.firstIndex(where: { $0 == "SleepDisabled" }),
                  keyIndex + 1 < parts.count
            else { continue }
            return parts[keyIndex + 1].trimmingCharacters(in: .whitespaces) == "1"
        }
        return nil
    }
}

/// How long Keep Awake should hold before releasing on its own.
enum KeepAwakeDuration: String, Codable, CaseIterable, Identifiable {
    case indefinite
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours

    var id: String { rawValue }

    var title: String {
        switch self {
        case .indefinite: return "Until I turn it off"
        case .thirtyMinutes: return "30 minutes"
        case .oneHour: return "1 hour"
        case .twoHours: return "2 hours"
        case .fourHours: return "4 hours"
        }
    }

    /// Nil for indefinite — the assertion simply stays.
    var seconds: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 3_600
        case .twoHours: return 7_200
        case .fourHours: return 14_400
        }
    }

    /// A ceiling applied to the root watchdog even when the user chose "indefinite".
    ///
    /// Indefinite means "for as long as I'm working", not "until the battery is flat in a bag". The
    /// watchdog clears the flag the moment Sarvkrit exits anyway; this only matters if the app runs
    /// untouched for half a day.
    static let watchdogCeiling: TimeInterval = 12 * 3_600

    var watchdogSeconds: TimeInterval {
        min(seconds ?? Self.watchdogCeiling, Self.watchdogCeiling)
    }
}
