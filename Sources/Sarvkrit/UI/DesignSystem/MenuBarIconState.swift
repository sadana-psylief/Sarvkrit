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
    /// The camera is on. Outranks everything: a mic that is muted is a safety measure already
    /// working, whereas a camera that is on is a live exposure the user may not have noticed.
    case cameraOn

    /// All template symbols, so the icon still inverts on light and dark menu bars and dims when the
    /// menu bar is inactive. A coloured icon would opt out of all of that.
    var symbolName: String {
        switch self {
        case .idle: return "command.square"
        case .awake: return "cup.and.saucer.fill"
        case .systemSleepDisabled: return "bolt.fill"
        case .microphoneMuted: return "mic.slash.fill"
        case .cameraOn: return "video.fill"
        }
    }

    /// What VoiceOver reads. The icon alone conveys nothing without it.
    var accessibilityLabel: String {
        switch self {
        case .idle: return "Sarvkrit"
        case .awake: return "Sarvkrit — keeping your Mac awake"
        case .systemSleepDisabled: return "Sarvkrit — system sleep is disabled"
        case .microphoneMuted: return "Sarvkrit — microphone muted"
        case .cameraOn: return "Sarvkrit — the camera is on"
        }
    }

    /// The more consequential state wins, and the order is deliberate.
    ///
    /// A camera that is on beats everything: it is a live exposure the user may not have noticed. A
    /// muted microphone comes next — the cost of not noticing it is immediate and personal, though
    /// it is a safety measure already working rather than a risk. Below those, a Mac that can't
    /// sleep at all matters more than one that merely won't idle out.
    static func current(
        keepAwakeRunning: Bool,
        systemSleepDisabled: Bool,
        microphoneMuted: Bool = false,
        cameraOn: Bool = false
    ) -> MenuBarIconState {
        if cameraOn { return .cameraOn }
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
        case .cameraOn: return "Camera on"
        }
        guard let countdown = countdownText(remaining: remaining) else { return prefix }
        return "\(prefix) · \(countdown) left"
    }

    /// Everything shown beside the icon, as the single string the menu bar can actually render.
    ///
    /// A `MenuBarExtra` label renders exactly one `Image` and one `Text` and drops anything
    /// further without warning, so Keep Awake's countdown and the System Monitor's live readings
    /// cannot be two views competing for the space — they are composed here instead. Laid out as
    /// two `Text`s, only the first would ever appear.
    ///
    /// The countdown reads first: it belongs to the icon that is currently showing a cup or a bolt.
    ///
    /// Empty strings count as absent, not as content. `menuBarLine` is empty whenever live data is
    /// switched off or no metrics are chosen, and testing only for nil would leave "5m · " with a
    /// dangling separator.
    static func trailingText(countdown: String?, liveData: String?) -> String? {
        let parts = [countdown, liveData].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }
}
