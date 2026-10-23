import XCTest
@testable import Whiplash

/// Deterministic RNG for quip tests.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class NotchPokeAndPetTests: XCTestCase {
    func testFivePokesInTwoSecondsMakeDizzy() {
        var counter = PokeCounter()
        let times: [TimeInterval] = [10, 10.3, 10.7, 11.2]
        for t in times { XCTAssertFalse(counter.poke(at: t)) }
        XCTAssertTrue(counter.poke(at: 11.9), "fifth poke within 2 s")
        XCTAssertFalse(counter.poke(at: 12.0), "count starts over after dizziness")
    }

    func testSlowPokesNeverMakeDizzy() {
        var counter = PokeCounter()
        for i in 0..<20 { XCTAssertFalse(counter.poke(at: Double(i) * 0.6), "poke \(i)") }
    }

    func testRubbingBackAndForthIsPetting() {
        var detector = PetDetector()
        var petted = false
        var time: TimeInterval = 0
        // Four quick strokes of 12 pt, sampled every 2 pt like real mouse events.
        outer: for stroke in 0..<8 {
            let xs = stride(from: 0, through: 12, by: 2).map { CGFloat($0) }
            for x in stroke.isMultiple(of: 2) ? xs : xs.reversed() {
                time += 0.012
                if detector.feed(x: 100 + x, at: time) { petted = true; break outer }
            }
        }
        XCTAssertTrue(petted)
        XCTAssertLessThan(time, 1.0)
    }

    func testSlowStrokesAndJitterAreNotPetting() {
        var slow = PetDetector()
        var time: TimeInterval = 0
        for stroke in 0..<10 {
            time += 0.8
            XCTAssertFalse(slow.feed(x: stroke.isMultiple(of: 2) ? 100 : 130, at: time))
        }
        var jitter = PetDetector()
        for i in 0..<60 {
            XCTAssertFalse(jitter.feed(x: 100 + (i.isMultiple(of: 2) ? 0 : 3), at: Double(i) * 0.01), "tiny wobble isn't a stroke")
        }
    }

    func testPettingCooldownAndReset() {
        var detector = PetDetector()
        var detections = 0
        var time: TimeInterval = 0
        for stroke in 0..<10 {
            time += 0.05
            if detector.feed(x: stroke.isMultiple(of: 2) ? 100 : 120, at: time) { detections += 1 }
        }
        XCTAssertEqual(detections, 1, "one rub, one detection (cooldown)")
        detector.reset()
        XCTAssertFalse(detector.feed(x: 300, at: time + 5), "first sample after leaving Lash only anchors")
    }

    func testLashStateReactsToPokesAndPets() {
        let model = IslandModel()
        model.soundEnabled = false
        let lash = LashState(model: model)
        for _ in 0..<4 { lash.poke() }
        XCTAssertNil(lash.reaction)
        XCTAssertEqual(lash.squishes, 4)
        XCTAssertTrue(QuipBook.lines(for: .mood(model.mood)).contains(model.quip ?? ""), "a poke earns a quip")
        lash.poke()
        XCTAssertEqual(lash.reaction, .dizzy)
        XCTAssertEqual(lash.expression(for: .happy), .dizzy)
        XCTAssertTrue(QuipBook.lines(for: .dizzy).contains(model.quip ?? ""))

        for i in 0..<12 {
            lash.cursorMoved(to: CGPoint(x: i.isMultiple(of: 2) ? 100 : 124, y: 50), overLash: true)
        }
        XCTAssertEqual(lash.reaction, .blissful)
        XCTAssertEqual(lash.hearts.count, 3)
        XCTAssertTrue(QuipBook.lines(for: .petted).contains(model.quip ?? ""))
    }
}

final class NotchLashStateTests: XCTestCase {
    func testBlinksOnlyWhenTheEyesAreOpen() {
        let model = IslandModel()
        let lash = LashState(model: model)
        XCTAssertTrue(lash.eyesAreOpen)
        model.phase = .snoozed(until: .distantFuture)
        XCTAssertFalse(lash.eyesAreOpen, "a sleeping Lash (hours of snooze) must not redraw to blink")
        model.phase = .whipping
        XCTAssertFalse(lash.eyesAreOpen, "eyes squeezed shut laughing")
        model.phase = .warning(secondsLeft: 3)
        XCTAssertTrue(lash.eyesAreOpen)
    }

    func testHeartsFanOutInsideLashsReach() {
        let model = IslandModel()
        model.soundEnabled = false
        let lash = LashState(model: model)
        for i in 0..<12 { lash.cursorMoved(to: CGPoint(x: i.isMultiple(of: 2) ? 100 : 124, y: 50), overLash: true) }
        let drifts = lash.hearts.map(\.drift)
        XCTAssertEqual(drifts.count, 3)
        XCTAssertTrue(drifts.allSatisfy { (-1...1).contains($0) })
        XCTAssertLessThan(drifts[0], 0, "left")
        XCTAssertGreaterThan(drifts[2], 0, "right")
    }

    func testMoodChipNamesReactions() {
        XCTAssertEqual(MoodChip.name(for: .mood(.suspicious)), "suspicious")
        XCTAssertEqual(MoodChip.name(for: .dizzy), "dizzy")
        XCTAssertEqual(MoodChip.name(for: .blissful), "blissful")
    }
}

final class NotchGazeTests: XCTestCase {
    func testGazePointsAtTheCursorAndIsClamped() {
        let far = Gaze.vector(from: .zero, to: CGPoint(x: 1000, y: 0))
        XCTAssertEqual(far.dx, 1, accuracy: 0.0001)
        XCTAssertEqual(far.dy, 0, accuracy: 0.0001)
        let below = Gaze.vector(from: .zero, to: CGPoint(x: 0, y: 500))
        XCTAssertEqual(below.dy, 1, accuracy: 0.0001, "y down: cursor below → pupils look down")
        let near = Gaze.vector(from: .zero, to: CGPoint(x: 30, y: 40))
        XCTAssertEqual(hypot(near.dx, near.dy), 50 / Gaze.fullDeflectionDistance, accuracy: 0.0001, "eases in close up")
        XCTAssertEqual(Gaze.vector(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5)), .zero)
    }

    func testQuantizationSuppressesTinyMoves() {
        let a = Gaze.quantized(Gaze.vector(from: .zero, to: CGPoint(x: 1000, y: 10)))
        let b = Gaze.quantized(Gaze.vector(from: .zero, to: CGPoint(x: 1000, y: 12)))
        XCTAssertEqual(a, b)
        XCTAssertEqual(Gaze.quantized(CGVector(dx: 0.52, dy: -0.26)).dx, 0.5, accuracy: 0.0001)
    }

    func testLashStatePublishesOnlyVisibleGazeChanges() {
        let lash = LashState(model: IslandModel())
        var publishes = 0
        let sub = lash.$gaze.dropFirst().sink { _ in publishes += 1 }
        for y in 0..<5 { lash.look(at: CGPoint(x: 2000, y: CGFloat(y)), from: .zero) }
        XCTAssertEqual(publishes, 1)
        sub.cancel()
    }
}

final class NotchQuipTests: XCTestCase {
    func testEveryMoodAndTopicHasPlentyOfShortLines() {
        let topics: [QuipTopic] = CritterMood.allCases.map { .mood($0) } + [.dizzy, .petted, .relief, .snoozed]
        for topic in topics {
            let lines = QuipBook.lines(for: topic)
            XCTAssertGreaterThanOrEqual(lines.count, 6, "\(topic)")
            XCTAssertEqual(Set(lines).count, lines.count, "\(topic) has duplicates")
            for line in lines { XCTAssertLessThanOrEqual(line.count, 32, "'\(line)' won't fit the peek lip") }
        }
        for mood in CritterMood.allCases { XCTAssertFalse(QuipBook.status(for: mood).isEmpty) }
    }

    func testPickerDealsTheWholeDeckWithoutRepeats() {
        var picker = QuipPicker()
        var rng = SplitMix64(state: 42)
        let topic = QuipTopic.mood(.smug)
        let all = QuipBook.lines(for: topic)
        var previous: String?
        var firstDeck: [String] = []
        for i in 0..<(all.count * 10) {
            let line = picker.next(for: topic, using: &rng)
            XCTAssertNotEqual(line, previous, "same line twice in a row")
            previous = line
            if i < all.count { firstDeck.append(line) }
        }
        XCTAssertEqual(Set(firstDeck), Set(all), "every line comes up once before any repeats")
    }

    func testPickerKeepsTopicsApart() {
        var picker = QuipPicker()
        var rng = SplitMix64(state: 7)
        XCTAssertTrue(QuipBook.lines(for: .dizzy).contains(picker.next(for: .dizzy, using: &rng)))
        XCTAssertTrue(QuipBook.lines(for: .petted).contains(picker.next(for: .petted, using: &rng)))
    }

    func testWarningLines() {
        XCTAssertEqual(QuipBook.warning(secondsLeft: 5), "5 seconds. you ignored me.")
        XCTAssertTrue(QuipBook.nudge(workSeconds: 50 * 60).hasPrefix("50 min, no break"))
        let lines = (1...5).map { QuipBook.warning(secondsLeft: $0) }
        XCTAssertEqual(Set(lines).count, 5, "a different threat every second")
        for (i, line) in lines.enumerated() { XCTAssertTrue(line.hasPrefix("\(i + 1)"), line) }
        XCTAssertTrue(QuipBook.warning(secondsLeft: 9).contains("9"))
    }
}

final class NotchFormatTests: XCTestCase {
    func testClock() {
        XCTAssertEqual(IslandFormat.clock(83), "1:23")
        XCTAssertEqual(IslandFormat.clock(83.9), "1:23")
        XCTAssertEqual(IslandFormat.clock(120), "2:00")
        XCTAssertEqual(IslandFormat.clock(600), "10:00")
        XCTAssertEqual(IslandFormat.clock(3725), "1:02:05")
        XCTAssertEqual(IslandFormat.clock(-4), "0:00")
    }

    func testRemaining() {
        XCTAssertEqual(IslandFormat.remaining(30), "1m")
        XCTAssertEqual(IslandFormat.remaining(42 * 60 + 5), "43m")
        XCTAssertEqual(IslandFormat.remaining(3600), "1h")
        XCTAssertEqual(IslandFormat.remaining(3900), "1h 5m")
        XCTAssertEqual(IslandFormat.remaining(-10), "1m")
    }

    func testFormattingNeverTraps() {
        XCTAssertEqual(IslandFormat.clock(.nan), "0:00")
        XCTAssertEqual(IslandFormat.clock(.infinity), "0:00")
        XCTAssertEqual(IslandFormat.clock(1e300), "99:59:59")
        XCTAssertEqual(IslandFormat.remaining(.nan), "1m")
        XCTAssertEqual(IslandFormat.remaining(Date.distantFuture.timeIntervalSinceNow), "99h")
    }

    func testSnoozeDurations() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 22, minute: 30))!
        XCTAssertEqual(SnoozeOption.restOfDay.duration(from: lateEvening, calendar: calendar), 90 * 60, accuracy: 0.5)
        XCTAssertEqual(SnoozeOption.fifteenMinutes.duration(from: lateEvening, calendar: calendar), 15 * 60)
        XCTAssertEqual(SnoozeOption.oneHour.duration(), 3600)
    }

    func testThresholdChoices() {
        XCTAssertEqual(ThresholdOption.all.map(\.seconds), [1500, 2700, 3000, 3600, 5400])
        XCTAssertEqual(ThresholdOption.all.map(\.label), ["25m", "45m", "50m", "60m", "90m"])
    }

    func testProgressColoursRunGreenAmberRed() {
        let start = ProgressPalette.rgb(0), mid = ProgressPalette.rgb(0.55), end = ProgressPalette.rgb(1)
        XCTAssertGreaterThan(start.green, start.red)
        XCTAssertGreaterThan(mid.red, 0.9)
        XCTAssertGreaterThan(mid.green, 0.6)
        XCTAssertGreaterThan(end.red, end.green * 3)
        let clamped = ProgressPalette.rgb(7)
        XCTAssertEqual(clamped.red, end.red)
        XCTAssertEqual(clamped.green, end.green)
    }
}

/// Pulling the whip out of the island's right end.
final class NotchWhipPullTests: XCTestCase {
    private let zone = CGRect(x: 300, y: 0, width: 28, height: 37)

    func testPressAndDragPullsTheWhipOutOnce() {
        var pull = WhipPull()
        XCTAssertTrue(pull.press(at: CGPoint(x: 314, y: 18), in: zone))
        XCTAssertTrue(pull.isHolding)
        XCTAssertFalse(pull.drag(to: CGPoint(x: 318, y: 22)), "a wobble isn't a pull")
        XCTAssertTrue(pull.drag(to: CGPoint(x: 314, y: 18 + WhipPull.distance)), "downward, out of the island")
        XCTAssertFalse(pull.isHolding)
        XCTAssertFalse(pull.drag(to: CGPoint(x: 200, y: 300)), "it's out: once")
    }

    func testPullsInAnyDirection() {
        var pull = WhipPull()
        _ = pull.press(at: CGPoint(x: 320, y: 10), in: zone)
        XCTAssertTrue(pull.drag(to: CGPoint(x: 330, y: 10)), "sideways, past the end")
    }

    func testAClickOrAPressElsewhereDoesNothing() {
        var pull = WhipPull()
        _ = pull.press(at: CGPoint(x: 314, y: 18), in: zone)
        pull.release()
        XCTAssertFalse(pull.isHolding)
        XCTAssertFalse(pull.drag(to: CGPoint(x: 314, y: 80)), "let go first: no whip")
        XCTAssertFalse(pull.press(at: CGPoint(x: 250, y: 18), in: zone), "the middle of the wing")
        XCTAssertFalse(pull.drag(to: CGPoint(x: 250, y: 80)))
        XCTAssertFalse(pull.press(at: CGPoint(x: 314, y: 18), in: nil), "Lash has the whip")
    }
}
