import AppKit
import Combine
import XCTest
@testable import Whiplash

/// A manual clock for the coordinator's timers.
private final class FakeScheduler: TimerScheduling {
    private(set) var now: TimeInterval = 0
    private var jobs: [(id: Int, due: TimeInterval, action: () -> Void)] = []
    private var nextID = 0

    var pendingCount: Int { jobs.count }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable {
        let id = nextID
        nextID += 1
        jobs.append((id, now + max(0, delay), action))
        return AnyCancellable { [weak self] in self?.jobs.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let end = now + seconds
        while let job = jobs.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            jobs.removeAll { $0.id == job.id }
            now = job.due
            job.action()
        }
        now = end
    }
}

/// Stands in for the overlay: records plans and finishes when told to.
private final class FakePresenter: PunishmentPresenting {
    private(set) var isActive = false
    private(set) var plans: [PunishmentPlan] = []
    private(set) var dismissals = 0
    private var completion: (() -> Void)?
    private var onBeat: ((PunishmentBeat) -> Void)?

    func run(plan: PunishmentPlan, on screen: NSScreen, anchor: CGPoint, onBeat: @escaping (PunishmentBeat) -> Void,
             completion: @escaping () -> Void) {
        isActive = true
        plans.append(plan)
        self.onBeat = onBeat
        self.completion = completion
    }

    func beat(_ beat: PunishmentBeat) {
        onBeat?(beat)
    }

    func dismiss() {
        dismissals += 1
    }

    func finish() {
        isActive = false
        let done = completion
        completion = nil
        onBeat = nil
        done?()
    }
}

final class AppCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: Settings!
    private var scheduler: FakeScheduler!
    private var presenter: FakePresenter!
    private var sound: RecordingSound!
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(NSScreen.screens.isEmpty, "punishments need a display to aim at")
        suiteName = "whiplash.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        settings = Settings(defaults: defaults)
        scheduler = FakeScheduler()
        presenter = FakePresenter()
        sound = RecordingSound()
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeCoordinator(_ arguments: [String] = []) -> AppCoordinator {
        let scheduler = self.scheduler!
        let start = self.start
        var environment = AppCoordinator.Environment()
        environment.settings = settings
        environment.defaults = defaults
        environment.scheduler = scheduler
        environment.now = { start.addingTimeInterval(scheduler.now) }
        environment.sound = sound
        environment.presenter = presenter
        return AppCoordinator(options: LaunchOptions(arguments: ["Whiplash", "--no-capture"] + arguments), environment: environment)
    }

    private let kitty = TerminalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty", pid: 4242)

    func testThresholdNudgesThenCountsDownFiveToOneThenPunishes() {
        settings.nudgeSeconds = 3
        let app = makeCoordinator()
        app.terminalDidChange(kitty)
        app.handleThresholdReached()
        XCTAssertEqual(app.model.phase, .nudge(secondsLeft: 3), "a gentle nudge comes first")
        XCTAssertTrue(WhiplashLines.nudges.contains(app.model.quip ?? ""))
        scheduler.advance(by: 2)
        XCTAssertEqual(app.model.phase, .nudge(secondsLeft: 1))
        XCTAssertEqual(sound.count(.alarm), 0)

        scheduler.advance(by: 1)
        XCTAssertEqual(app.model.phase, .warning(secondsLeft: 5), "ignored: the countdown")
        XCTAssertEqual(sound.count(.alarm), 1)
        var seen: [IslandPhase] = [app.model.phase]
        for _ in 0..<4 {
            scheduler.advance(by: 1)
            seen.append(app.model.phase)
        }
        XCTAssertEqual(seen, (1...5).reversed().map { .warning(secondsLeft: $0) })
        XCTAssertEqual(sound.count(.tick), 4)
        XCTAssertTrue(presenter.plans.isEmpty)

        scheduler.advance(by: 1)
        XCTAssertEqual(app.model.phase, .whipping)
        XCTAssertEqual(presenter.plans.count, 1)
        XCTAssertEqual(presenter.plans.first?.strikes, 2)
        XCTAssertNil(presenter.plans.first?.backdrop, "--no-capture means glass mode")
        XCTAssertTrue(WhiplashLines.taunts.contains(presenter.plans.first?.message ?? ""))
    }

    func testSteppingAwayDuringTheNudgeCallsOffTheWhip() {
        let app = makeCoordinator()
        app.handleThresholdReached()
        scheduler.advance(by: 30)
        guard case .nudge = app.model.phase else { return XCTFail("expected the nudge") }

        app.awayDidChange(true)
        XCTAssertEqual(app.model.phase, .idle)
        XCTAssertEqual(app.model.quip, WhiplashLines.heeded)
        XCTAssertNil(app.nudgeSecondsLeft)
        XCTAssertEqual(app.tracker.nextReminderAt, settings.repeatSeconds, accuracy: 1,
                       "no real break yet: remind again after a while")
        scheduler.advance(by: 600)
        XCTAssertTrue(presenter.plans.isEmpty, "no whip after taking the hint")
    }

    func testSteppingAwayDuringTheCountdownCallsOffTheWhipToo() {
        settings.nudgeSeconds = 1
        let app = makeCoordinator()
        app.handleThresholdReached()
        scheduler.advance(by: 2)
        XCTAssertEqual(app.model.phase, .warning(secondsLeft: 4))
        app.awayDidChange(true)
        XCTAssertNil(app.countdownSecondsLeft)
        scheduler.advance(by: 30)
        XCTAssertTrue(presenter.plans.isEmpty)
    }

    func testSpareMeThisOnceResetsTheTimerAndCallsOffTheWhip() {
        settings.nudgeSeconds = 3
        let app = makeCoordinator()
        app.handleThresholdReached()
        scheduler.advance(by: 1)
        app.spareOnce()
        XCTAssertEqual(app.model.phase, .idle)
        XCTAssertNil(app.nudgeSecondsLeft)
        XCTAssertEqual(app.model.quip, WhiplashLines.spared)
        XCTAssertEqual(app.tracker.workSeconds, 0)
        XCTAssertEqual(app.tracker.nextReminderAt, settings.thresholdSeconds)
        scheduler.advance(by: 60)
        XCTAssertTrue(presenter.plans.isEmpty, "spared")

        app.handleThresholdReached()
        scheduler.advance(by: 4)
        XCTAssertNotNil(app.countdownSecondsLeft)
        app.spareOnce()
        XCTAssertNil(app.countdownSecondsLeft, "the countdown can be called off too")
        scheduler.advance(by: 30)
        XCTAssertTrue(presenter.plans.isEmpty)
    }

    func testSwitchingAppsDoesNotCallItOff() {
        settings.nudgeSeconds = 2
        let app = makeCoordinator()
        app.terminalDidChange(kitty)
        app.handleThresholdReached()
        app.terminalDidChange(nil) // off to the browser
        app.terminalDidChange(TerminalApp(name: "Terminal", bundleID: "com.apple.Terminal", pid: 7))
        scheduler.advance(by: 2 + 5)
        XCTAssertEqual(presenter.plans.count, 1)
    }

    func testSnoozedOrDisabledMeansNoCountdown() {
        let app = makeCoordinator()
        app.snooze(for: 15 * 60)
        XCTAssertEqual(app.model.phase, .snoozed(until: start.addingTimeInterval(15 * 60)))
        app.handleThresholdReached()
        XCTAssertNil(app.countdownSecondsLeft)
        XCTAssertNil(app.nudgeSecondsLeft)

        app.resume()
        XCTAssertEqual(app.model.phase, .idle)
        app.toggleAutoWhip()
        XCTAssertEqual(app.model.phase, .disabled)
        app.handleThresholdReached()
        XCTAssertNil(app.countdownSecondsLeft)
        XCTAssertNil(app.nudgeSecondsLeft)
        scheduler.advance(by: 10)
        XCTAssertTrue(presenter.plans.isEmpty)
    }

    func testSnoozeEndsByItself() {
        let app = makeCoordinator()
        app.snoozeRestOfDay()
        guard case .snoozed(let until) = app.model.phase else { return XCTFail("not snoozed") }
        XCTAssertEqual(Calendar.current.startOfDay(for: until), until, "rest of day ends at midnight")
        scheduler.advance(by: until.timeIntervalSince(start) + 1)
        XCTAssertEqual(app.model.phase, .idle)
        XCTAssertNil(settings.snoozedUntil)
    }

    func testFinishedPunishmentKeepsScoreAndEscalates() {
        let app = makeCoordinator()
        app.terminalDidChange(kitty)
        app.punish()
        XCTAssertEqual(app.model.phase, .whipping)
        XCTAssertTrue(app.isBusy)

        presenter.finish()
        XCTAssertEqual(settings.totalWhips, 1)
        XCTAssertEqual(app.model.totalWhips, 1)
        XCTAssertEqual(app.model.whipsToday, 1)
        XCTAssertEqual(defaults.integer(forKey: WhipTally.countKey), 1)
        XCTAssertEqual(app.model.escalationLevel, 1)
        XCTAssertEqual(app.tracker.nextReminderAt, settings.repeatSeconds, accuracy: 1,
                       "no real break: the next reminder comes after the repeat interval")
        XCTAssertEqual(app.model.phase, .aftermath)
        scheduler.advance(by: AppCoordinator.aftermathSeconds)
        XCTAssertEqual(app.model.phase, .idle)

        app.punish()
        XCTAssertEqual(presenter.plans.last?.strikes, 3, "a repeat offence in the same streak hits harder")
        presenter.finish()
        app.handleBreakTaken()
        XCTAssertEqual(app.model.escalationLevel, 0, "a real break wipes the slate")
    }

    func testThresholdDuringManualModeIsHonouredAfterwards() {
        let app = makeCoordinator()
        app.terminalDidChange(kitty)
        app.grabWhip()
        XCTAssertEqual(app.model.phase, .manual)
        XCTAssertEqual(presenter.plans.first?.isManual, true)

        app.handleThresholdReached()
        XCTAssertNil(app.nudgeSecondsLeft, "no nudge while you hold the whip")
        presenter.finish()
        XCTAssertEqual(app.nudgeSecondsLeft, Int(settings.nudgeSeconds))
        XCTAssertEqual(settings.totalWhips, 0, "whipping the screen yourself does not count")
    }

    /// A threshold that came while the user held the whip, followed by a real break, must not nudge afterwards.
    func testAThresholdPendingFromBeforeABreakIsForgotten() {
        let app = makeCoordinator()
        app.grabWhip()
        app.handleThresholdReached()
        app.handleBreakTaken()
        presenter.finish()
        XCTAssertNil(app.nudgeSecondsLeft)
        XCTAssertNil(app.countdownSecondsLeft)
        XCTAssertEqual(app.model.phase, .idle)
    }

    func testTheIslandPlaysAlongWithTheShow() {
        let app = makeCoordinator()
        app.terminalDidChange(kitty)
        app.punish()
        presenter.beat(.shatter)
        XCTAssertTrue(app.model.laughingHard, "BWAHAHA as the glass gives way")
        XCTAssertEqual(app.model.phase, .whipping)
        scheduler.advance(by: AppCoordinator.bigLaughSeconds + 0.1)
        XCTAssertFalse(app.model.laughingHard)

        presenter.beat(.reassemble)
        XCTAssertEqual(app.model.phase, .aftermath, "smug while the screen rewinds")
        let quip = app.model.quip
        XCTAssertTrue(WhiplashLines.aftermath.contains(quip ?? ""))
        presenter.finish()
        XCTAssertEqual(app.model.phase, .aftermath)
        XCTAssertEqual(app.model.quip, quip, "one smug line, not two")
        XCTAssertEqual(settings.totalWhips, 1)
    }

    func testMuteKeepsTheSavedSoundSettingAlone() {
        let app = makeCoordinator(["--mute"])
        XCTAssertTrue(settings.soundEnabled)
        app.toggleSound()
        XCTAssertTrue(settings.soundEnabled, "--mute must not flip the saved setting")
        XCTAssertFalse(app.model.soundEnabled)
        XCTAssertEqual(app.model.quip, WhiplashLines.muted)
    }

    func testThresholdMenuClearsTheSessionOverride() {
        let app = makeCoordinator(["--threshold", "20"])
        XCTAssertEqual(app.model.thresholdSeconds, 20)
        XCTAssertEqual(app.tracker.thresholdOverride, 20)
        app.setThreshold(300)
        XCTAssertNil(app.tracker.thresholdOverride)
        XCTAssertEqual(settings.thresholdSeconds, 300)
        XCTAssertEqual(app.model.thresholdSeconds, 300)
    }

    func testMirrorsSettingsAndStreakIntoTheModel() {
        let app = makeCoordinator()
        app.workDidChange(61.7)
        XCTAssertEqual(app.model.streakSeconds, 61.7)
        XCTAssertEqual(settings.longestStreakSeconds, 61)
        XCTAssertEqual(app.model.longestStreakSeconds, 61)

        app.toggleSound()
        XCTAssertFalse(app.model.soundEnabled)
        XCTAssertFalse(sound.enabled)
        app.toggleSound()
        XCTAssertTrue(sound.enabled)

        let muted = makeCoordinator(["--mute"])
        XCTAssertFalse(muted.model.soundEnabled)
        XCTAssertFalse(sound.enabled, "--mute wins over the setting")
    }
}
