import CoreGraphics
import Foundation

/// Glass around one impact that breaks out when the screen shatters.
struct DamageDisc {
    var center: FXVec
    var radius: Double
    /// The impact's radial cracks (polylines starting at `center`). When given, shards are laid out between them so
    /// the glass breaks along the cracks you saw: radial slivers in spiderweb rows instead of a honeycomb.
    var radials: [[FXVec]] = []

    /// Where a radial crack is `distance` away from the centre (extrapolated straight past its tip).
    func point(on radial: [FXVec], at distance: Double) -> FXVec {
        for i in 1..<radial.count where radial[i].distance(to: center) >= distance {
            let a = radial[i - 1], b = radial[i]
            let da = a.distance(to: center), db = b.distance(to: center)
            return a + (b - a) * FXEase.clamp01((distance - da) / max(db - da, 1e-9))
        }
        guard let last = radial.last, radial.count > 1 else { return center + FXVec.polar(0, distance) }
        let direction = (last - radial[radial.count - 2]).normalized
        return last + direction * max(0, distance - last.distance(to: center))
    }
}

/// Voronoi diagram by half-plane clipping. Every cell remembers which neighbour produced each of its edges,
/// which gives adjacency (for connected holes) and the hole's rim for free.
enum Voronoi {
    struct Cell {
        var site: Int
        /// Counter-clockwise, convex.
        var polygon: [FXVec]
        /// `neighbours[i]` is the site across edge polygon[i] → polygon[i+1], or -1 for the clip rectangle.
        var neighbours: [Int]
    }

    static func cells(sites: [FXVec], clip: CGRect) -> [Cell] {
        let box = [FXVec(clip.minX, clip.minY), FXVec(clip.maxX, clip.minY), FXVec(clip.maxX, clip.maxY), FXVec(clip.minX, clip.maxY)]
        return sites.indices.map { i in
            var polygon = box
            var labels = [-1, -1, -1, -1]
            let site = sites[i]
            let others = sites.indices.filter { $0 != i }.sorted {
                (sites[$0] - site).length < (sites[$1] - site).length
            }
            var reach = polygon.map { $0.distance(to: site) }.max() ?? 0
            for j in others {
                let d = sites[j].distance(to: site)
                // No farther site can cut the cell once its bisector lies beyond the cell's farthest vertex.
                if d / 2 > reach { break }
                guard d > 1e-9 else { continue }
                cut(&polygon, &labels, keepingCloserTo: site, than: sites[j], label: j)
                if polygon.isEmpty { break }
                reach = polygon.map { $0.distance(to: site) }.max() ?? 0
            }
            return Cell(site: i, polygon: polygon, neighbours: labels)
        }
    }

    /// Sutherland–Hodgman against the bisector half-plane, carrying edge labels through.
    private static func cut(_ polygon: inout [FXVec], _ labels: inout [Int], keepingCloserTo a: FXVec, than b: FXVec, label: Int) {
        let normal = b - a
        let mid = (a + b) * 0.5
        let side = { (p: FXVec) in (p - mid).dot(normal) }
        var outPoints: [FXVec] = []
        var outLabels: [Int] = []
        let n = polygon.count
        for i in 0..<n {
            let p = polygon[i], q = polygon[(i + 1) % n]
            let sp = side(p), sq = side(q)
            let pIn = sp <= 0, qIn = sq <= 0
            if pIn {
                outPoints.append(p)
                outLabels.append(labels[i])
                if !qIn {
                    outPoints.append(p + (q - p) * (sp / (sp - sq)))
                    outLabels.append(label)
                }
            } else if qIn {
                outPoints.append(p + (q - p) * (sp / (sp - sq)))
                outLabels.append(labels[i])
            }
        }
        // Drop degenerate slivers produced by numerically coincident vertices.
        var points: [FXVec] = []
        var edgeLabels: [Int] = []
        for i in outPoints.indices where outPoints[i].distance(to: outPoints[(i + 1) % outPoints.count]) > 1e-7 {
            points.append(outPoints[i])
            edgeLabels.append(outLabels[i])
        }
        polygon = points.count >= 3 ? points : []
        labels = points.count >= 3 ? edgeLabels : []
    }
}

/// Uniform grid over the hole: which shard covers each 4-pt cell. O(1) "is this point over the hole?".
struct HoleGrid {
    let origin: FXVec
    let cellSize: Double
    let columns: Int
    let rows: Int
    private(set) var cells: [Int32]

    init(bounds: CGRect, cellSize: Double = 4, shards: [[FXVec]]) {
        self.origin = FXVec(bounds.minX, bounds.minY)
        self.cellSize = cellSize
        columns = max(1, Int(ceil(bounds.width / cellSize)))
        rows = max(1, Int(ceil(bounds.height / cellSize)))
        cells = Array(repeating: -1, count: columns * rows)
        for (index, polygon) in shards.enumerated() {
            let box = FXPolygon.bounds(polygon)
            let c0 = max(0, Int(floor((box.minX - origin.x) / cellSize))), c1 = min(columns - 1, Int(floor((box.maxX - origin.x) / cellSize)))
            let r0 = max(0, Int(floor((box.minY - origin.y) / cellSize))), r1 = min(rows - 1, Int(floor((box.maxY - origin.y) / cellSize)))
            guard c0 <= c1, r0 <= r1 else { continue }
            for r in r0...r1 {
                for c in c0...c1 {
                    let centre = origin + FXVec((Double(c) + 0.5) * cellSize, (Double(r) + 0.5) * cellSize)
                    if FXPolygon.convexContains(polygon, centre) { cells[r * columns + c] = Int32(index) }
                }
            }
        }
    }

    /// The shard whose grid cell contains `p` (cell-accurate; see ShatterPlan.shard(containing:) for exact).
    func shard(at p: FXVec) -> Int? {
        let c = Int(floor((p.x - origin.x) / cellSize)), r = Int(floor((p.y - origin.y) / cellSize))
        guard c >= 0, r >= 0, c < columns, r < rows else { return nil }
        let value = cells[r * columns + c]
        return value >= 0 ? Int(value) : nil
    }
}

/// How the damaged glass breaks: shards (a Voronoi partition of the damage region, dense near impacts),
/// connected holes with their vanishing points, the rim, and a lookup grid.
struct ShatterPlan {
    struct Shard {
        /// Counter-clockwise, convex, scene coordinates.
        var polygon: [FXVec]
        var centroid: FXVec
        var area: Double
        var component: Int
        var nearestImpact: Int
        /// Distance to the nearest impact, normalised by the largest such distance (0 at an impact, 1 at the rim).
        var impactDistance: Double
    }

    /// One connected hole.
    struct Component {
        /// The hole's centre, guaranteed to be inside it.
        var centre: FXVec
        var area: Double
        var bounds: CGRect
    }

    /// An edge between a shard and unbroken glass.
    struct RimEdge {
        var a: FXVec
        var b: FXVec
        var shard: Int
    }

    var shards: [Shard]
    var components: [Component]
    var rim: [RimEdge]
    /// Union of all shard bounds.
    var bounds: CGRect
    var grid: HoleGrid

    static let shardCountRange = 60...160

    /// Fractures the union of `discs` (clipped to `bounds`) into roughly `targetCount` shards.
    static func make(discs: [DamageDisc], bounds: CGRect, seed: UInt64, targetCount: Int? = nil) -> ShatterPlan {
        let discs = discs.filter { $0.radius > 1 }
        let region = discs.reduce(CGRect.null) {
            $0.union(CGRect(x: $1.center.x - $1.radius, y: $1.center.y - $1.radius, width: 2 * $1.radius, height: 2 * $1.radius))
        }
        let clip = region.insetBy(dx: -region.width * 0.2 - 20, dy: -region.height * 0.2 - 20).intersection(bounds)
        guard !discs.isEmpty, !clip.isNull, clip.width > 1, clip.height > 1 else {
            return ShatterPlan(shards: [], components: [], rim: [], bounds: .null, grid: HoleGrid(bounds: .zero, shards: []))
        }
        let target = targetCount ?? Self.defaultTarget(area: coveredArea(discs, clip: clip))
        let (sites, inside) = fittedSites(discs: discs, clip: clip, target: target, seed: seed)
        let cells = Voronoi.cells(sites: sites, clip: clip)
        let broken = withTeeth(cells: cells, inside: inside, discs: discs, seed: seed)

        // Keep the cells whose site is inside the damage region (minus the teeth).
        var shardIndexOfSite = [Int](repeating: -1, count: sites.count)
        var polygons: [[FXVec]] = []
        var keptCells: [Voronoi.Cell] = []
        for cell in cells where broken[cell.site] && cell.polygon.count >= 3 {
            shardIndexOfSite[cell.site] = polygons.count
            polygons.append(cell.polygon)
            keptCells.append(cell)
        }

        // Connected components (union–find over shared edges) and the rim.
        var parent = Array(polygons.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        var rim: [RimEdge] = []
        for (index, cell) in keptCells.enumerated() {
            for e in cell.polygon.indices {
                let neighbour = cell.neighbours[e]
                let other = neighbour >= 0 ? shardIndexOfSite[neighbour] : -1
                if other >= 0 {
                    let a = find(index), b = find(other)
                    if a != b { parent[a] = b }
                } else {
                    rim.append(RimEdge(a: cell.polygon[e], b: cell.polygon[(e + 1) % cell.polygon.count], shard: index))
                }
            }
        }
        var componentOfRoot: [Int: Int] = [:]
        let componentIndex = polygons.indices.map { i -> Int in
            let root = find(i)
            if let c = componentOfRoot[root] { return c }
            componentOfRoot[root] = componentOfRoot.count
            return componentOfRoot.count - 1
        }

        let bounds = polygons.reduce(CGRect.null) { $0.union(FXPolygon.bounds($1)) }
        let grid = HoleGrid(bounds: bounds.insetBy(dx: -4, dy: -4), shards: polygons)

        var shards: [Shard] = polygons.enumerated().map { index, polygon in
            let centroid = FXPolygon.centroid(polygon)
            let nearest = discs.indices.min { centroid.distance(to: discs[$0].center) < centroid.distance(to: discs[$1].center) } ?? 0
            return Shard(polygon: polygon, centroid: centroid, area: abs(FXPolygon.signedArea(polygon)),
                         component: componentIndex[index], nearestImpact: nearest,
                         impactDistance: centroid.distance(to: discs[nearest].center))
        }
        let farthest = max(shards.map(\.impactDistance).max() ?? 1, 1)
        for i in shards.indices { shards[i].impactDistance /= farthest }

        let componentCount = componentOfRoot.count
        var components: [Component] = (0..<componentCount).map { c in
            let members = shards.filter { $0.component == c }
            let area = members.reduce(0) { $0 + $1.area }
            let centre = members.reduce(FXVec.zero) { $0 + $1.centroid * $1.area } / max(area, 1e-9)
            let box = members.reduce(CGRect.null) { $0.union(FXPolygon.bounds($1.polygon)) }
            return Component(centre: centre, area: area, bounds: box)
        }
        // A concave hole's centroid can sit on unbroken glass: fall back to the nearest shard centre.
        for c in components.indices {
            let centre = components[c].centre
            if let s = grid.shard(at: centre), shards[s].component == c { continue }
            if let best = shards.filter({ $0.component == c }).min(by: { $0.centroid.distance(to: centre) < $1.centroid.distance(to: centre) }) {
                components[c].centre = best.centroid
            }
        }
        return ShatterPlan(shards: shards, components: components, rim: rim, bounds: bounds, grid: grid)
    }

    /// Exact lookup: the shard whose polygon contains `p`. Allocation-free: called for every falling letter
    /// every frame.
    func shard(containing p: FXVec) -> Int? {
        if let s = grid.shard(at: p), FXPolygon.convexContains(shards[s].polygon, p) { return s }
        // Near an edge the cell may name a neighbour: check the cells around. The lowest index wins, so a point
        // exactly on a shared edge always resolves the same way.
        let step = grid.cellSize
        var best: Int?
        for dx in -1...1 {
            for dy in -1...1 {
                guard let s = grid.shard(at: p + FXVec(Double(dx) * step, Double(dy) * step)), s < (best ?? .max),
                      FXPolygon.convexContains(shards[s].polygon, p) else { continue }
                best = s
            }
        }
        return best
    }

    /// Share of the pieces along the edge of the damage that stay in the frame as teeth. A few read as jagged
    /// broken glass; many make the rim a row of blocky bites, like a cartoon gear.
    static let toothShare = 0.15
    /// How far into the damage a tooth may reach, as a fraction of the disc radius (deeper ones would stab into
    /// the middle of the hole, where the taunt goes).
    static let toothReach = 0.25

    /// Real broken glass leaves jagged teeth in the frame: some pieces along the edge of the damage stay put, so the
    /// hole's rim is a saw of spikes and notches rather than a smooth blob. Only pieces bordering unbroken glass that
    /// stay within the outer band of the damage, never one holding an impact, only while every broken neighbour stays
    /// attached to at least two others (no piece is cut off on its own), and never below the shard range. Returns
    /// which sites break out.
    static func withTeeth(cells: [Voronoi.Cell], inside: [Bool], discs: [DamageDisc], seed: UInt64) -> [Bool] {
        var broken = inside
        var rng = FXRandom(seed: seed &+ 0x7EE7)
        /// How deep inside the damage a point is (0 on the edge of the union of discs, 1 at an impact).
        func depth(_ p: FXVec) -> Double { discs.map { 1 - p.distance(to: $0.center) / $0.radius }.max() ?? 0 }
        let candidates = cells.filter { cell in
            inside[cell.site] && cell.polygon.count >= 3 && cell.neighbours.contains { $0 < 0 || !inside[$0] }
                && cell.polygon.allSatisfy { depth($0) <= toothReach }
                && !discs.contains { FXPolygon.convexContains(cell.polygon, $0.center) }
        }
        var budget = inside.filter { $0 }.count - (shardCountRange.lowerBound + 4)
        for cell in candidates.shuffled(using: &rng) where budget > 0 && rng.chance(toothShare) {
            let attached = Set(cell.neighbours.filter { $0 >= 0 && broken[$0] }).allSatisfy { n in
                cells[n].neighbours.filter { $0 >= 0 && $0 != cell.site && broken[$0] }.count >= 2
            }
            guard attached else { continue }
            broken[cell.site] = false
            budget -= 1
        }
        return broken
    }

    // MARK: - Sites

    /// ~1 shard per 2600 pt², within the allowed range — with room for a dozen teeth above the minimum.
    static func defaultTarget(area: Double) -> Int {
        min(150, max(shardCountRange.lowerBound + 16, Int(area / 2600)))
    }

    /// Area of the union of discs inside `clip`, by sampling.
    static func coveredArea(_ discs: [DamageDisc], clip: CGRect) -> Double {
        let step = 6.0
        var count = 0
        var y = clip.minY + step / 2
        while y < clip.maxY {
            var x = clip.minX + step / 2
            while x < clip.maxX {
                let p = FXVec(x, y)
                if discs.contains(where: { p.distance(to: $0.center) <= $0.radius }) { count += 1 }
                x += step
            }
            y += step
        }
        return Double(count) * step * step
    }

    /// Finds a site spacing that yields about `target` shards inside the region (bisection on the scale).
    static func fittedSites(discs: [DamageDisc], clip: CGRect, target: Int, seed: UInt64) -> ([FXVec], [Bool]) {
        var lo = 2.0, hi = 400.0
        var best: ([FXVec], [Bool])?
        var bestError = Int.max
        for _ in 0..<18 {
            let scale = (lo * hi).squareRoot()
            let result = sites(discs: discs, clip: clip, spacing: scale, seed: seed)
            let count = result.1.filter { $0 }.count
            let error = abs(count - target)
            if error < bestError { bestError = error; best = result }
            if error <= max(2, target / 20) { break }
            if count > target { lo = scale } else { hi = scale }
        }
        return best ?? ([], [])
    }

    /// Sites in rows around every impact: small shards at the impact, growing towards the rim. With radial cracks
    /// the sites sit in columns between neighbouring cracks (so shard edges follow them) and rows are deeper than
    /// columns are wide (radial slivers); without, plain polar rings. Then thinned so overlapping impacts don't
    /// pile up. A row of sites just outside each disc bounds its outermost shards, and a fence of never-breaking
    /// sites around every disc bounds them again wherever that row was thinned away or fell outside the clip.
    static func sites(discs: [DamageDisc], clip: CGRect, spacing base: Double, seed: UInt64) -> ([FXVec], [Bool]) {
        var rng = FXRandom(seed: seed)
        struct Candidate { var p: FXVec; var gap: Double; var rank: Double }
        var candidates: [Candidate] = []
        for disc in discs {
            let spacing = { (rho: Double) in base * (1 + 2.2 * rho / disc.radius) }
            candidates.append(Candidate(p: disc.center + FXVec.polar(rng.unit() * 2 * .pi, base * 0.15), gap: base * 0.6, rank: 0))
            let radials = disc.radials.filter { $0.count > 1 }.sorted {
                ($0[1] - disc.center).angle < ($1[1] - disc.center).angle
            }
            var rho = base * 0.6
            // Rows out to one lying wholly beyond the disc: it bounds the outermost shards (without it they would
            // stretch out to the clip rectangle as big boxy slabs).
            var bounded = false
            while !bounded {
                let depth = spacing(rho)
                let mid = rho + depth / 2
                bounded = mid - 0.22 * depth > disc.radius
                if radials.count >= 3 {
                    for k in radials.indices {
                        let a = (disc.point(on: radials[k], at: mid) - disc.center).angle
                        var span = (disc.point(on: radials[(k + 1) % radials.count], at: mid) - disc.center).angle - a
                        while span <= 0 { span += 2 * .pi }
                        let columns = max(1, Int((mid * span / (depth * 0.62)).rounded()))
                        let width = mid * span / Double(columns)
                        for c in 0..<columns {
                            let angle = a + span * (Double(c) + 0.5 + rng.signed() * 0.12) / Double(columns)
                            let r = mid + rng.signed() * 0.15 * depth
                            candidates.append(Candidate(p: disc.center + FXVec.polar(angle, r), gap: 0.55 * min(depth, width),
                                                        rank: r / disc.radius))
                        }
                    }
                } else {
                    let count = max(4, Int((2 * .pi * mid / depth).rounded()))
                    let phase = rng.unit() * 2 * .pi
                    for k in 0..<count {
                        let angle = phase + (Double(k) + rng.signed() * 0.28) * 2 * .pi / Double(count)
                        let r = mid + rng.signed() * 0.22 * depth
                        candidates.append(Candidate(p: disc.center + FXVec.polar(angle, r), gap: 0.62 * depth, rank: r / disc.radius))
                    }
                }
                rho += depth
            }
        }
        candidates.sort { $0.rank < $1.rank }

        // Thin with a spatial hash so overlapping discs don't produce slivers.
        let cell = base * 2
        var hash: [Int64: [Int]] = [:]
        var accepted: [Candidate] = []
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y))) }
        for c in candidates where clip.contains(c.p.cgPoint) {
            let cx = Int(floor(c.p.x / cell)), cy = Int(floor(c.p.y / cell))
            let reach = Int(ceil(c.gap / cell))
            var ok = true
            search: for x in (cx - reach)...(cx + reach) {
                for y in (cy - reach)...(cy + reach) {
                    for other in hash[key(x, y)] ?? [] where accepted[other].p.distance(to: c.p) < min(c.gap, accepted[other].gap) {
                        ok = false
                        break search
                    }
                }
            }
            guard ok else { continue }
            hash[key(cx, cy), default: []].append(accepted.count)
            accepted.append(c)
        }
        var points = accepted.map(\.p)
        // The fence: without it an outer shard whose bounding neighbour is missing stretches out into a long arm
        // (sometimes to the screen edge). Its sites lie outside every disc, so they never break.
        let depth = base * 3.2
        for disc in discs {
            let radius = disc.radius + 0.55 * depth
            let count = max(8, Int((2 * .pi * radius / (0.75 * depth)).rounded(.up)))
            let phase = rng.unit() * 2 * .pi
            for k in 0..<count {
                let p = disc.center + FXVec.polar(phase + 2 * .pi * Double(k) / Double(count), radius)
                guard !discs.contains(where: { p.distance(to: $0.center) <= $0.radius * 1.05 }),
                      !points.contains(where: { $0.distance(to: p) < 0.35 * depth }) else { continue }
                points.append(p)
            }
        }
        let inside = points.map { p in discs.contains { p.distance(to: $0.center) <= $0.radius } }
        return (points, inside)
    }
}
