# Water Reminder

A hydration tracker that reminds you when you fall behind, without becoming the kind of reminder
people switch off within a week.

## Why it's shaped like this

Most water apps get switched off because they nag on a fixed clock, interrupt calls, fire a backlog
after lunch, and guilt you with streaks. This one:

- reminds only when you're **behind pace**, not every N minutes;
- treats a drink as the timer reset, so drinking early earns silence;
- never interrupts a call, a locked or sleeping Mac, or someone who has stepped away, and on return
  waits a grace period and then sends **at most one** reminder;
- starts quiet (the icon), escalates once (a notification), and backs off if ignored;
- shows progress and history with **no streaks and no red days**;
- stops for the day once the goal is met.

## Behaviour

| Rule | Default |
|---|---|
| Goal | 2 L (250 ml–6 L) |
| Active hours | 09:00–19:00 |
| Day turns over at | 04:00 |
| Minimum gap (after a drink, between notifications) | 45 min |
| Maximum gap (remind even when on pace) | 2 h |
| Icon to notification | 20 min (icon fills `drop` → `drop.halffull` → `drop.fill`) |
| Ignored notification | next spacing doubles, capped at the maximum gap |
| Stepped away | no input for 5 min |
| Long absence → grace | ≥ 30 min away → 5 min grace, then one reminder |
| Snooze (notification) | 15 min; tray offers 1 hour |
| Not today | silent until the day turns over; logging still counts |

**Pacing.** The expected amount is a straight line from 0 at the start of the active hours to the
goal at their end. The icon is due at `min(max(lastDrink + minGap, paceCatchUp), lastDrink +
maxGap)`, where `lastDrink` is clamped to the window start. The notification is due 20 minutes after
that, or after the back-off or snooze, whichever is later, and only if that's still inside the
window.

**Suppression.** The screen is locked, the system or display is asleep, you've been idle past the
threshold, or the camera or microphone is in use. Suppression holds back the notification; the icon
still changes. Focus is handled by macOS itself, because reminders are system notifications marked
`.passive`.

**Not trusting timers.** Every timestamp that matters is persisted (`waterReminder.*` in
UserDefaults), and the whole decision is recomputed on wake, unlock, every log, and a single timer
for the next decision point. A 60-second poll runs only while a reminder is due, to notice a call
ending or someone coming back.

**Permission.** Notification permission is requested when the feature is first switched on. If it
is denied, the reminders become icon-only on the same schedule, and the pane offers a link to System
Settings.

## Code

| Piece | File |
|---|---|
| Schedule (pure) | `Features/System/WaterSchedule.swift` |
| Log, day boundary, units (pure) | `Features/System/HydrationLog.swift` |
| Persistence (JSON + `CoalescingSaver`) | `Features/System/HydrationStore.swift` |
| Idle, lock, sleep, call detection | `Features/System/ActivitySignals.swift` |
| `UNUserNotificationCenter` seam + delegate | `Core/SystemNotifications.swift` |
| Feature | `Features/System/WaterReminderFeature.swift` |
| Tray panel, detail pane | `UI/System/WaterTrayView.swift`, `UI/System/WaterDetailView.swift` |
| Icon ranking (below camera, mic and system-sleep, above the Keep Awake cup) | `UI/DesignSystem/MenuBarIconState.swift` |

DEBUG builds read `waterReminder.debugTimeScale` and divide every gap and delay by it, so a day can
be walked through by hand:

```bash
defaults write ai.psylief.sarvkrit waterReminder.debugTimeScale -float 60   # minutes become seconds
```

## Out of scope

- Fullscreen-app detection. There is no clean API for it that needs no permission, and the
  camera/microphone check covers the common case of a call.
- Goals derived from body weight or the weather. The goal is a nudge, and a formula would claim
  more precision than it has.
