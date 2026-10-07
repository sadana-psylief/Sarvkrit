import AppKit
import Combine
import Foundation
import SwiftUI
import os

/// Reminds you to drink, paced to your day, and keeps count.
///
/// The rules for *when* live in `WaterSchedule`, which is pure. This class is the plumbing around
/// them: it keeps the log, reads the clock and the Mac's state, sets one timer for the next moment
/// the answer could change, and turns a decision into an icon and, rarely, a notification.
///
/// **Nothing here trusts a timer across sleep.** A `Timer` set for 14:20 on a Mac that slept from
/// 14:00 to 16:00 fires late or not at all, so every timestamp that matters is persisted and the
/// whole decision is recomputed from scratch on wake, unlock, and every log — the timer is only an
/// optimisation for "nothing happened, but the time moved on".
///
/// **One of two features whose panel stays up while it's off** (`panelIsItsOwnSwitch`). The
/// switch controls the *reminders*; the count and the log buttons work regardless, because some
/// people want a tracker and no nudges, so the panel is never an empty card.
final class WaterReminderFeature: Feature, ObservableObject {
    let id = "water-reminder"
    let category = FeatureCategory.system
    let title = "Water Reminder"
    let summary = "Paced reminders to drink, and a daily count"
    let details = """
        Keeps count of what you drink and reminds you when you fall behind — paced across your \
        active hours toward a daily goal, not on a fixed clock. Drinking early earns silence.

        The menu bar icon changes first. Only if nothing is logged for a while does a single \
        notification follow, with buttons to log a glass or snooze. Nothing pops up while the \
        screen is locked, while you're away, during a call, or when Focus is on, and coming back \
        after a long break gets you one reminder, never a backlog.
        """
    let symbolName = "drop"
    /// No Accessibility: idle time comes from the HID event source, not an event tap.
    let requirements: Set<Requirement> = []

    @Published private(set) var isRunning = false
    @Published private(set) var thirst: WaterThirst = .none
    @Published private(set) var goalMet = false
    @Published private(set) var permission: NotificationPermission = .notDetermined
    /// A mirror of the store's contents, published so the views redraw on every log.
    @Published private(set) var log: HydrationLog

    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "Water")
    private let defaults: UserDefaults
    private let store: HydrationStore
    private let notifier: NotificationPosting
    private let signals: ActivitySensing
    private let clock: () -> Date
    private let calendar: Calendar
    private let usesTimers: Bool

    private var recheckTimer: Timer?
    private var pollTimer: Timer?

    /// When the person was last seen leaving — a lock, a sleep, or input stopping. In memory only:
    /// across a relaunch the absence is unknowable and the grace period is a nicety, not a promise.
    private var awaySince: Date?
    private var graceUntil: Date?

    static let notificationCategory = "water-reminder"
    static let notificationID = "water-reminder.nudge"
    enum Action {
        static let drank = "water.drank"
        static let snooze = "water.snooze"
        static let notToday = "water.not-today"
    }

    /// No input for this long means you've stepped away; nothing pops up.
    static let idleThreshold: TimeInterval = 5 * 60
    /// Away for at least this long earns a grace period on return.
    static let longAbsence: TimeInterval = 30 * 60
    static let snoozeDuration: TimeInterval = 15 * 60
    /// How often the Mac's state is re-read while a reminder is due. Only then — the rest of the
    /// time a single timer for the next decision point is all that runs.
    static let pollInterval: TimeInterval = 60

    init(
        defaults: UserDefaults = .standard,
        store: HydrationStore? = nil,
        notifier: NotificationPosting = SystemNotifications.shared,
        signals: ActivitySensing = ActivitySignals(),
        calendar: Calendar = .current,
        usesTimers: Bool = true,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        let store = store ?? HydrationStore()
        self.store = store
        self.log = store.contents
        self.notifier = notifier
        self.signals = signals
        self.calendar = calendar
        self.usesTimers = usesTimers
        self.clock = now

        // Registered at construction rather than on activate: a button tapped on a notification
        // left over from the previous run is delivered during launch, possibly before `sync()`
        // has got round to activating anything.
        notifier.onAction(category: Self.notificationCategory) { [weak self] action in
            self?.handle(action: action)
        }
    }

    // MARK: - Settings

    private enum Key {
        static let goal = "waterReminder.goalMilliliters"
        static let unit = "waterReminder.unit"
        static let glass = "waterReminder.glassMilliliters"
        static let bottle = "waterReminder.bottleMilliliters"
        static let custom = "waterReminder.customMilliliters"
        static let activeStart = "waterReminder.activeStartMinutes"
        static let activeEnd = "waterReminder.activeEndMinutes"
        static let dayStart = "waterReminder.dayStartHour"
        static let minimumGap = "waterReminder.minimumGapMinutes"
        static let maximumGap = "waterReminder.maximumGapMinutes"
        static let quietInMeetings = "waterReminder.quietInMeetings"
        static let quietWhenIdle = "waterReminder.quietWhenIdle"
        static let lastNotification = "waterReminder.lastNotification"
        static let ignored = "waterReminder.ignoredNotifications"
        static let snoozedUntil = "waterReminder.snoozedUntil"
        static let silencedDay = "waterReminder.silencedDay"
        /// DEBUG builds only: divide every gap and delay by this, so a day can be walked in minutes.
        static let debugTimeScale = "waterReminder.debugTimeScale"
    }

    private func int(_ key: String, default value: Int) -> Int {
        defaults.object(forKey: key) == nil ? value : defaults.integer(forKey: key)
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
    }

    private func date(_ key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    /// The one setter every setting goes through: announce, store, re-decide.
    private func set(_ value: Any?, forKey key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        evaluate()
    }

    var goalMilliliters: Int {
        get { int(Key.goal, default: 2_000) }
        set { set(min(6_000, max(250, newValue)), forKey: Key.goal) }
    }

    var unit: VolumeUnit {
        get { defaults.string(forKey: Key.unit).flatMap(VolumeUnit.init) ?? .localeDefault }
        set { set(newValue.rawValue, forKey: Key.unit); registerCategory() }
    }

    var glassMilliliters: Int {
        get { int(Key.glass, default: 250) }
        set { set(Self.clampSize(newValue), forKey: Key.glass); registerCategory() }
    }

    var bottleMilliliters: Int {
        get { int(Key.bottle, default: 500) }
        set { set(Self.clampSize(newValue), forKey: Key.bottle) }
    }

    /// Zero means "no custom size", and the button isn't shown.
    var customMilliliters: Int {
        get { int(Key.custom, default: 0) }
        set { set(newValue <= 0 ? 0 : Self.clampSize(newValue), forKey: Key.custom) }
    }

    private static func clampSize(_ value: Int) -> Int { min(2_000, max(25, value)) }

    var activeStartMinutes: Int {
        get { int(Key.activeStart, default: 9 * 60) }
        set { set(min(23 * 60, max(0, newValue)), forKey: Key.activeStart) }
    }

    var activeEndMinutes: Int {
        get { int(Key.activeEnd, default: 19 * 60) }
        set { set(min(24 * 60 - 1, max(1, newValue)), forKey: Key.activeEnd) }
    }

    var dayStartHour: Int {
        get { int(Key.dayStart, default: 4) }
        set { set(min(8, max(0, newValue)), forKey: Key.dayStart) }
    }

    var minimumGapMinutes: Int {
        get { int(Key.minimumGap, default: 45) }
        set { set(min(maximumGapMinutes, max(15, newValue)), forKey: Key.minimumGap) }
    }

    var maximumGapMinutes: Int {
        get { int(Key.maximumGap, default: 120) }
        set { set(min(240, max(minimumGapMinutes, newValue)), forKey: Key.maximumGap) }
    }

    var quietInMeetings: Bool {
        get { bool(Key.quietInMeetings, default: true) }
        set { set(newValue, forKey: Key.quietInMeetings) }
    }

    var quietWhenIdle: Bool {
        get { bool(Key.quietWhenIdle, default: true) }
        set { set(newValue, forKey: Key.quietWhenIdle) }
    }

    /// The quick-log sizes, in button order. The custom size appears only once one is set.
    var quickSizes: [(name: String, milliliters: Int)] {
        var sizes = [("Glass", glassMilliliters), ("Bottle", bottleMilliliters)]
        if customMilliliters > 0 { sizes.append(("Custom", customMilliliters)) }
        return sizes
    }

    var settings: WaterSettings {
        var settings = WaterSettings()
        settings.goalMilliliters = goalMilliliters
        settings.activeStartMinutes = activeStartMinutes
        settings.activeEndMinutes = activeEndMinutes
        settings.dayStartHour = dayStartHour
        settings.minimumGap = TimeInterval(minimumGapMinutes * 60)
        settings.maximumGap = TimeInterval(maximumGapMinutes * 60)
        return settings.compressed(by: timeScale)
    }

    private var timeScale: Double {
        #if DEBUG
        return max(1, defaults.double(forKey: Key.debugTimeScale))
        #else
        return 1
        #endif
    }

    // MARK: - Reminder state, persisted so it survives sleep and relaunch

    private(set) var lastNotification: Date? {
        get { date(Key.lastNotification) }
        set { defaults.set(newValue, forKey: Key.lastNotification) }
    }

    private(set) var ignoredNotifications: Int {
        get { defaults.integer(forKey: Key.ignored) }
        set { defaults.set(newValue, forKey: Key.ignored) }
    }

    private(set) var snoozedUntil: Date? {
        get { date(Key.snoozedUntil) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.snoozedUntil) }
    }

    private var silencedDay: Date? {
        get { date(Key.silencedDay) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.silencedDay) }
    }

    var isSilencedToday: Bool {
        silencedDay == HydrationDay.start(of: clock(), dayStartHour: dayStartHour, calendar: calendar)
    }

    var isSnoozed: Bool { (snoozedUntil ?? .distantPast) > clock() }

    // MARK: - Reading the log

    var consumedToday: Int {
        log.total(onDayOf: clock(), dayStartHour: dayStartHour, calendar: calendar)
    }

    var todaysEntries: [HydrationEntry] {
        log.entries(onDayOf: clock(), dayStartHour: dayStartHour, calendar: calendar)
    }

    var todayStart: Date {
        HydrationDay.start(of: clock(), dayStartHour: dayStartHour, calendar: calendar)
    }

    func history(days: Int) -> [(day: Date, milliliters: Int)] {
        log.dailyTotals(days: days, endingAt: clock(), dayStartHour: dayStartHour, calendar: calendar)
    }

    /// Where the straight line says you should be by now. Used for the "on pace" caption.
    var expectedByNow: Int {
        WaterSchedule.expected(by: clock(), settings: settings, calendar: calendar)
    }

    var now: Date { clock() }

    // MARK: - Logging

    func logDrink(milliliters: Int, at date: Date? = nil) {
        let when = min(date ?? clock(), clock())
        store.update { $0.add(milliliters: milliliters, at: when) }
        // A drink answers any reminder outstanding: the back-off and the snooze both reset, and the
        // notification is withdrawn rather than left sitting in Notification Center asking a
        // question that's already been answered.
        ignoredNotifications = 0
        snoozedUntil = nil
        notifier.remove(ids: [Self.notificationID])
        logDidChange()
    }

    func undoLast() {
        store.update { $0.undoLast() }
        logDidChange()
    }

    func remove(entry id: UUID) {
        store.update { $0.remove(id: id) }
        logDidChange()
    }

    private func logDidChange() {
        log = store.contents
        evaluate()
    }

    func flush() { store.flush() }

    // MARK: - Snooze

    func snooze(for duration: TimeInterval = WaterReminderFeature.snoozeDuration) {
        snoozedUntil = clock().addingTimeInterval(duration / timeScale)
        notifier.remove(ids: [Self.notificationID])
        evaluate()
    }

    /// "Not today": silent until the hydration day turns over. Still counts what you log.
    func silenceToday() {
        silencedDay = todayStart
        notifier.remove(ids: [Self.notificationID])
        evaluate()
    }

    func resumeReminders() {
        snoozedUntil = nil
        silencedDay = nil
        evaluate()
    }

    // MARK: - Lifecycle

    func activate() {
        isRunning = true
        store.update { $0.prune(now: clock(), calendar: calendar) }
        log = store.contents
        signals.onAwayChange = { [weak self] away in self?.awayChanged(away) }
        signals.start()
        registerCategory()
        refreshPermission(requestIfUndetermined: true)
        evaluate()
    }

    func deactivate() {
        isRunning = false
        recheckTimer?.invalidate()
        recheckTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        signals.stop()
        signals.onAwayChange = nil
        notifier.remove(ids: [Self.notificationID])
        thirst = .none
        goalMet = false
        awaySince = nil
        graceUntil = nil
    }

    /// Shown while off too — see the header.
    var panelIsItsOwnSwitch: Bool { true }

    @MainActor
    func makeDetailView() -> AnyView? {
        AnyView(WaterDetailView(feature: self))
    }

    @MainActor
    func trayPanels() -> [TrayPanel] {
        [TrayPanel(id: "water", title: "Water", symbolName: "drop") {
            WaterTrayView(feature: self)
        }]
    }

    // MARK: - Permission

    func refreshPermission(requestIfUndetermined: Bool = false) {
        notifier.permission { [weak self] permission in
            guard let self else { return }
            self.permission = permission
            guard requestIfUndetermined, permission == .notDetermined, self.isRunning else { return }
            self.requestPermission()
        }
    }

    func requestPermission() {
        notifier.requestPermission { [weak self] permission in
            self?.permission = permission
        }
    }

    private func registerCategory() {
        notifier.register(category: Self.notificationCategory, actions: [
            NotificationAction(id: Action.drank, title: "Drank \(unit.format(glassMilliliters))"),
            NotificationAction(id: Action.snooze, title: "Snooze 15 min"),
            NotificationAction(id: Action.notToday, title: "Not today"),
        ])
    }

    func handle(action: String) {
        switch action {
        case Action.drank: logDrink(milliliters: glassMilliliters)
        case Action.snooze: snooze()
        case Action.notToday: silenceToday()
        // Clicking the body or dismissing it says nothing about whether you drank.
        default: break
        }
    }

    // MARK: - Deciding

    /// Recomputes everything from persisted state and the current moment. Safe to call any time,
    /// as often as you like: the only side effect that isn't idempotent — posting — records itself
    /// before the next call can see it.
    func evaluate() {
        guard isRunning else { return }
        let now = clock()
        updatePresence(now: now)

        var input = WaterScheduleInput(
            now: now,
            settings: settings,
            consumedToday: consumedToday,
            lastDrink: log.lastDrink,
            lastNotification: lastNotification,
            ignoredNotifications: ignoredNotifications,
            snoozedUntil: snoozedUntil,
            silencedDay: silencedDay,
            suppressed: false,
            graceUntil: graceUntil)
        var decision = WaterSchedule.decide(input, calendar: calendar)

        // Suppression is asked only when it could matter: reading the camera and microphone state
        // is cheap, but not free, and almost every evaluation ends long before a notification.
        if decision.shouldNotify, isSuppressed {
            input.suppressed = true
            decision = WaterSchedule.decide(input, calendar: calendar)
        }

        if thirst != decision.thirst { thirst = decision.thirst }
        if goalMet != decision.goalMet { goalMet = decision.goalMet }
        if decision.shouldNotify { notify(now: now) }

        scheduleRecheck(at: decision.recheckAt)
        // Poll only while something is due (to notice a call ending, or someone coming back) or
        // while we believe the person is away (to notice them return).
        setPolling(decision.thirst != .none || awaySince != nil)
    }

    private var isSuppressed: Bool {
        if signals.isAway { return true }
        if quietWhenIdle, signals.idleSeconds >= Self.idleThreshold / timeScale { return true }
        if quietInMeetings, signals.isInMeeting { return true }
        return false
    }

    private func notify(now: Date) {
        lastNotification = now
        ignoredNotifications += 1
        // Recorded either way, so a denied permission degrades to the icon alone on the same
        // schedule rather than to a reminder retried every minute.
        guard permission == .allowed else { return }
        notifier.post(
            id: Self.notificationID,
            category: Self.notificationCategory,
            title: "Time for some water",
            body: "\(unit.format(consumedToday)) of \(unit.format(goalMilliliters)) so far today.")
        logger.info("water reminder posted")
    }

    // MARK: - Presence

    private func awayChanged(_ away: Bool) {
        let now = clock()
        if away {
            if awaySince == nil { awaySince = now }
        } else {
            returned(now: now)
        }
        evaluate()
    }

    /// Notices someone stepping away by input stopping, and coming back by it starting again.
    /// Lock and sleep arrive as events instead; see `awayChanged`.
    private func updatePresence(now: Date) {
        guard !signals.isAway else { return }
        let idle = signals.idleSeconds
        if idle >= Self.idleThreshold / timeScale {
            if awaySince == nil { awaySince = now.addingTimeInterval(-idle) }
        } else if awaySince != nil {
            returned(now: now)
        }
    }

    private func returned(now: Date) {
        defer { awaySince = nil }
        guard let since = awaySince, now.timeIntervalSince(since) >= Self.longAbsence / timeScale else { return }
        graceUntil = now.addingTimeInterval(settings.returnGrace)
    }

    // MARK: - Timers

    private func scheduleRecheck(at date: Date?) {
        recheckTimer?.invalidate()
        recheckTimer = nil
        guard usesTimers, let date else { return }
        // The clock may be injected; the run loop's isn't. Convert to a delay so a test clock and a
        // real timer can't disagree about what "14:20" means.
        let delay = max(1, date.timeIntervalSince(clock()))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in self?.evaluate() }
        // A little tolerance lets macOS coalesce the wake-up with others. Nobody needs a water
        // reminder to the second.
        timer.tolerance = min(30, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        recheckTimer = timer
    }

    private func setPolling(_ on: Bool) {
        guard usesTimers else { return }
        if !on {
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        guard pollTimer == nil else { return }
        let interval = max(2, Self.pollInterval / timeScale)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.evaluate() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}
