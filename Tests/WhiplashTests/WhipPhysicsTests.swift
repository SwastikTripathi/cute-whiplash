import XCTest
@testable import Whiplash

/// Deterministic random numbers for the physics tests.
struct WhipTestRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// Scene of the 16" MacBook Pro used throughout the whip tests.
enum WhipTestScreen {
    static let size = CGSize(width: 1728, height: 1117)
    static let anchor = IslandLayout.whipGrip(for: NotchGeometry.demo(size: size)).whipVec
}

extension WhipRope {
    /// Length of the thong's polyline (thong root → tip).
    var polylineLength: Double {
        (1..<(count - 1)).reduce(0) { $0 + (positions[$1 + 1] - positions[$1]).whipLength }
    }
}

final class WhipRopeTests: XCTestCase {
    func testRandomHandMotionStaysFiniteAndInextensible() {
        randomHandMotion(walls: nil)
        // Thrashing against the screen's edges too (the thong is 500 pt, the notch 37 pt from the top).
        let size = WhipTestScreen.size
        randomHandMotion(walls: (0, 0, Double(size.width), Double(size.height)))
    }

    private func randomHandMotion(walls: (minX: Double, minY: Double, maxX: Double, maxY: Double)?) {
        var random = WhipTestRandom(state: 42)
        let anchor = WhipTestScreen.anchor
        var rope = WhipRope(hand: WhipHandPose(position: anchor, angle: -.pi / 2), length: 500)
        rope.walls = walls
        var hand = rope.hand
        var target = hand
        var worstStretch = 0.0
        // 10 s of a hand thrashing around within 120 pt of the notch, at ragged frame times.
        var t = 0.0
        while t < 10 {
            if Double.random(in: 0...1, using: &random) < 0.08 {
                target = WhipHandPose(position: anchor + WhipVec(Double.random(in: -120...120, using: &random),
                                                                 Double.random(in: -120...0, using: &random)),
                                      angle: Double.random(in: -Double.pi...Double.pi, using: &random))
            }
            hand = hand.mixed(with: target, 0.25)
            let dt = 1.0 / 120 * Double.random(in: 0.5...1.5, using: &random)
            rope.step(dt: dt, hand: hand)
            t += dt
            XCTAssertTrue(rope.positions.allSatisfy(\.isWhipFinite))
            worstStretch = max(worstStretch, abs(rope.polylineLength / rope.length - 1))
        }
        XCTAssertEqual(rope.resetCount, 0)
        XCTAssertLessThan(worstStretch, 0.05, "thong length must stay within 5 % (walls: \(walls != nil))")
    }

    func testRigSurvivesGarbageInput() {
        let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 400)
        rig.beginManualControl(at: WhipVec(600, 700))
        for dt in [Double.nan, -1, .infinity, 10, 0, 1.0 / 60] {
            rig.moveHandle(to: WhipVec(.nan, 3))
            rig.step(dt: dt)
        }
        rig.moveHandle(to: WhipVec(1e9, -1e9))
        for _ in 0..<120 { rig.step(dt: 1.0 / 30) }
        XCTAssertTrue(rig.rope.positions.allSatisfy(\.isWhipFinite))
    }

    func testGrowingFromReeledInHangsStraightWithoutKnots() {
        let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 0)
        XCTAssertTrue(rig.isRetracted)
        rig.length = 420
        for _ in 0..<90 { rig.step(dt: 1.0 / 60) }
        XCTAssertFalse(rig.isRetracted)
        XCTAssertEqual(rig.rope.length, 420, accuracy: 1)
        // Hanging straight down: the tip is (almost) a full rope length below the thong root.
        let drop = rig.rope.thongRoot.y - rig.rope.tip.y
        XCTAssertGreaterThan(drop, 0.95 * 420)
    }

    /// Display timestamps jitter around the vsync grid; a steady 60 / 120 Hz display must still get the same
    /// number of fixed ticks every frame, or the whip judders.
    func testJitteryDisplayGetsSteadyTicks() {
        var random = WhipTestRandom(state: 7)
        for (fps, ticksPerFrame) in [(120.0, 1), (60.0, 2)] {
            let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 400)
            var last = 0.0
            for frame in 1...600 {
                let stamp = Double(frame) / fps + Double.random(in: -0.15...0.15, using: &random) / fps
                let before = rig.tickCount
                rig.step(dt: stamp - last)
                last = stamp
                XCTAssertEqual(rig.tickCount - before, ticksPerFrame, "at \(fps) fps, frame \(frame)")
            }
        }
    }

    func testRetractReelsIntoTheNotch() {
        let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 420)
        for _ in 0..<60 { rig.step(dt: 1.0 / 60) }
        var completions = 0
        rig.retract { completions += 1 }
        XCTAssertTrue(rig.isBusy)
        for _ in 0..<40 { rig.step(dt: 1.0 / 60) }
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(rig.isRetracted)
        XCTAssertFalse(rig.isBusy)
        XCTAssertLessThan(rig.rope.length, 2.5)
        XCTAssertEqual(rig.presence, 0)
        // Retracting a whip that is already in is instant.
        rig.retract { completions += 1 }
        rig.step(dt: 1.0 / 60)
        XCTAssertEqual(completions, 2)
    }
}

final class WhipManualTests: XCTestCase {
    private let base = WhipVec(700, 760)

    /// Grabs the whip, plays `mouse(t)` for `duration` seconds at 60 fps and returns crack times.
    private func play(duration: Double, _ mouse: (Double) -> WhipVec) -> [Double] {
        let rig = WhipRig(anchor: WhipTestScreen.anchor, length: 380)
        rig.bounds = CGRect(origin: .zero, size: WhipTestScreen.size)
        for _ in 0..<60 { rig.step(dt: 1.0 / 60) }
        var cracks: [Double] = []
        var t = 0.0
        rig.onEvent = { if case .crack = $0 { cracks.append(t) } }
        rig.beginManualControl(at: mouse(0))
        XCTAssertTrue(rig.isManual)
        while t < duration {
            t += 1.0 / 60
            rig.moveHandle(to: mouse(t))
            rig.step(dt: 1.0 / 60)
        }
        return cracks
    }

    func testSlowMovementNeverCracks() {
        let base = self.base
        let lazyPaths: [(Double) -> WhipVec] = [
            { t in base + WhipVec(160 * sin(t * 1.3), 90 * sin(t * 2.1)) },          // meandering
            { t in base + WhipVec(100 * cos(t * 3.8), 100 * sin(t * 3.8)) },          // circling at ~380 pt/s
            { t in base + WhipVec(0, 120 * sin(t * 2.5)) },                           // bobbing
            { t in base + WhipVec(min(t, 1.2) * 500 - 300, 0) },                      // a 500 pt/s drag, then stop
            { _ in WhipVec(150, 150) },                                               // grabbed far from the notch
        ]
        for (i, path) in lazyPaths.enumerated() {
            XCTAssertEqual(play(duration: 5, path), [], "lazy path \(i) cracked")
        }
    }

    func testQuickFlickCracksOnce() {
        let base = self.base
        for (speed, direction) in [(1500.0, WhipVec(1, 0)), (2000, WhipVec(-1, 0)), (3000, WhipVec(0, 1)), (2500, WhipVec(0.8, 0.6))] {
            // Rest, then cover speed × 0.1 s in 100 ms and stop dead.
            let cracks = play(duration: 3) { t in
                base + direction * (speed * 0.1 * WhipMath.smoothstep((t - 1.5) / 0.1))
            }
            XCTAssertEqual(cracks.count, 1, "flick at \(speed) pt/s toward \(direction)")
            if let crack = cracks.first { XCTAssertEqual(crack, 1.6, accuracy: 0.2) }
        }
    }
}
