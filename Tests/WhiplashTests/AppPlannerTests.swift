import XCTest
@testable import Whiplash

final class AppPlannerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "whiplash.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testStrikesEscalateUpToSix() {
        let strikes = (0...6).map { PunishmentPlanner.strikeCount(escalationLevel: $0, intensity: 1) }
        XCTAssertEqual(strikes, [2, 3, 4, 5, 6, 6, 6])
        XCTAssertEqual(PunishmentPlanner.strikeCount(escalationLevel: -3, intensity: 1), 2)
    }

    func testIntensityScalesStrikes() {
        let gentle = (0...4).map { PunishmentPlanner.strikeCount(escalationLevel: $0, intensity: 0.5) }
        let unhinged = (0...4).map { PunishmentPlanner.strikeCount(escalationLevel: $0, intensity: 2) }
        XCTAssertEqual(gentle, [1, 2, 2, 3, 3], "gentle means fewer, but never zero")
        XCTAssertEqual(unhinged, [4, 6, 6, 6, 6])
        XCTAssertEqual(PunishmentPlanner.strikeCount(escalationLevel: 0, intensity: 0), 1, "out-of-range intensity is clamped")
    }

    func testPlanReflectsSettings() {
        let settings = Settings(defaults: defaults)
        settings.intensity = 2
        let target = CGRect(x: 10, y: 20, width: 800, height: 500)
        let plan = PunishmentPlanner.plan(escalationLevel: 1, settings: settings, targetRect: target, backdrop: nil, message: "HYDRATE, NERD")
        XCTAssertEqual(plan.strikes, 6)
        XCTAssertEqual(plan.intensity, 2)
        XCTAssertEqual(plan.targetRect, target)
        XCTAssertEqual(plan.holdSeconds, PunishmentPlanner.holdSeconds)
        XCTAssertEqual(plan.message, "HYDRATE, NERD")
        XCTAssertTrue(plan.shatter)
        XCTAssertFalse(plan.isManual)

        settings.intensity = 1
        settings.escalate = false
        XCTAssertEqual(PunishmentPlanner.plan(escalationLevel: 3, settings: settings, targetRect: nil, backdrop: nil, message: "").strikes, 2,
                       "escalation off: every whip is a first offence")
    }

    func testWhipsTodayRollsOverAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 23, minute: 58))!
        let tally = WhipTally(defaults: defaults, calendar: calendar, now: { now })

        XCTAssertEqual(tally.today, 0)
        XCTAssertEqual(tally.increment(), 1)
        XCTAssertEqual(tally.increment(), 2)
        XCTAssertEqual(WhipTally(defaults: defaults, calendar: calendar, now: { now }).today, 2, "persisted")

        now = now.addingTimeInterval(3 * 60) // 00:01 the next day
        XCTAssertEqual(tally.today, 0)
        XCTAssertEqual(tally.increment(), 1)
        XCTAssertEqual(defaults.integer(forKey: WhipTally.countKey), 1)
    }

    func testTauntsAvoidRepeatingThemselves() {
        var rng = OverlayRandom(seed: 3)
        var previous: String?
        for _ in 0..<50 {
            let taunt = WhiplashLines.pick(from: WhiplashLines.taunts, avoiding: previous, using: &rng)
            XCTAssertNotEqual(taunt, previous)
            XCTAssertTrue(WhiplashLines.taunts.contains(taunt))
            previous = taunt
        }
        XCTAssertEqual(WhiplashLines.pick(from: ["only"], avoiding: "only", using: &rng), "only")
    }

    func testMenuHeaderFormatting() {
        XCTAssertEqual(StatusMenuController.workLine(work: 2052, threshold: 3000), "Working 34:12 / 50:00")
        XCTAssertEqual(StatusMenuController.workLine(work: 0, threshold: 3000), "Rested · break reminder after 50:00 of work")
        XCTAssertEqual(StatusMenuController.clock(3723), "1:02:03")
        XCTAssertEqual(StatusMenuController.clock(-5), "0:00")
        XCTAssertEqual(StatusMenuController.detailLine(phase: .warning(secondsLeft: 3), whipsToday: 0, totalWhips: 0),
                       "The whip comes out in 3…")
        XCTAssertEqual(StatusMenuController.detailLine(phase: .idle, whipsToday: 2, totalWhips: 17), "Whipped 2× today · 17 all-time")
    }
}
