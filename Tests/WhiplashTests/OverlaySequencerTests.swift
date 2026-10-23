import XCTest
@testable import Whiplash

/// Drives a PunishmentSequencer on a fake clock with a scripted "stage" standing in for the whip and the FX:
/// each command schedules the inputs the real collaborators would send back, after configurable delays.
private final class FakeStage {
    typealias Command = PunishmentSequencer.Command
    typealias Input = PunishmentSequencer.Input

    let sequencer: PunishmentSequencer
    private(set) var now: TimeInterval = 0
    private(set) var commands: [(time: TimeInterval, command: Command)] = []
    private(set) var phases: [PunishmentSequencer.Phase] = []
    private var pending: [(time: TimeInterval, input: Input)] = []

    /// nil: the whip never reports the strike as done.
    var strikeDuration: TimeInterval? = 0.8
    /// nil: the whip never reports a crack.
    var crackDelay: TimeInterval? = 0.5
    var shatterDuration: TimeInterval? = 1.2
    var reassembleDuration: TimeInterval? = 0.9

    init(_ sequencer: PunishmentSequencer) {
        self.sequencer = sequencer
        phases = [sequencer.phase]
    }

    func send(_ input: Input, after delay: TimeInterval = 0) {
        pending.append((now + delay, input))
    }

    /// Steps at 60 fps until `end` or until the sequence finishes.
    func run(until end: TimeInterval, dt: TimeInterval = 1.0 / 60) {
        while now < end, !sequencer.isFinished {
            now += dt
            let due = pending.filter { $0.time <= now + 1e-9 }
            pending.removeAll { $0.time <= now + 1e-9 }
            for item in due { perform(sequencer.handle(item.input)) }
            perform(sequencer.advance(by: dt))
            if phases.last != sequencer.phase { phases.append(sequencer.phase) }
        }
    }

    var commandList: [Command] { commands.map(\.command) }

    func time(of match: (Command) -> Bool) -> TimeInterval? {
        commands.first { match($0.command) }?.time
    }

    private func perform(_ list: [Command]) {
        for command in list {
            commands.append((now, command))
            switch command {
            case .strike(let index, _):
                if let crackDelay { send(.cracked, after: crackDelay) }
                if let strikeDuration { send(.strikeFinished(index: index), after: strikeDuration) }
            case .shatter:
                if let shatterDuration { send(.shatterFinished, after: shatterDuration) }
            case .reassemble:
                if let reassembleDuration { send(.reassembled, after: reassembleDuration) }
            case .fallbackCrack, .retract, .creak:
                break
            }
        }
    }
}

final class OverlaySequencerTests: XCTestCase {
    private let targets = [CGPoint(x: 100, y: 500), CGPoint(x: 400, y: 200), CGPoint(x: 700, y: 400)]

    private func autoSequencer(strikes: Int = 3, shatters: Bool = true, hold: TimeInterval = 3.5,
                               glyphsReady: Bool = true) -> PunishmentSequencer {
        PunishmentSequencer(mode: .auto, targets: Array(targets.prefix(strikes)), shatters: shatters,
                            holdSeconds: hold, glyphsReady: glyphsReady)
    }

    func testAutoTimelineRunsStrikesThenShatterHoldReassembleAndFinishes() {
        let stage = FakeStage(autoSequencer())
        stage.run(until: 30)
        let s = stage.sequencer

        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.crackCount, 3)
        XCTAssertEqual(s.fallbackCrackCount, 0)
        XCTAssertTrue(s.didShatter)
        XCTAssertEqual(stage.commandList, [
            .strike(index: 0, target: targets[0]), .strike(index: 1, target: targets[1]), .strike(index: 2, target: targets[2]),
            .retract, .creak, .shatter, .reassemble(quick: false),
        ])
        // No gap after a completed strike; from the second strike on the next one is chained 0.1 s after the crack.
        XCTAssertEqual(stage.phases, [
            .intro, .striking(0), .striking(1), .striking(2),
            .creaking, .shattering, .holding, .reassembling(quick: false), .fadingOut(quick: false), .finished,
        ])
        // intro 0.3 + 0.8 strike + (0.5 crack + 0.1 chain) + 0.5 to the final crack + 0.12 final break
        // + 1.2 shatter + 3.5 hold + 0.9 reassemble + 0.6 fade ≈ 8.52 s
        XCTAssertEqual(s.elapsed, 8.52, accuracy: 0.1)
        let shatter = try? XCTUnwrap(stage.time { $0 == .shatter })
        let reassemble = try? XCTUnwrap(stage.time { $0 == .reassemble(quick: false) })
        if let shatter, let reassemble {
            XCTAssertEqual(reassemble - shatter, 1.2 + 3.5, accuracy: 0.05, "hold starts when the shatter completes")
        }
        XCTAssertEqual(s.presentationAlpha, 0)
    }

    func testTheVolleySpeedsUpFromTheSecondStrike() {
        let targets = (0..<5).map { CGPoint(x: 100 + 100 * $0, y: 300) }
        let stage = FakeStage(PunishmentSequencer(mode: .auto, targets: targets, shatters: true, holdSeconds: 1, glyphsReady: true))
        stage.run(until: 30)
        let starts = (0..<5).compactMap { index in
            stage.time { if case .strike(index, _) = $0 { return true } else { return false } }
        }
        XCTAssertEqual(starts.count, 5)
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        // First strike: its whole 0.8 s (whip completion). Then crack (0.5 s) + chain delay (0.1 s).
        XCTAssertEqual(gaps[0], 0.8, accuracy: 0.03)
        for gap in gaps.dropFirst() { XCTAssertEqual(gap, 0.6, accuracy: 0.03) }
        XCTAssertEqual(stage.sequencer.crackCount, 5)
        XCTAssertEqual(stage.sequencer.fallbackCrackCount, 0)
        XCTAssertTrue(stage.sequencer.isFinished)
    }

    func testAChainedStrikeThatNeverCracksStillMovesOn() {
        let stage = FakeStage(autoSequencer())
        stage.crackDelay = nil
        stage.run(until: 30)
        XCTAssertEqual(stage.sequencer.fallbackCrackCount, 3, "no crack, no chaining: each strike waits for its completion")
        XCTAssertTrue(stage.sequencer.isFinished)
    }

    func testStrikeWithoutACrackGetsAFallbackCrackAtItsTarget() {
        let stage = FakeStage(autoSequencer())
        stage.crackDelay = nil
        stage.run(until: 30)

        XCTAssertTrue(stage.sequencer.isFinished)
        XCTAssertEqual(stage.sequencer.crackCount, 3)
        XCTAssertEqual(stage.sequencer.fallbackCrackCount, 3)
        let fallbacks = stage.commandList.compactMap { command -> CGPoint? in
            if case .fallbackCrack(_, let point) = command { return point }
            return nil
        }
        XCTAssertEqual(fallbacks, targets)
    }

    func testWhipThatNeverCompletesTimesOutPerStrike() {
        let stage = FakeStage(autoSequencer())
        stage.strikeDuration = nil
        stage.run(until: 30)
        let s = stage.sequencer

        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.crackCount, 3)
        let secondStrike = try? XCTUnwrap(stage.time { if case .strike(1, _) = $0 { return true } else { return false } })
        XCTAssertEqual(secondStrike ?? 0, 0.3 + s.timing.strikeTimeout + s.timing.strikeGap, accuracy: 0.05)
    }

    func testCollaboratorsThatNeverCompleteStillFinishWithinTheHardTimeout() {
        let stage = FakeStage(autoSequencer())
        stage.strikeDuration = nil
        stage.crackDelay = nil
        stage.shatterDuration = nil
        stage.reassembleDuration = nil
        stage.run(until: 60)

        XCTAssertTrue(stage.sequencer.isFinished)
        XCTAssertLessThan(stage.sequencer.elapsed, stage.sequencer.timing.autoTimeout)
    }

    func testTheFinalHitBreaksTheGlassAtOnceEvenBeforeTheTextArrives() {
        let stage = FakeStage(autoSequencer(glyphsReady: false))
        stage.run(until: 30)
        let finalStrike = stage.time { if case .strike(2, _) = $0 { return true } else { return false } } ?? 0
        let finalCrack = finalStrike + 0.5
        let shatter = stage.time { $0 == .shatter } ?? 0
        XCTAssertEqual(shatter - finalCrack, stage.sequencer.timing.finalBreak, accuracy: 0.03)
        XCTAssertEqual(stage.time { $0 == .retract } ?? 0, finalCrack, accuracy: 0.02, "the whip reels in on the final hit")
        XCTAssertEqual(stage.commandList.filter { $0 == .creak }.count, 1)
    }

    func testWithoutACrackingFinalHitTheShatterWaitsForGlyphsButAtMostTheGrace() {
        let late = FakeStage(autoSequencer(glyphsReady: false))
        late.crackDelay = nil
        late.run(until: 30)
        let creakLate = late.time { $0 == .creak } ?? 0
        let shatterLate = late.time { $0 == .shatter } ?? 0
        XCTAssertEqual(shatterLate - creakLate, 0.35 + 1.0, accuracy: 0.05, "gives up on OCR after the grace")
        XCTAssertGreaterThan(late.commandList.filter { $0 == .creak }.count, 1, "keeps creaking while it waits")

        let onTime = FakeStage(autoSequencer(glyphsReady: false))
        onTime.crackDelay = nil
        onTime.send(.glyphsReady, after: 3.5)
        onTime.run(until: 30)
        let creak = onTime.time { $0 == .creak } ?? 0
        let shatter = onTime.time { $0 == .shatter } ?? 0
        XCTAssertGreaterThan(shatter - creak, 0.35)
        XCTAssertLessThan(shatter - creak, 0.35 + 1.0)
        XCTAssertEqual(shatter, 3.5, accuracy: 0.05, "shatters as soon as the text arrives")
    }

    func testDismissMidwayEndsWithinPointFourSeconds() {
        let stage = FakeStage(autoSequencer())
        stage.run(until: 1.5)
        guard case .striking = stage.sequencer.phase else { return XCTFail("expected a strike in flight") }
        stage.reassembleDuration = nil // even if the FX never reports back
        stage.send(.dismiss)
        let dismissedAt = stage.now
        stage.run(until: 10)

        XCTAssertTrue(stage.sequencer.isFinished)
        XCTAssertLessThanOrEqual(stage.sequencer.elapsed - dismissedAt, 0.4 + 1.0 / 60)
        XCTAssertTrue(stage.commandList.contains(.retract))
        XCTAssertTrue(stage.commandList.contains(.reassemble(quick: true)))
        XCTAssertFalse(stage.commandList.contains(.shatter))
    }

    func testDismissDuringANormalReassemblyHurriesItWithoutReissuingIt() {
        let stage = FakeStage(autoSequencer())
        stage.reassembleDuration = nil
        stage.run(until: 9.0)
        XCTAssertEqual(stage.sequencer.phase, .reassembling(quick: false))
        stage.send(.dismiss)
        stage.run(until: 9.5)
        XCTAssertTrue(stage.sequencer.isFinished)
        XCTAssertEqual(stage.commandList.filter { if case .reassemble = $0 { return true } else { return false } }.count, 1)
    }

    func testAutoHardTimeoutDismisses() {
        let stage = FakeStage(autoSequencer(hold: 60))
        stage.run(until: 50)
        let s = stage.sequencer

        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.elapsed, s.timing.autoTimeout + 0.4, accuracy: 0.05)
        XCTAssertTrue(stage.commandList.contains(.reassemble(quick: true)))
    }

    func testManualHardTimeoutDismisses() {
        let stage = FakeStage(PunishmentSequencer(mode: .manual, targets: targets, shatters: true, holdSeconds: 3.5, glyphsReady: true))
        stage.run(until: 200)
        let s = stage.sequencer

        XCTAssertTrue(s.targets.isEmpty, "manual mode has no scripted strikes")
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.elapsed, s.timing.manualTimeout + 0.4, accuracy: 0.05)
        XCTAssertEqual(stage.commandList, [.retract, .reassemble(quick: true)])
    }

    func testManualShattersAfterSixCracksThenHoldsAndReassembles() {
        let stage = FakeStage(PunishmentSequencer(mode: .manual, targets: [], shatters: true, holdSeconds: 3.5, glyphsReady: true))
        for i in 0..<6 { stage.send(.cracked, after: 0.5 + Double(i) * 0.4) }
        stage.run(until: 30)
        let s = stage.sequencer

        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.crackCount, 6)
        XCTAssertEqual(stage.commandList, [.creak, .shatter, .retract, .reassemble(quick: false)])
        XCTAssertTrue(stage.phases.contains(.holding))
    }

    func testAutoSkipIsOnlyAcceptedWhileTheVoidIsOpen() {
        let stage = FakeStage(autoSequencer())
        stage.run(until: 1.0)
        XCTAssertFalse(stage.sequencer.acceptsSkip)
        stage.send(.skip)
        stage.run(until: 1.1)
        XCTAssertFalse(stage.commandList.contains { if case .reassemble = $0 { return true } else { return false } },
                       "a click while the whip is striking does nothing")

        stage.run(until: 6.0)
        XCTAssertEqual(stage.sequencer.phase, .holding)
        XCTAssertTrue(stage.sequencer.acceptsSkip)
        stage.send(.skip)
        stage.run(until: 6.05)
        XCTAssertEqual(stage.sequencer.phase, .reassembling(quick: false))
        XCTAssertFalse(stage.sequencer.acceptsSkip)
    }

    func testManualSkipReassemblesAtNormalSpeedAnyTime() {
        let stage = FakeStage(PunishmentSequencer(mode: .manual, targets: [], shatters: true, holdSeconds: 3.5, glyphsReady: true))
        stage.run(until: 0.5)
        XCTAssertTrue(stage.sequencer.acceptsSkip)
        stage.send(.skip)
        stage.run(until: 10)

        XCTAssertTrue(stage.sequencer.isFinished)
        XCTAssertEqual(stage.commandList, [.retract, .reassemble(quick: false)])
        XCTAssertFalse(stage.sequencer.didShatter)
    }

    func testCracksOnlyPlanHoldsBrieflyWithoutShattering() {
        let stage = FakeStage(autoSequencer(strikes: 2, shatters: false))
        stage.run(until: 30)

        XCTAssertTrue(stage.sequencer.isFinished)
        XCTAssertFalse(stage.commandList.contains(.shatter))
        XCTAssertFalse(stage.commandList.contains(.creak))
        XCTAssertEqual(stage.sequencer.crackCount, 2)
        XCTAssertTrue(stage.phases.contains(.holding))
    }

    func testDamageStopsOnceTheGlassHasShattered() {
        let s = autoSequencer()
        _ = s.advance(by: 0.31)
        XCTAssertTrue(s.acceptsDamage)
        _ = s.handle(.cracked)
        XCTAssertEqual(s.crackCount, 1)

        let stage = FakeStage(autoSequencer())
        stage.run(until: 3.0) // the shatter runs from ≈ 2.32 s (0.12 s after the final crack) to ≈ 3.52 s
        XCTAssertEqual(stage.sequencer.phase, .shattering)
        XCTAssertFalse(stage.sequencer.acceptsDamage)
        XCTAssertTrue(stage.sequencer.acceptsGlyphs)
        _ = stage.sequencer.handle(.cracked)
        XCTAssertEqual(stage.sequencer.crackCount, 3)
    }

    func testFadeAndTimeScale() {
        let s = autoSequencer()
        XCTAssertEqual(s.presentationAlpha, 1)
        XCTAssertEqual(s.timeScale, 1)
        _ = s.handle(.dismiss)
        XCTAssertEqual(s.phase, .reassembling(quick: true))
        XCTAssertEqual(s.timeScale, s.timing.quickTimeScale)
        _ = s.handle(.reassembled)
        XCTAssertEqual(s.phase, .fadingOut(quick: true))
        _ = s.advance(by: s.timing.quickFade / 2)
        XCTAssertEqual(s.presentationAlpha, 0.5, accuracy: 0.01)
        _ = s.advance(by: s.timing.quickFade)
        XCTAssertTrue(s.isFinished)
        XCTAssertEqual(s.presentationAlpha, 0)
        XCTAssertEqual(s.advance(by: 1), [])
        XCTAssertEqual(s.handle(.dismiss), [])
    }
}
