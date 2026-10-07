import XCTest
@testable import Sarvkrit

/// The plumbing around `WaterSchedule`: that a decision becomes an icon and at most one
/// notification, that the buttons on it do what they say, and that the Mac's state holds it back.
///
/// Nothing here reaches the real notification center, the real clock or the real camera. The
/// schedule's own rules are `WaterScheduleTests`; these only check they're wired up.
@MainActor
final class WaterReminderFeatureTests: XCTestCase {

    private final class FakeNotifier: NotificationPosting {
        var permissionValue: NotificationPermission = .allowed
        private(set) var requested = 0
        private(set) var posted: [(id: String, body: String)] = []
        private(set) var removed: [String] = []
        private(set) var categories: [String: [NotificationAction]] = [:]
        private var handlers: [String: (String) -> Void] = [:]

        func permission(_ completion: @escaping (NotificationPermission) -> Void) { completion(permissionValue) }
        func requestPermission(_ completion: @escaping (NotificationPermission) -> Void) {
            requested += 1
            completion(permissionValue)
        }
        func register(category: String, actions: [NotificationAction]) { categories[category] = actions }
        func post(id: String, category: String, title: String, body: String) { posted.append((id, body)) }
        func remove(ids: [String]) { removed.append(contentsOf: ids) }
        func onAction(category: String, _ handler: @escaping (String) -> Void) { handlers[category] = handler }

        func tap(_ action: String) { handlers[WaterReminderFeature.notificationCategory]?(action) }
    }

    private final class FakeSignals: ActivitySensing {
        var idleSeconds: TimeInterval = 0
        var isInMeeting = false
        var isAway = false { didSet { if oldValue != isAway { onAwayChange?(isAway) } } }
        var onAwayChange: ((Bool) -> Void)?
        private(set) var started = 0
        private(set) var stopped = 0
        func start() { started += 1 }
        func stop() { stopped += 1 }
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var notifier: FakeNotifier!
    private var signals: FakeSignals!
    private var now: Date!

    override func setUp() {
        super.setUp()
        suiteName = "water.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        notifier = FakeNotifier()
        signals = FakeSignals()
        now = at(8)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 7) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func makeFeature() -> WaterReminderFeature {
        let feature = WaterReminderFeature(
            defaults: defaults,
            store: HydrationStore(directory: directory),
            notifier: notifier,
            signals: signals,
            calendar: calendar,
            usesTimers: false,
            now: { [unowned self] in self.now })
        feature.unit = .milliliters
        return feature
    }

    /// Activated at `time`, with nothing logged.
    private func running(at time: Date) -> WaterReminderFeature {
        now = time
        let feature = makeFeature()
        feature.activate()
        return feature
    }

    // MARK: - Contract

    func testNeedsNoPermissionsAndKeepsItsPanelWhenOff() {
        let feature = makeFeature()
        XCTAssertTrue(feature.requirements.isEmpty, "the default is Accessibility, which this doesn't use")
        XCTAssertTrue(feature.panelIsItsOwnSwitch)
        XCTAssertEqual(feature.trayPanels().map(\.id), ["water"])
    }

    func testActivatingStartsListeningAndRegistersTheButtons() {
        let feature = running(at: at(8))
        XCTAssertEqual(signals.started, 1)
        let actions = notifier.categories[WaterReminderFeature.notificationCategory]?.map(\.id)
        XCTAssertEqual(actions, ["water.drank", "water.snooze", "water.not-today"])
        XCTAssertEqual(notifier.categories[WaterReminderFeature.notificationCategory]?.first?.title, "Drank 250 ml")
        XCTAssertEqual(feature.thirst, .none)
    }

    func testAnUndecidedPermissionIsAskedForOnActivate() {
        notifier.permissionValue = .notDetermined
        _ = running(at: at(8))
        XCTAssertEqual(notifier.requested, 1)
    }

    // MARK: - Escalation

    func testOneNotificationOnceItIsEarnedAndNotOnEveryEvaluation() {
        let feature = running(at: at(9, 45))
        XCTAssertEqual(feature.thirst, .gentle)
        XCTAssertTrue(notifier.posted.isEmpty)

        now = at(10, 5)
        feature.evaluate()
        XCTAssertEqual(feature.thirst, .urgent)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted.first?.body, "0 ml of 2 L so far today.")

        now = at(10, 6)
        feature.evaluate()
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testADeniedPermissionStillChangesTheIconOnTheSameSchedule() {
        notifier.permissionValue = .denied
        let feature = running(at: at(10, 5))
        XCTAssertEqual(feature.thirst, .urgent)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    // MARK: - The buttons

    func testDrankLogsAGlassAndAnswersTheReminder() {
        let feature = running(at: at(10, 5))
        XCTAssertEqual(notifier.posted.count, 1)

        notifier.tap("water.drank")
        XCTAssertEqual(feature.consumedToday, 250)
        XCTAssertEqual(feature.thirst, .none)
        XCTAssertTrue(notifier.removed.contains(WaterReminderFeature.notificationID),
                      "an answered question shouldn't sit in Notification Center")
    }

    func testSnoozeIsQuietForFifteenMinutesThenAsksAgain() {
        let feature = running(at: at(10, 5))
        notifier.tap("water.snooze")
        XCTAssertEqual(feature.thirst, .none)
        XCTAssertTrue(feature.isSnoozed)

        now = at(10, 19)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1)

        now = at(10, 20)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 2)
    }

    func testNotTodayIsSilentUntilTomorrowButStillCounts() {
        let feature = running(at: at(10, 5))
        notifier.tap("water.not-today")
        XCTAssertTrue(feature.isSilencedToday)

        now = at(16)
        feature.evaluate()
        XCTAssertEqual(feature.thirst, .none)
        feature.logDrink(milliliters: 500)
        XCTAssertEqual(feature.consumedToday, 500)

        now = at(10, 5, day: 8)
        feature.evaluate()
        XCTAssertEqual(feature.thirst, .urgent)
    }

    func testTappingTheBodySaysNothingAboutDrinking() {
        let feature = running(at: at(10, 5))
        notifier.tap("com.apple.UNNotificationDefaultActionIdentifier")
        XCTAssertEqual(feature.consumedToday, 0)
        XCTAssertEqual(feature.thirst, .urgent)
    }

    // MARK: - Quiet times

    func testACallHoldsTheNotificationUntilItEnds() {
        signals.isInMeeting = true
        let feature = running(at: at(10, 5))
        XCTAssertEqual(feature.thirst, .urgent, "the icon still says so")
        XCTAssertTrue(notifier.posted.isEmpty)

        signals.isInMeeting = false
        now = at(10, 30)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testTheCallRuleCanBeSwitchedOff() {
        signals.isInMeeting = true
        now = at(10, 5)
        let feature = makeFeature()
        feature.quietInMeetings = false
        feature.activate()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testComingBackFromALockedLunchGetsGraceThenOneReminder() {
        let feature = running(at: at(9))
        now = at(9, 30)
        signals.isAway = true

        now = at(12)
        feature.evaluate()
        XCTAssertTrue(notifier.posted.isEmpty, "nothing on the lock screen")

        signals.isAway = false
        XCTAssertTrue(notifier.posted.isEmpty, "not the moment you sit down")

        now = at(12, 5)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1)

        now = at(12, 30)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1, "one reminder, not a backlog")
    }

    func testIdleCountsAsAwayAndInputCountsAsBack() {
        let feature = running(at: at(9))
        signals.idleSeconds = 60 * 60
        now = at(11)
        feature.evaluate()
        XCTAssertTrue(notifier.posted.isEmpty)

        signals.idleSeconds = 2
        now = at(11, 1)
        feature.evaluate()
        XCTAssertTrue(notifier.posted.isEmpty, "back after an hour: grace first")

        now = at(11, 6)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1)
    }

    // MARK: - Lifecycle and persistence

    func testDeactivatingStopsEverythingAndWithdrawsTheNotification() {
        let feature = running(at: at(10, 5))
        feature.deactivate()
        XCTAssertEqual(feature.thirst, .none)
        XCTAssertEqual(signals.stopped, 1)
        XCTAssertTrue(notifier.removed.contains(WaterReminderFeature.notificationID))

        now = at(12)
        feature.evaluate()
        XCTAssertEqual(notifier.posted.count, 1, "a switched-off reminder never posts")
    }

    func testLoggingWorksWithRemindersOff() {
        now = at(10)
        let feature = makeFeature()
        feature.logDrink(milliliters: 500)
        XCTAssertEqual(feature.consumedToday, 500)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testTheLogSurvivesARelaunch() {
        now = at(10)
        let first = makeFeature()
        first.logDrink(milliliters: 250)
        first.logDrink(milliliters: 500, at: at(9))
        first.flush()

        let second = makeFeature()
        XCTAssertEqual(second.consumedToday, 750)
        second.undoLast()
        XCTAssertEqual(second.consumedToday, 250, "undo is the last thing logged, the backdated one")
    }

    func testABackdatedDrinkCannotBeInTheFuture() {
        now = at(10)
        let feature = makeFeature()
        feature.logDrink(milliliters: 250, at: at(15))
        XCTAssertEqual(feature.todaysEntries.first?.date, at(10))
    }

    func testTheGlassButtonFollowsTheGlassSize() {
        let feature = running(at: at(8))
        feature.glassMilliliters = 330
        XCTAssertEqual(notifier.categories[WaterReminderFeature.notificationCategory]?.first?.title, "Drank 330 ml")
    }
}
