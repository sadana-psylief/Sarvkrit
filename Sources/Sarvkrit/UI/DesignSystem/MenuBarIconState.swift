import Foundation

/// What the menu bar icon should show.
///
/// The state reported is **whether the Mac can actually sleep**, not whether the Keep Awake switch
/// is on. Those usually agree — but after a reboot strands the system flag, the feature reads as off
/// while sleep is genuinely still disabled, and an icon that sided with the toggle would be
/// misleading in precisely the situation the indicator exists for.
enum MenuBarIconState: Equatable {
    case idle
    /// Won't idle to sleep — our own power assertion.
    case awake
    /// Won't sleep at all, lid closed or not — the system-wide flag.
    case systemSleepDisabled
    /// The microphone is muted. Ranked above the sleep states below, because a live-looking mic that
    /// is actually muted has an immediate cost — you talk to nobody — where sleep behaviour does
    /// not.
    case microphoneMuted

    /// All template symbols, so the icon still inverts on light and dark menu bars and dims when the
    /// menu bar is inactive. A coloured icon would opt out of all of that.
    var symbolName: String {
        switch self {
        case .idle: return "command.square"
        case .awake: return "cup.and.saucer.fill"
        case .systemSleepDisabled: return "bolt.fill"
        case .microphoneMuted: return "mic.slash.fill"
        }
    }

    /// What VoiceOver reads. The icon alone conveys nothing without it.
    var accessibilityLabel: String {
        switch self {
        case .idle: return "Sarvkrit"
        case .awake: return "Sarvkrit — keeping your Mac awake"
        case .systemSleepDisabled: return "Sarvkrit — system sleep is disabled"
        case .microphoneMuted: return "Sarvkrit — microphone muted"
        }
    }

    /// The more consequential state wins: a muted microphone beats everything, because the cost of
    /// not noticing it is immediate and personal. Below that, a Mac that can't sleep at all matters
    /// more than one that merely won't idle out.
    static func current(
        keepAwakeRunning: Bool,
        systemSleepDisabled: Bool,
        microphoneMuted: Bool = false
    ) -> MenuBarIconState {
        if microphoneMuted { return .microphoneMuted }
        if systemSleepDisabled { return .systemSleepDisabled }
        return keepAwakeRunning ? .awake : .idle
    }

    /// Remaining time beside the icon. Nil when there's nothing to count — an indefinite session has
    /// no end to show, and showing "0m" forever would be worse than showing nothing.
    static func countdownText(remaining: TimeInterval?) -> String? {
        guard let remaining, remaining > 0 else { return nil }
        let minutes = Int(remaining / 60)
        return minutes >= 1 ? "\(minutes)m" : "<1m"
    }

    /// The line shown in the tray panel's header while something is active.
    static func statusLine(state: MenuBarIconState, remaining: TimeInterval?) -> String? {
        let prefix: String
        switch state {
        case .idle: return nil
        case .awake: prefix = "Awake"
        case .systemSleepDisabled: prefix = "Sleep disabled"
        case .microphoneMuted: return "Mic muted"
        }
        guard let countdown = countdownText(remaining: remaining) else { return prefix }
        return "\(prefix) · \(countdown) left"
    }
}
