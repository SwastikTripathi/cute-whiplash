import XCTest
@testable import Whiplash

final class OverlayTargetingTests: XCTestCase {
    private let screen = CGSize(width: 1728, height: 1117)
    private lazy var terminal = FakeBackdrop.terminalRect(for: screen)

    private func targets(_ count: Int, _ rect: CGRect?, seed: UInt64 = 1) -> [CGPoint] {
        var rng = OverlayRandom(seed: seed)
        return StrikeTargeting.targets(count: count, target: rect, sceneSize: screen, using: &rng)
    }

    func testTargetsAreInsideTheInsetTargetRect() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let points = targets(6, terminal, seed: seed)
            XCTAssertEqual(points.count, 6)
            let inset = terminal.insetBy(dx: terminal.width * 0.12, dy: terminal.height * 0.12)
            for point in points {
                XCTAssertTrue(inset.insetBy(dx: -0.5, dy: -0.5).contains(point), "\(point) outside \(inset) (seed \(seed))")
            }
        }
    }

    func testTargetsAreDistinctAndSpreadOut() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let points = targets(6, terminal, seed: seed)
            for i in points.indices {
                for j in points.indices where j > i {
                    let distance = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                    XCTAssertGreaterThan(distance, 60, "strikes \(i) and \(j) nearly overlap (seed \(seed))")
                }
            }
        }
    }

    func testFirstTargetIsTheMiddleOfTheTarget() {
        let region = StrikeTargeting.aimRegion(target: terminal, sceneSize: screen)
        for seed in 1...20 as ClosedRange<UInt64> {
            let first = targets(3, terminal, seed: seed)[0]
            XCTAssertEqual(first.x, region.midX, accuracy: region.width * 0.07)
            XCTAssertGreaterThanOrEqual(first.y, region.minY + region.height * 0.5)
            XCTAssertLessThanOrEqual(first.y, region.minY + region.height * 0.62)
        }
    }

    /// The webs of a volley must overlap so the glass breaks out as ONE hole with room for the taunt: every strike
    /// lands within reach of the first.
    func testTheVolleyIsClustered() {
        for seed in 1...20 as ClosedRange<UInt64> {
            for count in 2...6 {
                let points = targets(count, terminal, seed: seed)
                for point in points.dropFirst() {
                    let distance = hypot(point.x - points[0].x, point.y - points[0].y)
                    XCTAssertLessThanOrEqual(distance, StrikeTargeting.clusterRadius.upperBound * StrikeTargeting.outerRingFactor + 1,
                                             "seed \(seed), \(count) strikes")
                }
            }
        }
    }

    func testFallsBackToTheCentreWithoutAUsableTarget() {
        let central = StrikeTargeting.fallbackRegion(in: screen)
        let offscreen = CGRect(x: 3000, y: 3000, width: 800, height: 600)
        let tiny = CGRect(x: 100, y: 100, width: 60, height: 40)
        for rect in [nil, offscreen, tiny] as [CGRect?] {
            let points = targets(4, rect)
            XCTAssertEqual(points.count, 4)
            for point in points {
                XCTAssertTrue(central.contains(point), "\(point) outside the central fallback for \(String(describing: rect))")
            }
        }
    }

    func testPartlyOffscreenTargetIsClippedToTheVisiblePart() {
        let hanging = CGRect(x: 1400, y: -200, width: 800, height: 700)
        let visible = hanging.intersection(CGRect(origin: .zero, size: screen))
        for point in targets(5, hanging) {
            XCTAssertTrue(visible.contains(point))
        }
    }

    func testStrikesNeverLandUnderTheMenuBar() {
        let fullScreen = CGRect(origin: .zero, size: screen)
        for point in targets(6, fullScreen) {
            XCTAssertLessThan(point.y, screen.height - StrikeTargeting.topExclusion)
        }
    }

    func testTargetingIsDeterministicForASeed() {
        XCTAssertEqual(targets(5, terminal, seed: 99), targets(5, terminal, seed: 99))
        XCTAssertNotEqual(targets(5, terminal, seed: 99), targets(5, terminal, seed: 100))
        XCTAssertEqual(targets(0, terminal), [])
    }

    func testCameraShakeDecaysToRestAndGlassIsSubtler() {
        var shake = CameraShake(profile: .backdrop(intensity: 1), seed: 3)
        shake.add(trauma: 1)
        shake.addPunch(1)
        var peak: CGFloat = 0
        var zoomed = false
        for _ in 0..<30 {
            let pose = shake.step(dt: 1.0 / 60)
            peak = max(peak, hypot(pose.offset.dx, pose.offset.dy))
            zoomed = zoomed || pose.scale < 1
        }
        XCTAssertGreaterThan(peak, 5)
        XCTAssertTrue(zoomed)
        for _ in 0..<120 { _ = shake.step(dt: 1.0 / 60) }
        XCTAssertEqual(shake.step(dt: 1.0 / 60), .rest, "fully decayed after a second and a half")

        let glass = CameraShake.Profile.glass(intensity: 1), backdrop = CameraShake.Profile.backdrop(intensity: 1)
        XCTAssertLessThan(glass.maxOffset, backdrop.maxOffset / 3)
        XCTAssertEqual(glass.maxZoom, 0, "glass mode never zooms off the live pixels")
        XCTAssertLessThan(CameraShake.Profile.backdrop(intensity: 0.5).maxOffset, CameraShake.Profile.backdrop(intensity: 2).maxOffset)
    }
}
