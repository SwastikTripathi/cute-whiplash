import SpriteKit
import XCTest
@testable import Whiplash

final class WhipStrikeTests: XCTestCase {
    /// Targets all over the lower 85 % of the screen: the far corners, the edges, right under the notch.
    private static let targets: [WhipVec] = [
        WhipVec(847, 514),   // terminal centre
        WhipVec(20, 20),     // bottom-left corner
        WhipVec(1708, 20),   // bottom-right corner
        WhipVec(20, 949),    // left edge, top of the allowed band
        WhipVec(1708, 949),  // right edge, top of the allowed band
        WhipVec(864, 949),   // just under the notch
        WhipVec(864, 30),    // straight down, far
        WhipVec(341, 186),   // terminal bottom-left
        WhipVec(1300, 400),
        WhipVec(560, 760),
    ]

    private struct Outcome {
        var cracks: [(time: Double, point: WhipVec, intensity: Double)] = []
        var whooshes: [Double] = []
        var completions: [Double] = []
    }

    /// Runs `strikes` back to back (each chained from the previous completion) at `fps`.
    private func run(_ strikes: [WhipVec], rig: WhipRig, fps: Double = 60, jitter: Double = 0, seconds: Double = 5) -> Outcome {
        var outcome = Outcome()
        var t = 0.0
        var random = WhipTestRandom(state: 9)
        rig.onEvent = { event in
            switch event {
            case .crack(let point, let intensity): outcome.cracks.append((t, point, intensity))
            case .whoosh: outcome.whooshes.append(t)
            }
        }
        var remaining = strikes
        func next() {
            guard !remaining.isEmpty else { return }
            rig.strike(at: remaining.removeFirst()) {
                outcome.completions.append(t)
                next()
            }
        }
        next()
        while t < seconds, outcome.completions.count < strikes.count {
            let dt = 1 / fps * (1 + jitter * Double.random(in: -1...1, using: &random))
            t += dt
            rig.step(dt: dt)
        }
        return outcome
    }

    private func hangingRig() -> WhipRig {
        let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 380)
        for _ in 0..<90 { rig.step(dt: 1.0 / 60) }
        return rig
    }

    func testEveryStrikeCracksExactlyOnceNearItsTarget() {
        for target in Self.targets {
            let outcome = run([target], rig: hangingRig())
            XCTAssertEqual(outcome.cracks.count, 1, "target \(target)")
            XCTAssertEqual(outcome.whooshes.count, 1)
            XCTAssertEqual(outcome.completions.count, 1)
            guard let crack = outcome.cracks.first, let done = outcome.completions.first else { continue }
            XCTAssertLessThan((crack.point - target).whipLength, 40, "crack at \(crack.point) for target \(target)")
            XCTAssertGreaterThan(crack.intensity, 0)
            XCTAssertLessThanOrEqual(crack.intensity, 1)
            // Whoosh, then crack, then the completion ~0.25 s later; ≈0.8–1.0 s per strike.
            XCTAssertLessThan(outcome.whooshes[0], crack.time)
            XCTAssertEqual(done - crack.time, 0.25, accuracy: 0.03)
            XCTAssertEqual(done, 0.85, accuracy: 0.15)
        }
    }

    /// The crack spends the throw: in the frame it fires, the tip is at the crack (not a fast step further
    /// on), and afterwards the thong drops instead of wheeling on round the hand — it never leaves the top of
    /// the screen, and long ropes wind up steep enough not to run off its sides.
    func testCrackStopsTheTipAtTheTargetAndTheWhipStaysOnScreen() {
        let screen = CGRect(origin: .zero, size: WhipTestScreen.size)
        for target in Self.targets {
            let rig = hangingRig()
            rig.bounds = screen
            var crack: WhipVec?
            var tipAtCrack: WhipVec?
            rig.onEvent = { if case .crack(let point, _) = $0 { crack = point } }
            var done = false
            rig.strike(at: target) { done = true }
            var above = -Double.infinity, sideBeforeCrack = -Double.infinity
            for _ in 0..<150 {
                rig.step(dt: 1.0 / 60)
                if crack != nil, tipAtCrack == nil { tipAtCrack = rig.rope.tip }
                let xs = rig.rope.positions.map(\.x), ys = rig.rope.positions.map(\.y)
                if crack == nil {
                    sideBeforeCrack = max(sideBeforeCrack, max(-(xs.min() ?? 0), (xs.max() ?? 0) - Double(screen.maxX)))
                } else {
                    above = max(above, (ys.max() ?? 0) - Double(screen.maxY))
                }
            }
            XCTAssertTrue(done)
            guard let crack, let tipAtCrack else { XCTFail("no crack for \(target)"); continue }
            XCTAssertLessThan((tipAtCrack - crack).whipLength, 100, "tip far from its crack for target \(target)")
            XCTAssertLessThanOrEqual(above, 0.5, "whip left the top of the screen after cracking at \(target)")
            XCTAssertLessThan(sideBeforeCrack, 60, "wind-up ran off the side for target \(target)")
        }
    }

    func testStrikeFromReeledInUnfurlsFirst() {
        let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 0)
        let target = WhipVec(40, 60)
        let outcome = run([target], rig: rig)
        XCTAssertEqual(outcome.cracks.count, 1)
        if let crack = outcome.cracks.first { XCTAssertLessThan((crack.point - target).whipLength, 40) }
        XCTAssertLessThan(outcome.completions.first ?? 99, 1.25)
    }

    func testChainedStrikesFlowFromOneToTheNext() {
        let targets = [WhipVec(372, 216), WhipVec(1220, 560), WhipVec(780, 750), WhipVec(1650, 60), WhipVec(90, 880)]
        let outcome = run(targets, rig: hangingRig(), jitter: 0.3, seconds: 8)
        XCTAssertEqual(outcome.cracks.count, targets.count)
        XCTAssertEqual(outcome.completions.count, targets.count)
        for (crack, target) in zip(outcome.cracks, targets) {
            XCTAssertLessThan((crack.point - target).whipLength, 40, "crack at \(crack.point) for target \(target)")
        }
        XCTAssertLessThan(outcome.completions.last ?? 99, Double(targets.count) * 1.0)
    }

    /// The anchor is just inside the island's bottom edge and the island draws no handle: Lash's paw (on the whip's
    /// handle) may slide and twist along that edge but never drop out of it.
    func testTheHandStaysAtTheIslandsLipThroughoutAStrike() {
        let anchor = WhipTestScreen.anchor
        let tuning = WhipTuning()
        for target in Self.targets {
            let rig = hangingRig()
            var done = false
            rig.strike(at: target) { done = true }
            var lowest = Double.infinity
            for _ in 0..<120 where !done {
                rig.step(dt: 1.0 / 60)
                lowest = min(lowest, rig.rope.hand.position.y)
            }
            XCTAssertGreaterThanOrEqual(lowest, anchor.y - max(tuning.handDip, tuning.windUpDip) - 0.5, "target \(target)")
        }
    }

    /// A strike queued while the last one follows through takes over after `chainedFollowThrough`, not the full
    /// follow-through — and still lands on its target.
    func testAStrikeQueuedRightAfterACrackChainsSoonerAndStillHits() {
        let rig = hangingRig()
        var t = 0.0
        var cracks: [(time: Double, point: WhipVec)] = []
        var completions: [Double] = []
        rig.onEvent = { if case .crack(let point, _) = $0 { cracks.append((t, point)) } }
        let targets = [WhipVec(700, 400), WhipVec(1000, 520), WhipVec(820, 300), WhipVec(600, 600)]
        var next = 0
        func queue() {
            rig.strike(at: targets[next]) { completions.append(t) }
            next += 1
        }
        queue()
        var queuedAfter = 0
        while t < 6, completions.count < targets.count {
            t += 1.0 / 60
            rig.step(dt: 1.0 / 60)
            // Like the sequencer: 0.1 s after each crack, call the next strike.
            if let last = cracks.last, cracks.count > queuedAfter, next < targets.count, t - last.time >= 0.1 {
                queuedAfter = cracks.count
                queue()
            }
        }
        XCTAssertEqual(cracks.count, targets.count)
        for (crack, target) in zip(cracks, targets) {
            XCTAssertLessThan((crack.point - target).whipLength, 40, "crack at \(crack.point) for target \(target)")
        }
        let gaps = zip(cracks, cracks.dropFirst()).map { $1.time - $0.time }
        for gap in gaps { XCTAssertLessThan(gap, 0.8, "chained strikes come faster than one per 0.8 s") }
    }

    func testCrackLandsTheSameAtAnyFrameRate() {
        let target = WhipVec(1180, 300)
        let reference = run([target], rig: hangingRig(), fps: 60).cracks.first?.point
        for (fps, jitter) in [(120.0, 0.0), (47.0, 0.35), (144.0, 0.2)] {
            let point = run([target], rig: hangingRig(), fps: fps, jitter: jitter).cracks.first?.point
            XCTAssertNotNil(point)
            if let point, let reference { XCTAssertLessThan((point - reference).whipLength, 1, "at \(fps) fps") }
        }
    }

    func testRetractCutsStrikesShortAndStillCompletesThem() {
        let rig = hangingRig()
        var cracks = 0
        var order: [String] = []
        rig.onEvent = { if case .crack = $0 { cracks += 1 } }
        rig.strike(at: WhipVec(500, 400)) { order.append("strike 1") }
        rig.strike(at: WhipVec(900, 300)) { order.append("strike 2") }
        for _ in 0..<12 { rig.step(dt: 1.0 / 60) }
        rig.retract { order.append("retract") }
        for _ in 0..<60 { rig.step(dt: 1.0 / 60) }
        XCTAssertEqual(order, ["strike 1", "strike 2", "retract"])
        XCTAssertEqual(cracks, 0)
        XCTAssertTrue(rig.isRetracted)
    }

    func testManualControlInterruptsScriptedStrikes() {
        let rig = hangingRig()
        var completed = 0
        rig.strike(at: WhipVec(500, 400)) { completed += 1 }
        rig.step(dt: 1.0 / 60)
        rig.beginManualControl(at: WhipVec(800, 800))
        rig.step(dt: 1.0 / 60)
        XCTAssertEqual(completed, 1)
        XCTAssertFalse(rig.isBusy)
        XCTAssertTrue(rig.isManual)
        rig.endManualControl()
        XCTAssertFalse(rig.isManual)
    }
}

final class WhipNodeTests: XCTestCase {
    func testNodeReportsWhooshAndCrackAndCleansUpItsBurst() {
        let scene = SKScene(size: WhipTestScreen.size)
        let whip = WhipNode(anchor: WhipTestScreen.anchor.whipPoint, length: 0)
        scene.addChild(whip)
        var cracks: [(CGPoint, CGFloat)] = []
        var whooshes = 0
        var completed = false
        whip.onCrack = { cracks.append(($0, $1)) }
        whip.onWhoosh = { whooshes += 1 }
        let target = CGPoint(x: 847, y: 514)
        whip.strike(at: target) { completed = true }
        XCTAssertTrue(whip.isBusy)
        func hasBurst() -> Bool { whip.children.contains { $0.children.contains { $0 is WhipCrackBurst } } }
        var t = 0.0
        var sawBurst = false
        while t < 3 {
            t += 1.0 / 60
            whip.step(dt: 1.0 / 60)
            sawBurst = sawBurst || hasBurst()
        }
        XCTAssertTrue(completed)
        XCTAssertFalse(whip.isBusy)
        XCTAssertEqual(whooshes, 1)
        XCTAssertEqual(cracks.count, 1)
        if let crack = cracks.first {
            XCTAssertLessThan(hypot(crack.0.x - target.x, crack.0.y - target.y), 40)
        }
        XCTAssertTrue(sawBurst)
        // The burst fades and removes itself.
        XCTAssertFalse(hasBurst())
    }

    func testLengthPropertyUnfurlsAndRetractHides() {
        let whip = WhipNode(anchor: WhipTestScreen.anchor.whipPoint, length: 0)
        whip.length = 450
        XCTAssertEqual(whip.length, 450)
        for _ in 0..<60 { whip.step(dt: 1.0 / 60) }
        XCTAssertEqual(Double(whip.rig.rope.length), 450, accuracy: 1)
        var done = false
        whip.retract { done = true }
        for _ in 0..<40 { whip.step(dt: 1.0 / 60) }
        XCTAssertTrue(done)
        XCTAssertEqual(whip.length, 0)
        XCTAssertTrue(whip.rig.isRetracted)
    }

    func testEveryComicWordRenders() {
        for word in WhipCrackBurst.words {
            let lettering = WhipCrackBurst.lettering(for: word)
            XCTAssertGreaterThan(lettering.size.width, 100)
            XCTAssertGreaterThan(lettering.size.height, 40)
        }
    }
}
