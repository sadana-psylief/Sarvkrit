import Foundation

/// What to do at launch about a fan that is already being held.
///
/// Pure, for the reason `KeepAwakeState` is pure: getting this wrong either strands a fan at a
/// fixed speed or stamps on a setting somebody else made deliberately, and neither failure
/// announces itself.
///
/// One asymmetry with `KeepAwakeState` is worth knowing. Reading the mode key is free, but
/// clearing it costs a password — so a fan we left held produces an *offer*, never a prompt
/// nobody asked for at launch. And unlike the system's `SleepDisabled` flag, **the SMC resets to
/// automatic on a power cycle**, so a stranded fan is bounded by the next restart. That makes this
/// a mild inconvenience rather than the "Mac awake in a bag" failure Keep Awake engineers against,
/// and the UI should say so rather than alarm.
enum FanReconcile {
    struct Situation: Equatable {
        /// We recorded taking the fan, in this session or a previous one.
        var weForcedIt: Bool
        /// What the SMC's mode key actually says right now.
        var modeIsForced: Bool
        /// Whether the user wants Sarvkrit driving the fans at all.
        var wantsControl: Bool
    }

    enum Action: Equatable {
        case takeControl
        /// Surface it and let the user decide, rather than spending their password unasked.
        case offerToRelease
        case doNothing
    }

    static func action(for situation: Situation) -> Action {
        switch (situation.wantsControl, situation.modeIsForced, situation.weForcedIt) {

        // Wanted and already held — whoever holds it, the fans are in the state asked for.
        case (true, true, _):
            return .doNothing

        // Wanted and free, or wanted and slipped out of our grip while the Mac slept. Take it.
        case (true, false, _):
            return .takeControl

        // Not wanted, held, and ours: the helper should have released it, so it died badly or the
        // Mac lost power mid-hold. Offer to fix rather than firing an unexplained password dialog.
        case (false, true, true):
            return .offerToRelease

        // Not wanted, held, and NOT ours. Macs Fan Control, TG Pro, somebody's script. Somebody
        // took these fans on purpose and it is not our place to hand them back.
        case (false, true, false):
            return .doNothing

        // Not wanted and not held. Nothing to do, including when we still believe otherwise —
        // a reboot cleared it, which is the SMC doing us a favour.
        case (false, false, _):
            return .doNothing
        }
    }
}
