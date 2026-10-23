import CoreGraphics
import Foundation

/// One fracture line. Every vertex carries the time (seconds after the hit) at which the crack front reaches it,
/// so drawing the crack at time t means: every vertex with arrival ≤ t, plus a partial segment towards the next.
struct CrackLine {
    enum Kind { case radial, fork, ring, micro }

    let kind: Kind
    var points: [FXVec]
    /// Same count as `points`, non-decreasing.
    var arrivals: [Double]
    /// Index of the first vertex of the slow creak tail (== points.count when there is none).
    var tailStart: Int

    init(kind: Kind, points: [FXVec], arrivals: [Double], tailStart: Int? = nil) {
        self.kind = kind
        self.points = points
        self.arrivals = arrivals
        self.tailStart = tailStart ?? points.count
    }

    /// The visible part at time `t`: whole vertices that have arrived plus the interpolated front.
    func visiblePoints(at t: Double) -> [FXVec] {
        guard let first = arrivals.first, t >= first, points.count > 1 else { return [] }
        var out: [FXVec] = [points[0]]
        for i in 1..<points.count {
            if arrivals[i] <= t {
                out.append(points[i])
            } else {
                let span = arrivals[i] - arrivals[i - 1]
                let f = span > 1e-9 ? (t - arrivals[i - 1]) / span : 1
                out.append(points[i - 1] + (points[i] - points[i - 1]) * f)
                break
            }
        }
        return out
    }
}

/// A closed piece of glass bounded by crack lines — a wedge between two neighbouring radials, cut by rings.
/// Rendered slightly displaced and tinted, which is what makes the cracked area read as broken glass.
struct CrackCell {
    var polygon: [FXVec]
    /// When the last crack line enclosing it has arrived.
    var closedAt: Double
}

/// A spiderweb fracture around one impact. Pure data, deterministic for a given seed.
struct CrackPattern {
    let center: FXVec
    let intensity: Double
    var lines: [CrackLine]
    /// Indices into `lines` of the main radial cracks, sorted counter-clockwise by angle.
    var radials: [Int]
    /// The crushed, whitish zone right at the impact point.
    var impactZone: [FXVec]
    var cells: [CrackCell]
    /// Duration of the fast main growth; everything later is creaking.
    let growthDuration: Double
    /// Last arrival of anything (creak tails included).
    var endTime: Double
    /// Everything but the creak tails has arrived by now.
    var settleTime: Double
    /// Farthest main-growth distance from the centre.
    var extent: Double

    /// Tunables, in points and seconds.
    enum Tuning {
        static let radialCount = 8...14
        static let segmentLength = 10.0...28.0
        /// Largest heading change per segment; most kinks are smaller (triangular distribution).
        static let headingJitterDegrees = 13.0
        /// Pull of the heading back towards the radial's direction, per segment: glass cracks run straight with
        /// small kinks rather than wandering.
        static let headingReversion = 0.45
        static let baseLength = 180.0...520.0
        static let growthDuration = 0.2...0.35
        /// Same-pattern radials ignore each other inside this radius (they all start at the centre).
        static let selfArrestRadius = 26.0
    }

    /// Generates a fracture at `center`. `intensity` (≈0.2...2) scales length and density; lines are clipped to
    /// `bounds` and stop where they meet `obstacles` (earlier cracks), like real crack arrest.
    static func generate(center: CGPoint, intensity: CGFloat, bounds: CGRect, seed: UInt64,
                         obstacles: CrackObstacles? = nil) -> CrackPattern {
        var builder = Builder(center: FXVec(center), intensity: Double(intensity), bounds: bounds, seed: seed,
                              external: obstacles)
        return builder.build()
    }

    /// Every segment except the micro-fractures, for the obstacle grid of later cracks.
    func segments() -> [(FXVec, FXVec)] {
        var out: [(FXVec, FXVec)] = []
        for line in lines where line.kind != .micro {
            for i in 1..<max(line.points.count, 1) { out.append((line.points[i - 1], line.points[i])) }
        }
        return out
    }
}

/// Spatial hash of crack segments. New cracks stop where they meet old ones (crack arrest), which is what
/// makes overlapping webs read as real glass instead of scribbles.
struct CrackObstacles {
    private var cells: [Int64: [Int]] = [:]
    private(set) var segments: [(FXVec, FXVec)] = []
    private let cellSize = 32.0

    init() {}

    init(patterns: [CrackPattern]) {
        for pattern in patterns { insert(pattern) }
    }

    mutating func insert(_ pattern: CrackPattern) {
        for (a, b) in pattern.segments() { insert(a, b) }
    }

    mutating func insert(_ a: FXVec, _ b: FXVec) {
        let index = segments.count
        segments.append((a, b))
        forEachCell(a, b) { cells[$0, default: []].append(index) }
    }

    /// The smallest parameter t in (0, 1] at which a→b crosses a stored segment.
    func firstHit(from a: FXVec, to b: FXVec) -> Double? {
        var best: Double?
        var seen = Set<Int>()
        forEachCell(a, b) { key in
            for index in cells[key] ?? [] where seen.insert(index).inserted {
                let (c, d) = segments[index]
                if let t = FXSegment.intersection(a, b, c, d), t < (best ?? 2) { best = t }
            }
        }
        return best
    }

    private func forEachCell(_ a: FXVec, _ b: FXVec, _ body: (Int64) -> Void) {
        let x0 = Int(floor(min(a.x, b.x) / cellSize)), x1 = Int(floor(max(a.x, b.x) / cellSize))
        let y0 = Int(floor(min(a.y, b.y) / cellSize)), y1 = Int(floor(max(a.y, b.y) / cellSize))
        for x in x0...x1 {
            for y in y0...y1 { body(Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(y)))) }
        }
    }
}

// MARK: - Generation

private struct Builder {
    let center: FXVec
    let intensity: Double
    let bounds: CGRect
    var rng: FXRandom
    let external: CrackObstacles?
    var local = CrackObstacles()

    /// A line under construction: points with their path distance from the impact (converted to times later).
    struct Walk {
        var points: [FXVec]
        var distances: [Double]
        /// Stopped by the screen edge or another crack (such lines get no creak tail).
        var blocked = false
    }

    struct Ring {
        var left: Int, right: Int
        /// Vertex index on the left / right radial where the ring attaches.
        var leftVertex: Int, rightVertex: Int
        /// Left → right, endpoints included.
        var points: [FXVec]
        var complete: Bool
        var growsFromLeft: Bool
        /// When the ring has fully grown (set once arrival times are known).
        var finish = 0.0
    }

    init(center: FXVec, intensity: Double, bounds: CGRect, seed: UInt64, external: CrackObstacles?) {
        self.center = center
        self.intensity = intensity.isFinite ? min(max(intensity, 0.2), 2) : 1
        self.bounds = bounds
        self.rng = FXRandom(seed: seed)
        self.external = external
    }

    mutating func build() -> CrackPattern {
        let lengthScale = min(max(intensity, 0.35), 1.6)
        let density = min(intensity, 1.3)
        let growth = FXEase.lerp(CrackPattern.Tuning.growthDuration.lowerBound,
                                 CrackPattern.Tuning.growthDuration.upperBound,
                                 FXEase.clamp01(0.35 + 0.4 * (intensity - 0.5) + rng.signed() * 0.15))

        // Radials: evenly spread, jittered directions.
        let range = CrackPattern.Tuning.radialCount
        let count = min(max(8 + Int((density * 4.5).rounded()) + rng.int(-1...1), range.lowerBound), range.upperBound)
        let spacing = 2 * Double.pi / Double(count)
        let rotation = rng.unit() * 2 * .pi
        var radialWalks: [Walk] = []
        var angles: [Double] = []
        for i in 0..<count {
            let angle = rotation + Double(i) * spacing + rng.signed() * 0.27 * spacing
            let length = FXEase.lerp(CrackPattern.Tuning.baseLength.lowerBound, CrackPattern.Tuning.baseLength.upperBound,
                                     pow(rng.unit(), 0.9)) * lengthScale
            let radial = walk(kind: .radial, from: center, startDistance: 0, heading: angle, length: length)
            // Near a screen edge some directions are clipped away entirely.
            guard radial.points.count > 1 else { continue }
            angles.append(angle)
            radialWalks.append(radial)
        }
        // Creak tails continue the unblocked radials a little, much later.
        var tails: [Walk?] = []
        for i in radialWalks.indices {
            guard !radialWalks[i].blocked, rng.chance(0.7), let last = radialWalks[i].points.last,
                  let lastDistance = radialWalks[i].distances.last else { tails.append(nil); continue }
            let heading = (last - radialWalks[i].points[radialWalks[i].points.count - 2]).angle
            let extra = lastDistance * rng.range(0.05...0.14)
            tails.append(walk(kind: .radial, from: last, startDistance: lastDistance, heading: heading, length: extra,
                              meanHeading: angles[i]))
        }

        // Forks branch off radials (and occasionally off forks).
        var forks: [Walk] = []
        for walkIndex in radialWalks.indices { forks += spawnForks(of: radialWalks[walkIndex], depth: 0) }

        // Arrival times of the main growth: the front covers its path distance with an ease-out in time.
        let mainWalks = radialWalks + forks
        let maxDistance = max(mainWalks.compactMap(\.distances.last).max() ?? 1, 1)
        func arrival(_ distance: Double) -> Double {
            let a = FXEase.clamp01(distance / maxDistance)
            return growth * (1 - cbrt(1 - a))
        }

        var lines: [CrackLine] = []
        var radialLineIndices: [Int] = []
        for (i, radial) in radialWalks.enumerated() {
            var points = radial.points
            var arrivals = radial.distances.map(arrival)
            if let tail = tails[i], tail.points.count > 1 {
                let delay = rng.range(0.1...0.35), duration = rng.range(0.7...1.3)
                let tailLength = max((tail.distances.last ?? 0) - tail.distances[0], 1e-6)
                for j in 1..<tail.points.count {
                    let f = (tail.distances[j] - tail.distances[0]) / tailLength
                    points.append(tail.points[j])
                    arrivals.append(growth + delay + duration * (1 - (1 - f) * (1 - f)))
                }
            }
            radialLineIndices.append(lines.count)
            lines.append(CrackLine(kind: .radial, points: points, arrivals: arrivals, tailStart: radial.points.count))
        }
        for fork in forks { lines.append(CrackLine(kind: .fork, points: fork.points, arrivals: fork.distances.map(arrival))) }

        // Concentric rings bridging neighbouring radials: the spiderweb.
        var rings = makeRings(radialWalks: radialWalks)
        for index in rings.indices {
            let ring = rings[index]
            let left = radialWalks[ring.left], right = radialWalks[ring.right]
            let start = max(arrival(left.distances[ring.leftVertex]), arrival(right.distances[ring.rightVertex]))
                + rng.range(0.004...0.03)
            let speed = rng.range(1400...2400)
            var points = ring.points
            if !ring.growsFromLeft { points.reverse() }
            var arrivals: [Double] = [start]
            var travelled = 0.0
            for j in 1..<points.count {
                travelled += points[j].distance(to: points[j - 1])
                arrivals.append(start + travelled / speed)
            }
            rings[index].finish = arrivals.last ?? start
            if !ring.complete {
                // A ring that gave up half way: keep only the part that grew.
                let keep = max(2, Int(Double(points.count) * rng.range(0.35...0.75)))
                points = Array(points.prefix(keep))
                arrivals = Array(arrivals.prefix(keep))
            }
            lines.append(CrackLine(kind: .ring, points: points, arrivals: arrivals))
        }

        let zoneRadius = 3.5 + 4.5 * min(intensity, 1.5)
        lines += microFractures(zoneRadius: zoneRadius)
        let impactZone = (0..<11).map { i -> FXVec in
            let a = Double(i) / 11 * 2 * .pi + rng.signed() * 0.2
            return center + FXVec.polar(a, zoneRadius * rng.range(0.5...1.0))
        }

        let cells = makeCells(radialWalks: radialWalks, rings: rings)
        let extent = mainWalks.flatMap(\.points).map { $0.distance(to: center) }.max() ?? 0
        let endTime = lines.compactMap(\.arrivals.last).max() ?? growth
        let settleTime = lines.map { $0.arrivals.prefix($0.tailStart).max() ?? 0 }.max() ?? growth
        return CrackPattern(center: center, intensity: intensity, lines: lines, radials: radialLineIndices,
                            impactZone: impactZone, cells: cells, growthDuration: growth, endTime: endTime,
                            settleTime: settleTime, extent: extent)
    }

    // MARK: Random walks

    /// A jittered walk of `length` points of path from `start`. Stops at the bounds and at earlier cracks.
    mutating func walk(kind: CrackLine.Kind, from start: FXVec, startDistance: Double, heading initialHeading: Double,
                       length: Double, meanHeading: Double? = nil, segmentScale: Double = 1) -> Walk {
        var result = Walk(points: [start], distances: [startDistance])
        let mean = meanHeading ?? initialHeading
        var heading = initialHeading
        var travelled = 0.0
        var position = start
        while travelled < length - 1 {
            let segment = min(rng.range(CrackPattern.Tuning.segmentLength) * segmentScale, length - travelled)
            let jitter = (rng.unit() - rng.unit()) * CrackPattern.Tuning.headingJitterDegrees * .pi / 180
            heading += jitter + (mean - heading) * CrackPattern.Tuning.headingReversion
            var next = position + FXVec.polar(heading, segment)
            var stop = false
            if let t = FXSegment.exitParameter(position, next, rect: bounds) {
                next = position + (next - position) * t
                stop = true
            }
            var hit = external?.firstHit(from: position, to: next)
            if position.distance(to: center) > CrackPattern.Tuning.selfArrestRadius,
               let t = local.firstHit(from: position, to: next) {
                hit = min(hit ?? t, t)
            }
            if let t = hit {
                next = position + (next - position) * t
                stop = true
            }
            let step = next.distance(to: position)
            if step > 0.25 {
                if kind != .micro { local.insert(position, next) }
                travelled += step
                position = next
                result.points.append(next)
                result.distances.append(startDistance + travelled)
            }
            if stop { result.blocked = true; break }
        }
        return result
    }

    mutating func spawnForks(of parent: Walk, depth: Int) -> [Walk] {
        guard parent.points.count > 3, let total = parent.distances.last else { return [] }
        let origin = parent.distances[0]
        let span = total - origin
        var forks: [Walk] = []
        let probability = depth == 0 ? 0.075 : 0.03
        for i in 1..<(parent.points.count - 1) {
            let along = (parent.distances[i] - origin) / max(span, 1)
            guard along > 0.18, along < 0.85, rng.chance(probability) else { continue }
            let direction = (parent.points[i + 1] - parent.points[i - 1]).angle
            let heading = direction + rng.sign() * rng.range(0.32...0.72)
            let length = (total - parent.distances[i]) * rng.range(0.3...0.62)
            guard length > 24 else { continue }
            let fork = walk(kind: .fork, from: parent.points[i], startDistance: parent.distances[i], heading: heading,
                            length: length)
            guard fork.points.count > 1 else { continue }
            forks.append(fork)
            if depth < 1 { forks += spawnForks(of: fork, depth: depth + 1) }
        }
        return forks
    }

    // MARK: Rings

    mutating func makeRings(radialWalks: [Walk]) -> [Ring] {
        let lengths = radialWalks.map { $0.points.last?.distance(to: center) ?? 0 }.sorted()
        guard !lengths.isEmpty else { return [] }
        let median = lengths[lengths.count / 2]
        let levels = min(4, max(2, rng.int(2...3) + (intensity > 1.05 ? 1 : 0)))
        let fractions = [0.13, 0.26, 0.41, 0.6]
        let order = radialWalks.indices.sorted {
            (radialWalks[$0].points[1] - center).angle < (radialWalks[$1].points[1] - center).angle
        }
        var rings: [Ring] = []
        for level in 0..<levels {
            let radius = median * (fractions[level] + rng.signed() * 0.025)
            guard radius > 14 else { continue }
            let probability = 0.85 - 0.12 * Double(level)
            for k in order.indices {
                let left = order[k], right = order[(k + 1) % order.count]
                // Each bridge picks its own distance: real concentric cracks are staggered, not circles.
                let local = radius * (1 + rng.signed() * 0.14)
                guard rng.chance(probability),
                      let leftVertex = vertex(on: radialWalks[left], near: local * (1 + rng.signed() * 0.1)),
                      let rightVertex = vertex(on: radialWalks[right], near: local * (1 + rng.signed() * 0.1))
                else { continue }
                let a = radialWalks[left].points[leftVertex], b = radialWalks[right].points[rightVertex]
                rings.append(Ring(left: left, right: right, leftVertex: leftVertex, rightVertex: rightVertex,
                                  points: arc(from: a, to: b), complete: !rng.chance(0.12),
                                  growsFromLeft: rng.chance(0.5)))
            }
        }
        return rings
    }

    /// Main-growth vertex whose distance from the centre is closest to `radius`, if the radial gets that far.
    func vertex(on walk: Walk, near radius: Double) -> Int? {
        guard let last = walk.points.last, last.distance(to: center) > radius * 1.08 else { return nil }
        var best: Int?
        var bestError = Double.infinity
        for i in 1..<walk.points.count {
            let error = abs(walk.points[i].distance(to: center) - radius)
            if error < bestError { bestError = error; best = i }
        }
        return best
    }

    /// A nearly straight, kinked chord between two radial vertices, bowing a little outwards (counter-clockwise
    /// from `a` to `b`) — concentric glass cracks are polygonal, not circles.
    mutating func arc(from a: FXVec, to b: FXVec) -> [FXVec] {
        let chord = b - a
        let length = chord.length
        let steps = max(2, Int(length / 16))
        let normal = chord.perpendicular.normalized * -1
        let bow = length * rng.range(-0.02...0.09)
        var points = [a]
        for i in 1..<steps {
            let t = Double(i) / Double(steps)
            let sag = bow * sin(.pi * t)
            points.append(a + chord * t + normal * sag + chord.perpendicular.normalized * (rng.signed() * 1.4))
        }
        points.append(b)
        return points
    }

    // MARK: Impact detail

    mutating func microFractures(zoneRadius: Double) -> [CrackLine] {
        var lines: [CrackLine] = []
        let count = 16 + Int(10 * min(intensity, 1.5))
        for _ in 0..<count {
            let start = center + FXVec.polar(rng.unit() * 2 * .pi, zoneRadius * rng.range(0.2...1.4))
            let heading = (start - center).angle + rng.signed() * 1.2
            let length = rng.range(6...24) * (0.7 + 0.3 * min(intensity, 1.5))
            let w = walk(kind: .micro, from: start, startDistance: 0, heading: heading, length: length, segmentScale: 0.3)
            guard w.points.count > 1 else { continue }
            let t0 = rng.range(0...0.02)
            lines.append(CrackLine(kind: .micro, points: w.points, arrivals: w.distances.map { t0 + $0 / 900 }))
        }
        // Flakes: tiny concentric chips just around the crushed zone.
        for _ in 0..<rng.int(3...6) {
            let radius = zoneRadius * rng.range(1.5...3.2)
            let a0 = rng.unit() * 2 * .pi, span = rng.range(0.5...1.4)
            let steps = max(2, Int(radius * span / 4))
            let points = (0...steps).map { i -> FXVec in
                center + FXVec.polar(a0 + span * Double(i) / Double(steps), radius + rng.signed() * 0.8)
            }
            let t0 = rng.range(0.01...0.05)
            lines.append(CrackLine(kind: .micro, points: points, arrivals: points.indices.map { t0 + Double($0) * 0.004 }))
        }
        // A few short spikes out of the crushed zone.
        for _ in 0..<rng.int(4...8) {
            let heading = rng.unit() * 2 * .pi
            let start = center + FXVec.polar(heading, zoneRadius * 0.8)
            let w = walk(kind: .micro, from: start, startDistance: 0, heading: heading, length: rng.range(10...34),
                         segmentScale: 0.55)
            guard w.points.count > 1 else { continue }
            lines.append(CrackLine(kind: .micro, points: w.points, arrivals: w.distances.map { $0 / 1500 }))
        }
        return lines
    }

    // MARK: Cells

    /// Closed wedge pieces between neighbouring radials, bounded by complete rings (and the centre).
    func makeCells(radialWalks: [Walk], rings: [Ring]) -> [CrackCell] {
        var cells: [CrackCell] = []
        var byWedge: [Int: [Ring]] = [:]
        for ring in rings where ring.complete { byWedge[ring.left, default: []].append(ring) }
        // Sorted: dictionary order changes between runs, and the cells' order feeds the renderer's random draws.
        for left in byWedge.keys.sorted() {
            let wedgeRings = byWedge[left] ?? []
            let sorted = wedgeRings.sorted { $0.leftVertex + $0.rightVertex < $1.leftVertex + $1.rightVertex }
            var previous: Ring?
            for ring in sorted {
                let prevLeft = previous?.leftVertex ?? 0, prevRight = previous?.rightVertex ?? 0
                guard ring.leftVertex > prevLeft, ring.rightVertex > prevRight else { continue }
                let leftPoints = radialWalks[left].points, rightPoints = radialWalks[ring.right].points
                var polygon = Array(leftPoints[prevLeft...ring.leftVertex])
                polygon += ring.points.dropFirst()
                polygon += rightPoints[prevRight..<ring.rightVertex].reversed()
                if let previous {
                    polygon += previous.points.dropFirst().dropLast().reversed()
                } else if polygon.first == polygon.last {
                    polygon.removeLast()
                }
                // Rings only start once the radials reach them, so the outer ring finishing closes the cell.
                cells.append(CrackCell(polygon: polygon, closedAt: max(ring.finish, previous?.finish ?? 0)))
                previous = ring
            }
        }
        return cells
    }
}
