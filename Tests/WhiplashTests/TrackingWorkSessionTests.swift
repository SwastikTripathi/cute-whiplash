import XCTest
@testable import Whiplash

/// The break reminder's clock: active work since the last real break, for terminal-heavy work.
final class TrackingWorkSessionTests: XCTestCase {
    private let kitty = (id: "net.kovidgoyal.kitty", name: "kitty", pid: pid_t(101))
    private let safari = (id: "com.apple.Safari", name: "Safari", pid: pid_t(201))

    private var suite = ""
    private var defaults: UserDefaults!
    private var settings: Settings!
    private var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// Seconds since the last input; tests move it by hand.
    private var idle: TimeInterval = 0
    private var tracker: WorkSessionTracker!
    private var reminders = 0
    private var breaks = 0

    override func setUp() {
        super.setUp()
        suite = "WhiplashTests.work.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = Settings(defaults: defaults)
        tracker = WorkSessionTracker(settings: settings, now: { [unowned self] in clock }, idleSeconds: { [unowned self] in idle })
        tracker.onThresholdReached = { [unowned self] in reminders += 1 }
        tracker.onBreakTaken = { [unowned self] in breaks += 1 }
        tracker.start()
    }

    override func tearDown() {
        tracker = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func focus(_ app: (id: String, name: String, pid: pid_t)) {
        tracker.handleActivation(bundleID: app.id, name: app.name, pid: app.pid)
    }

    /// Ticks once a second like the real timer, typing all along (idle stays 0) unless `typing` is false.
    private func work(_ seconds: Int, typing: Bool = true) {
        for _ in 0..<seconds {
            clock += 1
            idle = typing ? 0 : idle + 1
            tracker.tick()
        }
    }

    func testDefaults() {
        XCTAssertEqual(settings.thresholdSeconds, 50 * 60)
        XCTAssertEqual(settings.breakSeconds, 5 * 60)
        XCTAssertEqual(settings.repeatSeconds, 20 * 60)
        XCTAssertEqual(settings.nudgeSeconds, 2 * 60)
    }

    func testWorkCountsInTheTerminalAndInOtherAppsBetweenCommands() {
        focus(kitty)
        work(60)
        focus(safari) // reading docs
        work(120)
        XCTAssertEqual(tracker.workSeconds, 180, accuracy: 1, "switching apps doesn't reset or stop the clock")
        XCTAssertEqual(breaks, 0)
    }

    func testNoTerminalNoClock() {
        focus(safari)
        work(600)
        XCTAssertEqual(tracker.workSeconds, 0)
        XCTAssertFalse(tracker.needsTicks, "nothing to measure, no timer")
    }

    func testOtherAppsStopCountingOnceTheTerminalIsLongUnused() {
        focus(kitty)
        work(10)
        focus(safari)
        work(Int(settings.terminalRecencySeconds) + 120)
        XCTAssertEqual(tracker.workSeconds, 10 + settings.terminalRecencySeconds, accuracy: 2)
    }

    func testShortIdlePausesWithoutResetting() {
        focus(kitty)
        work(100)
        work(Int(settings.idlePauseSeconds) + 60, typing: false) // watching a build
        let paused = tracker.workSeconds
        XCTAssertEqual(paused, 100 + settings.idlePauseSeconds, accuracy: 2, "idle beyond the pause window doesn't count")
        work(30)
        XCTAssertEqual(tracker.workSeconds, paused + 30, accuracy: 1)
        XCTAssertEqual(breaks, 0)
    }

    func testARealBreakResetsTheClock() {
        focus(kitty)
        work(1000)
        work(Int(settings.breakSeconds) + 1, typing: false)
        XCTAssertEqual(tracker.workSeconds, 0)
        XCTAssertEqual(breaks, 1)
        focus(safari)
        work(120)
        XCTAssertEqual(tracker.workSeconds, 0, "after a break, the next session starts with the terminal")
        focus(kitty)
        work(5)
        XCTAssertEqual(tracker.workSeconds, 5, accuracy: 1)
    }

    func testTheReminderFiresOnceThenAgainWhenReArmed() {
        tracker.thresholdOverride = 120
        focus(kitty)
        work(119)
        XCTAssertEqual(reminders, 0)
        work(2)
        XCTAssertEqual(reminders, 1)
        work(600)
        XCTAssertEqual(reminders, 1, "fires once; the coordinator decides what's next")

        tracker.remind(after: 300)
        XCTAssertEqual(tracker.nextReminderAt, tracker.workSeconds + 300, accuracy: 0.01)
        work(299)
        XCTAssertEqual(reminders, 1)
        work(2)
        XCTAssertEqual(reminders, 2)
    }

    func testRearmFiresAtOnceWhenOverdue() {
        tracker.thresholdOverride = 60
        focus(kitty)
        work(61)
        XCTAssertEqual(reminders, 1)
        tracker.rearm()
        XCTAssertEqual(reminders, 2)
    }

    func testABreakReArmsAtTheThreshold() {
        tracker.thresholdOverride = 60
        focus(kitty)
        work(61)
        tracker.remind(after: 1200)
        work(Int(settings.breakSeconds) + 1, typing: false)
        XCTAssertEqual(tracker.nextReminderAt, 60)
        focus(kitty)
        work(62)
        XCTAssertEqual(reminders, 2)
    }

    func testSpareMeThisOnceResetsTheClockButNotTheSession() {
        tracker.thresholdOverride = 120
        focus(kitty)
        work(125)
        XCTAssertEqual(reminders, 1)
        tracker.resetWork()
        XCTAssertEqual(tracker.workSeconds, 0)
        XCTAssertEqual(tracker.nextReminderAt, 120, "a full threshold away again")
        XCTAssertEqual(breaks, 0, "sparing isn't a break")
        focus(safari)
        work(30)
        XCTAssertEqual(tracker.workSeconds, 30, accuracy: 1, "still at work: the clock counts up again right away")
        work(91)
        XCTAssertEqual(reminders, 2)
    }

    func testSteppingAwayIsReported() {
        focus(kitty)
        work(10)
        XCTAssertFalse(tracker.isAway)
        work(Int(settings.stepAwaySeconds) + 1, typing: false)
        XCTAssertTrue(tracker.isAway)
        work(1)
        XCTAssertFalse(tracker.isAway)
    }

    func testShortLockKeepsTheSessionLongLockIsABreak() {
        focus(kitty)
        work(300)
        tracker.pause(.screenLocked)
        clock += 60
        tracker.resume([.screenLocked])
        XCTAssertEqual(tracker.workSeconds, 300, accuracy: 1)
        XCTAssertEqual(breaks, 0)

        tracker.pause(.screenLocked)
        clock += settings.breakSeconds + 1
        tracker.resume([.screenLocked])
        XCTAssertEqual(tracker.workSeconds, 0)
        XCTAssertEqual(breaks, 1)
    }

    func testBigClockJumpsAreCapped() {
        focus(kitty)
        work(10)
        clock += 3600 // a stalled timer, not an hour of work
        tracker.tick()
        XCTAssertLessThanOrEqual(tracker.workSeconds, 10 + WorkSessionTracker.maxTickContribution + 0.01)
    }
}
