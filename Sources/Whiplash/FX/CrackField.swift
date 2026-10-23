import AppKit
import SpriteKit

/// Look of a crack line, shared by the live SpriteKit strokes and the Core Graphics bake at shatter time so the
/// two are interchangeable.
enum CrackStyle {
    struct Stroke {
        let width: CGFloat
        let alpha: CGFloat
    }

    /// Bright hairlines: three widths from the impact outwards (thicker where the glass took the hit), each in a
    /// lit and a dim variant (segments facing the light catch it), plus thin fading tips.
    static let strokes: [Stroke] = [
        Stroke(width: 1.4, alpha: 0.92), Stroke(width: 1.4, alpha: 0.6),
        Stroke(width: 1.1, alpha: 0.88), Stroke(width: 1.1, alpha: 0.55),
        Stroke(width: 0.8, alpha: 0.85), Stroke(width: 0.8, alpha: 0.5),
        Stroke(width: 0.55, alpha: 0.42),
    ]
    static let shadowColor = NSColor(white: 0, alpha: 0.35)
    static let shadowWidth: CGFloat = 1.25
    static let shadowOffset = FXVec(0.7, -0.7)
    static let glowColor = NSColor(white: 1, alpha: 0.09)
    static let glowWidth: CGFloat = 4
    static let zoneFill = NSColor(white: 1, alpha: 0.55)
    static let zoneStroke = NSColor(white: 1, alpha: 0.85)
    /// Direction the light comes from (radians); segments perpendicular to it stay dim.
    static let lightAngle = 0.6
    /// Thin, fading crack tips (and creak tails).
    static let tipStroke = 6

    /// Which stroke a segment uses.
    static func stroke(for kind: CrackLine.Kind, distance: Double, extent: Double, along: Double, direction: FXVec) -> Int {
        if (kind == .radial || kind == .fork), along > 0.82 { return tipStroke }
        let band: Int
        if kind == .micro {
            band = 2
        } else {
            let f = distance / max(extent, 1)
            band = f < 0.2 ? 0 : f < 0.5 ? 1 : 2
        }
        let lit = abs(cos(direction.angle - lightAngle)) > 0.42 || kind == .micro
        return band * 2 + (lit ? 0 : 1)
    }
}

/// The paths of one crack at one moment: everything (for shadow and glow) plus one path per stroke style.
struct CrackPaths {
    /// Which segments: the slow creak tails change for over a second after a hit while everything else has long
    /// settled, so they are drawn by separate nodes and the big settled paths are not rebuilt every frame.
    enum Part { case all, settled, tails }

    let all = CGMutablePath()
    let strokes = CrackStyle.strokes.map { _ in CGMutablePath() }

    /// `hidden` leaves out every part where it returns true, cut exactly where it flips — e.g. whatever lies over
    /// the hole (after the shatter those parts fell in with the shards).
    init(pattern: CrackPattern, time: Double, part: Part = .all, hidden: ((FXVec) -> Bool)? = nil) {
        var allEnd: FXVec?
        var strokeEnds = [FXVec?](repeating: nil, count: strokes.count)
        for line in pattern.lines {
            guard line.points.count > 1, time >= line.arrivals[0] else { continue }
            var total = 0.0
            for i in 1..<line.points.count { total += line.points[i].distance(to: line.points[i - 1]) }
            var travelled = 0.0
            for i in 1..<line.points.count {
                let isTail = i >= line.tailStart
                if (part == .settled && isTail) || (part == .tails && !isTail) {
                    travelled += line.points[i].distance(to: line.points[i - 1])
                    continue
                }
                let a = line.points[i - 1]
                var b = line.points[i]
                let full = b.distance(to: a)
                let partial = line.arrivals[i] > time
                if partial {
                    let span = line.arrivals[i] - line.arrivals[i - 1]
                    b = a + (b - a) * (span > 1e-9 ? (time - line.arrivals[i - 1]) / span : 1)
                }
                if let (p, q) = Self.visiblePart(a, b, hidden: hidden) {
                    let style = isTail ? CrackStyle.tipStroke
                        : CrackStyle.stroke(for: line.kind, distance: ((a + b) * 0.5).distance(to: pattern.center),
                                            extent: pattern.extent, along: (travelled + full / 2) / max(total, 1), direction: b - a)
                    Self.append(p, q, to: all, end: &allEnd)
                    Self.append(p, q, to: strokes[style], end: &strokeEnds[style])
                }
                travelled += full
                if partial { break }
            }
        }
    }

    /// Continues the current subpath when the segment starts where the last one ended (round joins), else starts one.
    private static func append(_ a: FXVec, _ b: FXVec, to path: CGMutablePath, end: inout FXVec?) {
        if end != a { path.move(to: a.cgPoint) }
        path.addLine(to: b.cgPoint)
        end = b
    }

    /// The part of a→b that is not hidden (cut exactly at the boundary), or nil if it is all hidden.
    static func visiblePart(_ a: FXVec, _ b: FXVec, hidden: ((FXVec) -> Bool)?) -> (FXVec, FXVec)? {
        guard let hidden else { return (a, b) }
        let aHidden = hidden(a), bHidden = hidden(b)
        if aHidden && bHidden { return nil }
        if !aHidden && !bHidden { return (a, b) }
        var lo = 0.0, hi = 1.0
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if hidden(a + (b - a) * mid) == aHidden { lo = mid } else { hi = mid }
        }
        let crossing = a + (b - a) * ((lo + hi) / 2)
        return aHidden ? (crossing, b) : (a, crossing)
    }

    /// Splits a polyline into its visible runs.
    static func visibleRuns(_ points: [FXVec], hidden: ((FXVec) -> Bool)?) -> [[FXVec]] {
        var runs: [[FXVec]] = []
        var current: [FXVec] = []
        for i in 1..<points.count {
            guard let (p, q) = visiblePart(points[i - 1], points[i], hidden: hidden) else {
                if current.count > 1 { runs.append(current) }
                current = []
                continue
            }
            if current.last != p {
                if current.count > 1 { runs.append(current) }
                current = [p]
            }
            current.append(q)
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }
}

/// Draws every crack: animated growth and creak, the refraction cells, glints; hides what fell into the hole;
/// retracts on rewind. Owns two layers the DestructionLayer places: `cellLayer` (just above the backdrop) and
/// `lineLayer` (above the text).
final class CrackField {
    let cellLayer = SKNode()
    let lineLayer = SKNode()

    private final class Crack {
        let pattern: CrackPattern
        let born: Double
        let node = SKNode()
        let glow = SKShapeNode()
        let shadow = SKShapeNode()
        let strokes = CrackStyle.strokes.map { _ in SKShapeNode() }
        /// The creak tails: shadow + thin tip line, rebuilt while they creep.
        let tailShadow = SKShapeNode()
        let tail = SKShapeNode()
        var shownSettled = -1.0
        let zone: SKShapeNode
        let haze = SKSpriteNode(texture: FXTextures.softDot)
        var shownTime = -1.0
        var cells: [Cell] = []
        var nextGlint: Double
        var sweep: (start: Double, direction: FXVec, from: Double, to: Double)?
        var retractFrom = 0.0
        /// Growth and creak stopped here (the glass broke); nil for a crack still free to grow.
        var frozenAt: Double?

        init(pattern: CrackPattern, born: Double) {
            self.pattern = pattern
            self.born = born
            nextGlint = born + pattern.growthDuration + 0.04
            zone = SKShapeNode(path: FXPolygon.path(pattern.impactZone, offset: pattern.center))
        }
    }

    private struct Cell {
        let node: SKSpriteNode
        let home: FXVec
        let offset: FXVec
        let closedAt: Double
        let brightness: Double
        let sheen: Double
        /// What the node currently shows (appearance, sheen): settled cells aren't touched again.
        var shown = (appear: -1.0, sheen: -1.0)
    }

    private let backdrop: SKTexture?
    private let sceneSize: CGSize
    private let particles: FXParticles
    private var rng: FXRandom
    private var cracks: [Crack] = []
    private var hole: ((FXVec) -> Bool)?
    private var retract: (start: Double, duration: Double)?
    /// How far the rewind has got, 0...1 (0 before it starts).
    private var retractProgress = 0.0

    init(sceneSize: CGSize, backdrop: SKTexture?, particles: FXParticles, seed: UInt64) {
        self.sceneSize = sceneSize
        self.backdrop = backdrop
        self.particles = particles
        rng = FXRandom(seed: seed)
    }

    var patterns: [CrackPattern] { cracks.map(\.pattern) }
    var isEmpty: Bool { cracks.isEmpty }

    /// Existing crack lines, which new cracks stop at.
    var obstacles: CrackObstacles { CrackObstacles(patterns: patterns) }

    /// Each crack with how far it is drawn right now (pattern time), for baking.
    var snapshot: [(pattern: CrackPattern, time: Double)] { cracks.map { ($0.pattern, max($0.shownTime, 0)) } }

    /// Each crack with its main growth complete, for baking ahead of time (before it has got that far).
    var settledSnapshot: [(pattern: CrackPattern, time: Double)] { cracks.map { ($0.pattern, $0.pattern.settleTime) } }

    /// Every crack has finished its main growth (only creak tails may still be moving).
    func isSettled(at time: Double) -> Bool {
        cracks.allSatisfy { patternTime($0, at: time) >= $0.pattern.settleTime }
    }

    // MARK: - Commands

    func add(_ pattern: CrackPattern, at time: Double) {
        let crack = Crack(pattern: pattern, born: time)
        crack.glow.strokeColor = CrackStyle.glowColor
        crack.glow.lineWidth = CrackStyle.glowWidth
        crack.shadow.strokeColor = CrackStyle.shadowColor
        crack.shadow.lineWidth = CrackStyle.shadowWidth
        crack.shadow.position = CrackStyle.shadowOffset.cgPoint
        for (i, stroke) in crack.strokes.enumerated() {
            stroke.strokeColor = NSColor(white: 1, alpha: CrackStyle.strokes[i].alpha)
            stroke.lineWidth = CrackStyle.strokes[i].width
        }
        crack.tailShadow.strokeColor = CrackStyle.shadowColor
        crack.tailShadow.lineWidth = CrackStyle.shadowWidth
        crack.tailShadow.position = CrackStyle.shadowOffset.cgPoint
        crack.tail.strokeColor = NSColor(white: 1, alpha: CrackStyle.strokes[CrackStyle.tipStroke].alpha)
        crack.tail.lineWidth = CrackStyle.strokes[CrackStyle.tipStroke].width
        // Explicit layers (glow, shadows, hairlines, crushed zone), so the look holds with ignoresSiblingOrder too.
        // Fractions: z adds up through the tree, and all of it must stay below the particles' layer.
        for (shape, z) in [(crack.glow, 0.0), (crack.shadow, 0.1), (crack.tailShadow, 0.1)] + crack.strokes.map({ ($0, 0.2) })
            + [(crack.tail, 0.2)] {
            shape.zPosition = CGFloat(z)
            // Bevel joins and butt caps: invisible on hairlines, and SpriteKit tessellates round ones as curves,
            // which dominated the frame time.
            shape.lineCap = .butt
            shape.lineJoin = .bevel
            shape.fillColor = .clear
            shape.isAntialiased = true
            crack.node.addChild(shape)
        }
        let zoneRadius = FXPolygon.bounds(pattern.impactZone).width / 2
        crack.haze.size = CGSize(width: zoneRadius * 6, height: zoneRadius * 6)
        crack.haze.alpha = 0.32
        crack.haze.position = pattern.center.cgPoint
        crack.zone.position = pattern.center.cgPoint
        crack.zone.fillColor = CrackStyle.zoneFill
        crack.zone.strokeColor = CrackStyle.zoneStroke
        crack.zone.lineWidth = 0.6
        crack.haze.zPosition = 0.3
        crack.zone.zPosition = 0.4
        crack.node.addChild(crack.haze)
        crack.node.addChild(crack.zone)
        lineLayer.addChild(crack.node)
        crack.cells = makeCells(for: pattern)
        cracks.append(crack)

        let intensity = pattern.intensity
        particles.emitChips(at: pattern.center, count: Int(14 + 12 * min(intensity, 1.5)), speed: 70...380,
                            size: 2.5...6.5)
        particles.emitSparkle(at: pattern.center, size: 46 * min(max(intensity, 0.6), 1.4), life: 0.26)
        render(crack, at: 0)
    }

    /// Stops growth and creak (the glass is about to break) and drops the refraction cells. Cracks added later (a
    /// smash in the break) grow as usual.
    func freeze(at time: Double) {
        for crack in cracks {
            crack.frozenAt = time
            crack.sweep = nil
            for cell in crack.cells { cell.node.removeFromParent() }
            crack.cells = []
        }
    }

    /// Lets the creak tails move again (a shatter that could not break anything).
    func thaw() {
        for crack in cracks { crack.frozenAt = nil }
    }

    /// Hides everything over the hole (those parts are now baked into the falling shards); nil shows it all again.
    func setHole(_ test: ((FXVec) -> Bool)?, at time: Double) {
        hole = test
        for crack in cracks { render(crack, at: patternTime(crack, at: time), force: true) }
    }

    func beginRetract(at time: Double, duration: Double) {
        guard retract == nil else { return }
        for crack in cracks { crack.retractFrom = min(patternTime(crack, at: time), crack.pattern.endTime) }
        retract = (time, duration)
    }

    var isRetracted: Bool { retract != nil && cracks.allSatisfy { $0.shownTime <= 0 } }

    func removeAll() {
        cellLayer.removeAllChildren()
        lineLayer.removeAllChildren()
        cracks = []
        hole = nil
        retract = nil
        retractProgress = 0
    }

    // MARK: - Per frame

    func step(time: Double) {
        retractProgress = retract.map { FXEase.clamp01((time - $0.start) / $0.duration) } ?? 0
        // The web zips back into the impact and fades as it goes, so nothing pops off at the end.
        let fade = CGFloat(1 - FXEase.smoothstep(0.55, 1, retractProgress))
        for crack in cracks {
            if crack.node.alpha != fade { crack.node.alpha = fade }
            let t = patternTime(crack, at: time)
            if abs(t - crack.shownTime) > 1e-6 { render(crack, at: t) }
            updateCells(crack, patternTime: t, time: time)
            if retract == nil, time >= crack.nextGlint {
                emitGlint(on: crack, patternTime: t)
                crack.nextGlint = time + rng.range(2.0...3.4)
            }
        }
    }

    /// How far the crack is drawn: clamped to its end, so a finished crack stops rebuilding (re-tessellating)
    /// its paths every frame.
    private func patternTime(_ crack: Crack, at time: Double) -> Double {
        var t = min(time - crack.born, crack.pattern.endTime)
        if let frozenAt = crack.frozenAt { t = min(t, frozenAt - crack.born) }
        guard let retract else { return max(t, 0) }
        let u = FXEase.clamp01((time - retract.start) / retract.duration)
        let growth = crack.pattern.growthDuration
        let from = crack.retractFrom
        // Rewind in space rather than time: creak tails first, then the main growth zips back into the impact.
        func mainTime(reach: Double) -> Double { growth * (1 - cbrt(1 - FXEase.clamp01(reach))) }
        if from > growth {
            if u < 0.25 { return from - (from - growth) * (u / 0.25) }
            return mainTime(reach: 1 - FXEase.inOutCubic((u - 0.25) / 0.75))
        }
        let reach0 = 1 - pow(1 - from / growth, 3)
        return mainTime(reach: reach0 * (1 - FXEase.inOutCubic(u)))
    }

    private func render(_ crack: Crack, at t: Double, force: Bool = false) {
        crack.shownTime = t
        // The settled part stops changing a few tenths of a second after the hit; only the tails keep creeping.
        let settled = min(t, crack.pattern.settleTime)
        if force || settled != crack.shownSettled {
            crack.shownSettled = settled
            let paths = CrackPaths(pattern: crack.pattern, time: settled, part: .settled, hidden: hole)
            crack.glow.path = paths.all
            crack.shadow.path = paths.all
            for (i, stroke) in crack.strokes.enumerated() { stroke.path = paths.strokes[i] }
        }
        let tails = CrackPaths(pattern: crack.pattern, time: t, part: .tails, hidden: hole)
        crack.tailShadow.path = tails.all
        crack.tail.path = tails.strokes[CrackStyle.tipStroke]
        // The crushed zone pops in with the hit and shrinks away with the rewind (no lingering asterisk).
        let zoneScale = CGFloat(FXEase.outCubic(t / 0.05) * (1 - retractProgress))
        let zoneHidden = hole?(crack.pattern.center) ?? false
        crack.zone.setScale(zoneScale)
        crack.haze.setScale(zoneScale)
        crack.zone.isHidden = zoneHidden || t <= 0
        crack.haze.isHidden = crack.zone.isHidden
    }

    // MARK: - Refraction cells

    /// One batched sprite per cell (see `GlassPieces`), cut out by a small mask atlas of this crack's cells.
    private func makeCells(for pattern: CrackPattern) -> [Cell] {
        guard !pattern.cells.isEmpty else { return [] }
        let atlas = GlassPieces.MaskAtlas(polygons: pattern.cells.map(\.polygon), edgeWidth: 0)
        let masks = atlas.bitmap.texture()
        let shader = GlassPieces.shader(backdrop != nil ? .backdropCell : .glassCell,
                                        uniforms: GlassPieces.Uniforms(masks: masks))
        return pattern.cells.enumerated().map { index, source in
            let centroid = FXPolygon.centroid(source.polygon)
            let box = atlas.boxes[index]
            let node: SKSpriteNode
            if let backdrop {
                node = GlassPieces.sprite(texture: backdrop,
                                          textureRect: CGRect(x: box.minX / sceneSize.width, y: box.minY / sceneSize.height,
                                                              width: box.width / sceneSize.width, height: box.height / sceneSize.height),
                                          box: box, pivot: centroid, maskCell: atlas.cells[index], shader: shader)
            } else {
                node = GlassPieces.sprite(texture: masks, textureRect: atlas.cells[index], box: box, pivot: centroid,
                                          maskCell: atlas.cells[index], shader: shader)
            }
            // Near the impact the glass is more chaotic.
            let nearness = 1 - FXEase.clamp01(centroid.distance(to: pattern.center) / max(pattern.extent, 1))
            let offset = FXVec.polar(rng.unit() * 2 * .pi, rng.range(0.4...0.9) + 0.6 * nearness)
            let brightness = rng.chance(0.5) ? rng.range(0.86...0.97) : rng.range(1.03...1.12)
            let sheen = rng.chance(0.3) ? rng.range(0.005...0.02) : 0
            node.isHidden = true
            cellLayer.addChild(node)
            return Cell(node: node, home: centroid, offset: offset, closedAt: source.closedAt, brightness: brightness, sheen: sheen)
        }
    }

    private func updateCells(_ crack: Crack, patternTime t: Double, time: Double) {
        guard !crack.cells.isEmpty else { return }
        if crack.sweep == nil, retract == nil, time - crack.born >= crack.pattern.growthDuration, time - crack.born < crack.pattern.growthDuration + 0.05 {
            let direction = FXVec.polar(rng.unit() * 2 * .pi)
            let span = crack.pattern.extent
            crack.sweep = (time, direction, crack.pattern.center.dot(direction) - span, crack.pattern.center.dot(direction) + span)
        }
        var sweepPosition: Double?
        if let sweep = crack.sweep {
            let u = (time - sweep.start) / 0.75
            if u > 1 { crack.sweep = nil } else { sweepPosition = FXEase.lerp(sweep.from, sweep.to, FXEase.inOutCubic(u)) }
        }
        // On rewind the cells settle back first.
        let retractFade = retract.map { 1 - FXEase.clamp01((time - $0.start) / ($0.duration * 0.5)) } ?? 1
        for index in crack.cells.indices {
            let cell = crack.cells[index]
            let appear = FXEase.outCubic((t - cell.closedAt) / 0.12) * retractFade
            var sheen = cell.sheen
            if let position = sweepPosition, let direction = crack.sweep?.direction {
                let d = (cell.home.dot(direction) - position) / 55
                sheen += 0.12 * exp(-d * d)
            }
            guard appear != cell.shown.appear || sheen != cell.shown.sheen else { continue }
            crack.cells[index].shown = (appear, sheen)
            cell.node.isHidden = appear <= 0
            guard appear > 0 else { continue }
            if backdrop != nil {
                cell.node.position = (cell.home + cell.offset * appear).cgPoint
                GlassPieces.setShade(brightness: FXEase.lerp(1, cell.brightness, appear), opacity: 1, sheen: sheen * appear, on: cell.node)
            } else {
                // Glass mode: nothing to displace, just faint reflections off each piece.
                GlassPieces.setTint((0.025 + abs(1 - cell.brightness) * 0.4 + sheen) * appear, on: cell.node)
            }
        }
    }

    // MARK: - Glints

    private func emitGlint(on crack: Crack, patternTime t: Double) {
        let candidates = crack.pattern.radials.compactMap { index -> [FXVec]? in
            let visible = crack.pattern.lines[index].visiblePoints(at: t)
            guard visible.count > 4 else { return nil }
            let runs = CrackPaths.visibleRuns(visible, hidden: hole)
            return runs.max { $0.count < $1.count }
        }.filter { run in
            zip(run, run.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } > 90
        }
        guard !candidates.isEmpty else { return }
        let run = candidates[rng.int(0...(candidates.count - 1))]
        let track = Array(run.suffix(from: run.count / 5))
        particles.emitGlint(along: track, duration: rng.range(0.38...0.5), size: rng.range(18...28))
    }
}
