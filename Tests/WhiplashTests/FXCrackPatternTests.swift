import XCTest
@testable import Whiplash

final class FXCrackPatternTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let center = CGPoint(x: 820, y: 520)

    func testRadialCountAndDeterminism() {
        for seed in UInt64(1)...40 {
            let intensity = CGFloat(seed % 5) * 0.3 + 0.4
            let a = CrackPattern.generate(center: center, intensity: intensity, bounds: bounds, seed: seed)
            let b = CrackPattern.generate(center: center, intensity: intensity, bounds: bounds, seed: seed)
            XCTAssertTrue(CrackPattern.Tuning.radialCount.contains(a.radials.count), "seed \(seed): \(a.radials.count) radials")
            XCTAssertEqual(a.lines.count, b.lines.count)
            XCTAssertEqual(a.lines.map(\.points), b.lines.map(\.points))
        }
    }

    func testSegmentsAndArrivals() {
        for seed in UInt64(1)...30 {
            let p = CrackPattern.generate(center: center, intensity: 1, bounds: bounds, seed: seed)
            XCTAssertTrue(CrackPattern.Tuning.growthDuration.contains(p.growthDuration))
            for index in p.radials {
                let line = p.lines[index]
                XCTAssertEqual(line.points.first, FXVec(center))
                XCTAssertEqual(line.arrivals.first ?? -1, 0, accuracy: 1e-9)
                // Every segment but the last one of a walk (clipped / arrested / shortened to the exact length)
                // is 10–28 pt long.
                let lengths = zip(line.points, line.points.dropFirst()).map { $0.distance(to: $1) }
                let interior = lengths.dropLast()
                XCTAssertTrue(interior.allSatisfy { $0 > 1 && $0 <= 28.0001 }, "seed \(seed)")
                XCTAssertGreaterThan(interior.filter { $0 >= 9.999 }.count, interior.count * 8 / 10, "seed \(seed)")
            }
            for line in p.lines {
                XCTAssertEqual(line.points.count, line.arrivals.count)
                XCTAssertTrue(zip(line.arrivals, line.arrivals.dropFirst()).allSatisfy { $0 <= $1 + 1e-12 }, "arrivals must not decrease")
                XCTAssertTrue(line.points.allSatisfy { bounds.insetBy(dx: -0.001, dy: -0.001).contains($0.cgPoint) })
            }
            // The main growth finishes within the growth window; only creak tails arrive later.
            let main = p.lines.filter { $0.kind == .fork }.flatMap(\.arrivals)
            XCTAssertLessThanOrEqual(main.max() ?? 0, p.growthDuration + 1e-9)
            XCTAssertGreaterThan(p.endTime, p.growthDuration, "creak tails extend the crack after the hit")
        }
    }

    func testGrowthIsFastThenCreeping() {
        let p = CrackPattern.generate(center: center, intensity: 1, bounds: bounds, seed: 7)
        func reach(_ t: Double) -> Double {
            p.radials.map { p.lines[$0].visiblePoints(at: t).last?.distance(to: p.center) ?? 0 }.max() ?? 0
        }
        let early = reach(p.growthDuration * 0.25), late = reach(p.growthDuration)
        XCTAssertGreaterThan(early, late * 0.45, "ease-out: a quarter of the time covers most of the distance")
        XCTAssertLessThan(early, late)
    }

    func testLengthScalesWithIntensity() {
        let soft = (1...12).map { CrackPattern.generate(center: center, intensity: 0.5, bounds: bounds, seed: UInt64($0)).extent }
        let hard = (1...12).map { CrackPattern.generate(center: center, intensity: 1, bounds: bounds, seed: UInt64($0)).extent }
        let mean = { (a: [Double]) in a.reduce(0, +) / Double(a.count) }
        XCTAssertGreaterThan(mean(hard), mean(soft) * 1.5)
        XCTAssertTrue(hard.allSatisfy { $0 > 180 && $0 < 600 }, "\(hard)")
    }

    func testSpiderwebRingsBridgeNeighbouringRadials() {
        for seed in UInt64(1)...20 {
            let p = CrackPattern.generate(center: center, intensity: 1, bounds: bounds, seed: seed)
            let rings = p.lines.filter { $0.kind == .ring }
            XCTAssertGreaterThanOrEqual(rings.count, 4, "seed \(seed)")
            let radialVertices = Set(p.radials.flatMap { p.lines[$0].points })
            // Every ring starts on a radial (the side it grew from).
            XCTAssertTrue(rings.allSatisfy { radialVertices.contains($0.points[0]) })
            XCTAssertFalse(p.cells.isEmpty, "rings close wedge cells")
            for cell in p.cells {
                XCTAssertGreaterThanOrEqual(cell.polygon.count, 3)
                XCTAssertGreaterThan(abs(FXPolygon.signedArea(cell.polygon)), 1)
            }
            XCTAssertGreaterThan(p.lines.filter { $0.kind == .micro }.count, 12, "dense micro-fractures at the impact")
        }
    }

    func testClippedToBounds() {
        let corner = CGPoint(x: 30, y: 30)
        let p = CrackPattern.generate(center: corner, intensity: 1.4, bounds: bounds, seed: 3)
        for line in p.lines { XCTAssertTrue(line.points.allSatisfy { bounds.insetBy(dx: -0.001, dy: -0.001).contains($0.cgPoint) }) }
        XCTAssertGreaterThanOrEqual(p.radials.count, 2)
    }

    func testCracksStopAtEarlierCracks() {
        // A wall of existing crack 100 pt to the right: nothing new may cross it.
        var wall = CrackObstacles()
        wall.insert(FXVec(920, 0), FXVec(920, 1117))
        let p = CrackPattern.generate(center: center, intensity: 1.2, bounds: bounds, seed: 11, obstacles: wall)
        for line in p.lines { XCTAssertTrue(line.points.allSatisfy { $0.x <= 920.0001 }, "\(line.kind) crossed the wall") }
        // And some radial actually ends on it (a T-junction).
        XCTAssertTrue(p.radials.contains { abs((p.lines[$0].points.last?.x ?? 0) - 920) < 0.001 })
    }
}
