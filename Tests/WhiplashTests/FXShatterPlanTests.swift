import XCTest
@testable import Whiplash

final class FXShatterPlanTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    func testVoronoiPartitionsTheClipRectWithoutGapsOrOverlaps() {
        var rng = FXRandom(seed: 5)
        let clip = CGRect(x: 100, y: 80, width: 600, height: 420)
        let sites = (0..<140).map { _ in FXVec(rng.range(100...700), rng.range(80...500)) }
        let cells = Voronoi.cells(sites: sites, clip: clip)
        let total = cells.reduce(0) { $0 + abs(FXPolygon.signedArea($1.polygon)) }
        XCTAssertEqual(total, Double(clip.width * clip.height), accuracy: 1e-6 * Double(clip.width * clip.height))
        for cell in cells {
            XCTAssertGreaterThan(FXPolygon.signedArea(cell.polygon), 0, "counter-clockwise")
            XCTAssertEqual(cell.polygon.count, cell.neighbours.count)
            XCTAssertTrue(FXPolygon.convexContains(cell.polygon, sites[cell.site]))
        }
        // Random probes land in exactly one cell (away from shared edges).
        for _ in 0..<3000 {
            let p = FXVec(rng.range(100...700), rng.range(80...500))
            let owners = cells.filter { strictlyInside($0.polygon, p, margin: 1e-6) }
            let onEdge = cells.contains { FXPolygon.convexContains($0.polygon, p) && !strictlyInside($0.polygon, p, margin: 1e-6) }
            if !onEdge { XCTAssertEqual(owners.count, 1) }
        }
        // Adjacency is symmetric.
        for cell in cells {
            for n in cell.neighbours where n >= 0 { XCTAssertTrue(cells[n].neighbours.contains(cell.site)) }
        }
    }

    func testShardCountsStayInRange() {
        let scenarios: [[DamageDisc]] = [
            [DamageDisc(center: FXVec(860, 560), radius: 240)],
            [DamageDisc(center: FXVec(860, 560), radius: 90)],
            [DamageDisc(center: FXVec(700, 500), radius: 250), DamageDisc(center: FXVec(900, 620), radius: 220),
             DamageDisc(center: FXVec(1000, 420), radius: 260)],
            (0..<6).map { DamageDisc(center: FXVec(450 + Double($0) * 160, 300 + Double($0 % 2) * 300), radius: 300) },
            [DamageDisc(center: FXVec(40, 40), radius: 300)],
        ]
        for (i, discs) in scenarios.enumerated() {
            let plan = ShatterPlan.make(discs: discs, bounds: screen, seed: UInt64(i + 1))
            XCTAssertTrue(ShatterPlan.shardCountRange.contains(plan.shards.count), "scenario \(i): \(plan.shards.count) shards")
            // Shards tile the hole: their areas add up to the covered area of the hole grid (±grid resolution).
            let shardArea = plan.shards.reduce(0) { $0 + $1.area }
            let gridArea = Double(plan.grid.cells.filter { $0 >= 0 }.count) * plan.grid.cellSize * plan.grid.cellSize
            XCTAssertEqual(gridArea, shardArea, accuracy: shardArea * 0.05, "scenario \(i)")
            for shard in plan.shards { XCTAssertTrue(shard.polygon.allSatisfy { screen.insetBy(dx: -0.01, dy: -0.01).contains($0.cgPoint) }) }
        }
    }

    func testShardsAreSmallNearImpactsAndPairwiseDisjoint() {
        let disc = DamageDisc(center: FXVec(860, 560), radius: 260)
        let plan = ShatterPlan.make(discs: [disc], bounds: screen, seed: 9)
        let near = plan.shards.filter { $0.centroid.distance(to: disc.center) < 70 }.map(\.area)
        let far = plan.shards.filter { $0.centroid.distance(to: disc.center) > 180 }.map(\.area)
        let mean = { (a: [Double]) in a.reduce(0, +) / Double(max(a.count, 1)) }
        XCTAssertGreaterThan(mean(far), mean(near) * 3, "dense near the impact")

        var rng = FXRandom(seed: 2)
        for _ in 0..<4000 {
            let p = disc.center + FXVec.polar(rng.unit() * 2 * .pi, rng.unit() * 300)
            let owners = plan.shards.indices.filter { strictlyInside(plan.shards[$0].polygon, p, margin: 1e-6) }
            XCTAssertLessThanOrEqual(owners.count, 1, "overlap at \(p)")
            if let owner = owners.first { XCTAssertEqual(plan.shard(containing: p), owner) }
        }
    }

    func testComponentsAndVanishingPoints() {
        let apart = ShatterPlan.make(discs: [DamageDisc(center: FXVec(400, 500), radius: 150),
                                             DamageDisc(center: FXVec(1300, 500), radius: 150)], bounds: screen, seed: 4)
        XCTAssertEqual(apart.components.count, 2)
        let joined = ShatterPlan.make(discs: [DamageDisc(center: FXVec(700, 500), radius: 220),
                                              DamageDisc(center: FXVec(900, 520), radius: 220)], bounds: screen, seed: 4)
        XCTAssertEqual(joined.components.count, 1)
        for plan in [apart, joined] {
            for (c, component) in plan.components.enumerated() {
                let s = plan.shard(containing: component.centre)
                XCTAssertNotNil(s)
                XCTAssertEqual(s.map { plan.shards[$0].component }, c)
            }
            XCTAssertFalse(plan.rim.isEmpty)
        }
    }

    /// The rim is jagged: some pieces along the edge stay in the frame as teeth, but only in the outer band — the
    /// middle of every disc always breaks out, and so do the impacts.
    func testTeethStayInTheOuterBand() {
        let scenarios: [[DamageDisc]] = [
            [DamageDisc(center: FXVec(860, 560), radius: 260)],
            [DamageDisc(center: FXVec(700, 500), radius: 250), DamageDisc(center: FXVec(900, 620), radius: 220),
             DamageDisc(center: FXVec(1000, 420), radius: 160)],
        ]
        for (i, discs) in scenarios.enumerated() {
            let clip = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            let target = ShatterPlan.defaultTarget(area: ShatterPlan.coveredArea(discs, clip: clip))
            let (sites, inside) = ShatterPlan.fittedSites(discs: discs, clip: clip, target: target, seed: UInt64(i + 3))
            let cells = Voronoi.cells(sites: sites, clip: clip)
            let broken = ShatterPlan.withTeeth(cells: cells, inside: inside, discs: discs, seed: UInt64(i + 3))
            let teeth = cells.filter { inside[$0.site] && !broken[$0.site] }
            XCTAssertGreaterThan(teeth.count, 2, "scenario \(i): a jagged rim")
            for tooth in teeth {
                for v in tooth.polygon {
                    let depth = discs.map { 1 - v.distance(to: $0.center) / $0.radius }.max() ?? 0
                    XCTAssertLessThanOrEqual(depth, ShatterPlan.toothReach + 1e-9, "scenario \(i): tooth reaches too deep")
                }
            }
            let plan = ShatterPlan.make(discs: discs, bounds: clip, seed: UInt64(i + 3))
            var rng = FXRandom(seed: 17)
            for disc in discs {
                XCTAssertNotNil(plan.shard(containing: disc.center), "scenario \(i): the impact breaks out")
                for _ in 0..<400 {
                    let p = disc.center + FXVec.polar(rng.unit() * 2 * .pi, rng.unit() * disc.radius * 0.6)
                    XCTAssertNotNil(plan.shard(containing: p), "scenario \(i): hole at \(p)")
                }
            }
            // No shard reaches far beyond its disc (a missing bounding row once stretched rim shards into slabs).
            for shard in plan.shards {
                for v in shard.polygon {
                    XCTAssertTrue(discs.contains { v.distance(to: $0.center) < $0.radius * 1.6 }, "scenario \(i): \(v)")
                }
            }
        }
    }

    private func strictlyInside(_ polygon: [FXVec], _ p: FXVec, margin: Double) -> Bool {
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (b - a).normalized.cross(p - a) <= margin { return false }
        }
        return true
    }
}
