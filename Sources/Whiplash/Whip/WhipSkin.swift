import AppKit
import SpriteKit

/// Draws a `WhipRope` as a braided leather bullwhip: drop shadow, tapered thong with outline, highlight
/// and plaited chevrons, a frayed cracker at the tip, a wooden grip with a pommel held in Lash's fluffy white paw, and —
/// while the whip is fast — a cartoon smear over the area the thong swept since the last frame plus a tapered comet
/// streak along the tip's path. A faint warm rim keeps the thong readable over dark terminals. Every node is created
/// once; `update` only swaps paths and transforms.
final class WhipSkin: SKNode {
    enum Palette {
        /// Bright enough for ≥ 3:1 contrast on a near-black terminal.
        static let leather = NSColor(srgbRed: 0.62, green: 0.38, blue: 0.20, alpha: 1)
        static let leatherDark = NSColor(srgbRed: 0.19, green: 0.10, blue: 0.05, alpha: 1)
        static let leatherLight = NSColor(srgbRed: 0.86, green: 0.63, blue: 0.39, alpha: 1)
        static let cracker = NSColor(srgbRed: 0.96, green: 0.91, blue: 0.80, alpha: 1)
        static let wood = NSColor(srgbRed: 0.55, green: 0.33, blue: 0.16, alpha: 1)
        static let woodDark = NSColor(srgbRed: 0.30, green: 0.16, blue: 0.07, alpha: 1)
        static let brass = NSColor(srgbRed: 0.93, green: 0.74, blue: 0.33, alpha: 1)
        static let smear = NSColor(srgbRed: 1, green: 0.84, blue: 0.62, alpha: 1)
        /// The rim light around the thong.
        static let rim = NSColor(srgbRed: 1, green: 0.9, blue: 0.76, alpha: 0.32)
        /// Lash's paw (as in the island: fluffy white Samoyed fur, a cool rim light, pink toe beans).
        static let knuckle = NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)
        static let knuckleShade = NSColor(srgbRed: 0.70, green: 0.70, blue: 0.76, alpha: 0.85)
        static let knuckleRim = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.8)
        static let claw = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.70, alpha: 1)
    }

    /// Thong width at the handle and at the tip, points.
    static let rootWidth = 11.0
    static let tipWidth = 2.0
    /// How far the rim light reaches past the thong's edge, points.
    static let rimWidth: CGFloat = 1.1
    static let shadowOffset = CGPoint(x: 6, y: -10)

    private let shadowLayer = SKNode()
    private let shadowBody = WhipSkin.shape(fill: NSColor.black.withAlphaComponent(0.25))
    private let shadowHandle = WhipSkin.shape(fill: NSColor.black.withAlphaComponent(0.25))
    /// Motion smear: the area the outer thong swept since the last frame, one band per `smearBands` entry
    /// (fainter toward the handle, where the thong moves slower).
    private let smears: [SKShapeNode] = WhipSkin.smearBands.map { _ in WhipSkin.shape(fill: Palette.smear) }
    /// A tapered comet streak along the tip's recent path (soft halo + bright core): the tip tearing
    /// through the air.
    private let streakHalo = WhipSkin.shape(fill: .white)
    private let streakCore = WhipSkin.shape(fill: .white)
    private let rimLight = WhipSkin.shape(fill: Palette.rim)
    private let body = WhipSkin.shape(fill: Palette.leather, antialiased: false)
    private let outline = WhipSkin.shape(stroke: Palette.leatherDark, width: 1.4)
    private let highlights: [SKShapeNode] = (0..<3).map { _ in WhipSkin.shape(stroke: Palette.leatherLight, width: 1.1) }
    private let braids: [SKShapeNode] = (0..<3).map { _ in WhipSkin.shape(stroke: Palette.leatherDark, width: 0.9) }
    private let cracker = WhipSkin.shape(stroke: Palette.cracker, width: 1.1)
    private let handle = WhipSkin.makeHandle()
    /// Lash's fist round the grip, just below the island's edge. Hidden while the user holds the whip.
    private let fist = WhipSkin.makeFist()

    /// The outer thong at `smearU` in the previous frame, for the smear.
    private var lastSmearLine: [CGPoint] = []
    private var smearLine: [CGPoint] = []
    /// Material coordinates the smear is sampled at, and the (from, to, opacity) of each band.
    private static let smearU: [Double] = (0...36).map { 0.28 + 0.72 * Double($0) / 36 }
    private static let smearBands: [(from: Double, to: Double, opacity: CGFloat)] = (0..<6).map { k in
        let from = 0.28 + 0.12 * Double(k), to = from + 0.12
        return (from, to, CGFloat(0.03 + 0.25 * pow((Double(k) + 0.5) / 6, 1.4)))
    }
    /// Recent tip samples, newest last, for the streak.
    private var tipTrail: [WhipRope.TipSample] = []
    private static let streakLength: CGFloat = 520

    override init() {
        super.init()
        shadowLayer.position = Self.shadowOffset
        shadowLayer.addChild(shadowBody)
        shadowLayer.addChild(shadowHandle)
        shadowHandle.path = Self.handleSilhouette
        handle.addChild(fist)
        for node in [shadowLayer] + smears + [streakHalo, streakCore, rimLight, body, outline] + highlights + braids + [cracker, handle] {
            addChild(node)
        }
        for (i, node) in children.enumerated() { node.zPosition = CGFloat(i) }
        for (i, h) in highlights.enumerated() { h.alpha = [0.55, 0.38, 0.2][i] }
        for (i, b) in braids.enumerated() { b.alpha = [0.7, 0.45, 0.22][i] }
        cracker.lineCap = .round
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Redraws the whip. `presence` (0...1) fades and slims it while it slides out of / into the notch;
    /// `tipPath` is where the tip went since the last update; `fist` (0...1) is the opacity of Lash's fist.
    func update(rope: WhipRope, presence: Double, time: Double, tipPath: [WhipRope.TipSample], fist: Double = 1) {
        isHidden = presence <= 0.001
        guard !isHidden else { lastSmearLine.removeAll(); tipTrail.removeAll(); return }
        let samples = Self.centerline(of: rope)
        let normals = Self.normals(samples)
        let slim = CGFloat(0.35 + 0.65 * presence)
        let fade = CGFloat(WhipMath.smoothstep(presence * 1.6))

        let thong = Self.thong(samples, normals: normals, widthScale: slim)
        body.path = thong.quads
        rimLight.path = Self.thong(samples, normals: normals, widthScale: slim, extra: Self.rimWidth).quads
        outline.path = thong.edges
        shadowBody.path = thong.quads
        for (i, node) in highlights.enumerated() {
            node.path = Self.stripe(samples, normals: normals, from: Double(i) * 0.25, to: Double(i + 1) * 0.25,
                                    side: 0.42, widthScale: slim)
        }
        for (i, node) in braids.enumerated() {
            node.path = Self.braid(samples, normals: normals, from: [0, 0.35, 0.65][i], to: [0.35, 0.65, 0.9][i],
                                   widthScale: slim)
        }
        cracker.path = Self.cracker(rope: rope, time: time, scale: slim)

        let pommel = rope.positions[0], root = rope.positions[1]
        let angle = CGFloat((root - pommel).whipAngle)
        handle.position = pommel.whipPoint
        handle.zRotation = angle
        handle.setScale(slim)
        shadowHandle.position = pommel.whipPoint
        shadowHandle.zRotation = angle
        shadowHandle.setScale(slim)
        self.fist.alpha = CGFloat(fist)
        self.fist.isHidden = fist <= 0.001
        alpha = fade

        let speed = tipPath.reduce(rope.tipSpeed) { max($0, $1.speed) }
        updateSmear(samples, speed: speed)
        updateStreak(tipPath)
    }

    // MARK: - Centreline

    struct Sample {
        var point: CGPoint
        /// Material coordinate along the thong, 0 at the handle, 1 at the tip.
        var u: Double
    }

    /// Centripetal Catmull-Rom through the thong particles, subdivided by segment length.
    static func centerline(of rope: WhipRope) -> [Sample] {
        let p = rope.positions
        let n = p.count
        let total = max(rope.length, 1e-6)
        var samples: [Sample] = []
        samples.reserveCapacity(n * 3)
        var arc = 0.0
        for i in 1..<(n - 1) {
            let p0 = p[max(1, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(n - 1, i + 2)]
            let rest = rope.restLengths[i]
            let steps = Int(WhipMath.clamp((p2 - p1).whipLength / 7, 1, 6))
            for k in 0..<steps {
                let t = Double(k) / Double(steps)
                samples.append(Sample(point: catmullRom(p0, p1, p2, p3, t).whipPoint, u: (arc + rest * t) / total))
            }
            arc += rest
        }
        samples.append(Sample(point: p[n - 1].whipPoint, u: 1))
        return samples
    }

    /// Centripetal (α = ½) Catmull-Rom between p1 and p2 — no cusps or loops within a segment.
    static func catmullRom(_ p0: WhipVec, _ p1: WhipVec, _ p2: WhipVec, _ p3: WhipVec, _ t: Double) -> WhipVec {
        func knot(_ a: WhipVec, _ b: WhipVec) -> Double { max(pow((b - a).whipLength, 0.5), 1e-4) }
        let t1 = knot(p0, p1), t2 = t1 + knot(p1, p2), t3 = t2 + knot(p2, p3)
        let u = t1 + (t2 - t1) * t
        let a1 = p0 * ((t1 - u) / t1) + p1 * (u / t1)
        let a2 = p1 * ((t2 - u) / (t2 - t1)) + p2 * ((u - t1) / (t2 - t1))
        let a3 = p2 * ((t3 - u) / (t3 - t2)) + p3 * ((u - t2) / (t3 - t2))
        let b1 = a1 * ((t2 - u) / t2) + a2 * (u / t2)
        let b2 = a2 * ((t3 - u) / (t3 - t1)) + a3 * ((u - t1) / (t3 - t1))
        return b1 * ((t2 - u) / (t2 - t1)) + b2 * ((u - t1) / (t2 - t1))
    }

    static func width(at u: Double) -> Double {
        tipWidth + (rootWidth - tipWidth) * pow(max(0, 1 - u), 1.15)
    }

    /// Unit normals (left of travel) at every sample.
    private static func normals(_ s: [Sample]) -> [CGVector] {
        s.indices.map { i in
            let a = s[max(0, i - 1)].point, b = s[min(s.count - 1, i + 1)].point
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1e-6)
            return CGVector(dx: -dy / len, dy: dx / len)
        }
    }

    // MARK: - Paths

    /// The tapered thong as a union of quads (fills solidly even where the whip crosses itself) plus its
    /// two edges and rounded tip as strokes for the outline.
    /// `extra` widens it by that much on each side (for the rim light).
    private static func thong(_ s: [Sample], normals: [CGVector], widthScale: CGFloat,
                              extra: CGFloat = 0) -> (quads: CGPath, edges: CGPath) {
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(s.count)
        right.reserveCapacity(s.count)
        for (i, sample) in s.enumerated() {
            let half = CGFloat(width(at: sample.u) / 2) * widthScale + extra
            let n = normals[i]
            left.append(CGPoint(x: sample.point.x + n.dx * half, y: sample.point.y + n.dy * half))
            right.append(CGPoint(x: sample.point.x - n.dx * half, y: sample.point.y - n.dy * half))
        }
        let quads = CGMutablePath()
        for i in 0..<(s.count - 1) {
            // Keep every quad counter-clockwise so overlaps add up under the non-zero rule.
            let q = [right[i], right[i + 1], left[i + 1], left[i]]
            quads.addLines(between: signedArea(q) >= 0 ? q : q.reversed())
            quads.closeSubpath()
        }
        if let tip = s.last?.point, let l = left.last, let r = right.last {
            let radius = hypot(l.x - r.x, l.y - r.y) / 2
            quads.addEllipse(in: CGRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
        }
        let edges = CGMutablePath()
        edges.addLines(between: left)
        edges.addLines(between: right)
        if let l = left.last, let r = right.last, let tip = s.last?.point {
            edges.move(to: l)
            edges.addQuadCurve(to: r, control: CGPoint(x: tip.x * 2 - (l.x + r.x) / 2, y: tip.y * 2 - (l.y + r.y) / 2))
        }
        return (quads, edges)
    }

    private static func signedArea(_ q: [CGPoint]) -> CGFloat {
        var a: CGFloat = 0
        for i in q.indices {
            let p = q[i], n = q[(i + 1) % q.count]
            a += p.x * n.y - n.x * p.y
        }
        return a
    }

    /// A thin line running along one side of the thong between material coordinates `from` and `to`.
    private static func stripe(_ s: [Sample], normals: [CGVector], from: Double, to: Double, side: CGFloat,
                               widthScale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        var started = false
        for (i, sample) in s.enumerated() where sample.u >= from && sample.u <= to + 0.01 {
            let off = CGFloat(width(at: sample.u) / 2) * widthScale * side
            let p = CGPoint(x: sample.point.x + normals[i].dx * off, y: sample.point.y + normals[i].dy * off)
            if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        return path
    }

    /// Plaited chevrons ("V"s pointing to the tip) every ~8 pt of thong.
    private static func braid(_ s: [Sample], normals: [CGVector], from: Double, to: Double, widthScale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard s.count > 2 else { return path }
        // Screen arc length of every sample, for even spacing.
        var arcs = [CGFloat](repeating: 0, count: s.count)
        for i in 1..<s.count {
            arcs[i] = arcs[i - 1] + hypot(s[i].point.x - s[i - 1].point.x, s[i].point.y - s[i - 1].point.y)
        }
        let spacing: CGFloat = 8
        var j = 1
        var d = spacing * 0.5
        while d < arcs[s.count - 1] {
            while j < s.count - 1, arcs[j] < d { j += 1 }
            let a = s[j - 1], b = s[j]
            let span = max(arcs[j] - arcs[j - 1], 1e-6)
            let t = (d - arcs[j - 1]) / span
            let u = a.u + (b.u - a.u) * Double(t)
            defer { d += spacing }
            guard u >= from, u < to else { continue }
            let c = CGPoint(x: a.point.x + (b.point.x - a.point.x) * t, y: a.point.y + (b.point.y - a.point.y) * t)
            let n = normals[j]
            let tangent = CGVector(dx: n.dy, dy: -n.dx)
            let half = CGFloat(width(at: u) / 2) * widthScale * 0.78
            let back = half * 0.9
            path.move(to: CGPoint(x: c.x + n.dx * half - tangent.dx * back, y: c.y + n.dy * half - tangent.dy * back))
            path.addLine(to: c)
            path.addLine(to: CGPoint(x: c.x - n.dx * half - tangent.dx * back, y: c.y - n.dy * half - tangent.dy * back))
        }
        return path
    }

    /// Three frayed strands past the tip. They trail behind the tip when it moves fast, and flutter.
    private static func cracker(rope: WhipRope, time: Double, scale: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = rope.count
        let tip = rope.positions[n - 1]
        let along = tip - rope.positions[n - 3]
        guard along.whipLength > 1e-6 else { return path }
        var direction = along / along.whipLength
        let speed = rope.tipSpeed
        if speed > 200 {
            let trail = -rope.tipVelocity / speed
            let w = WhipMath.smoothstep((speed - 200) / 2500) * 0.8
            let mixed = direction * (1 - w) + trail * w
            if mixed.whipLength > 1e-6 { direction = mixed / mixed.whipLength }
        }
        let lengths = [15.0, 12.0, 10.0]
        let spreads = [0.0, 0.32, -0.30]
        for k in 0..<3 {
            let wobble = 0.18 * sin(time * 23 + Double(k) * 2.1) * WhipMath.smoothstep(speed / 800 + 0.3)
            let a = direction.whipAngle + spreads[k] + wobble
            let end = tip + WhipVec.whipUnit(a) * lengths[k] * Double(scale)
            let mid = tip + WhipVec.whipUnit(a - wobble * 1.8) * lengths[k] * 0.55 * Double(scale)
            path.move(to: tip.whipPoint)
            path.addQuadCurve(to: end.whipPoint, control: mid.whipPoint)
        }
        return path
    }

    /// Fills the area the outer thong swept since the last frame — a cartoon smear frame. Quads join each
    /// point of the thong to where the same bit of leather was a frame ago.
    private func updateSmear(_ samples: [Sample], speed: Double) {
        swap(&lastSmearLine, &smearLine)
        Self.resample(samples, at: Self.smearU, into: &smearLine)
        let strength = CGFloat(WhipMath.smoothstep((speed - 2500) / 6000))
        let ready = strength > 0.01 && lastSmearLine.count == smearLine.count
        for (band, node) in zip(Self.smearBands, smears) {
            node.isHidden = !ready
            guard ready else { continue }
            let path = CGMutablePath()
            for j in 0..<(smearLine.count - 1) where Self.smearU[j] >= band.from - 1e-9 && Self.smearU[j] < band.to - 1e-9 {
                let q = [lastSmearLine[j], lastSmearLine[j + 1], smearLine[j + 1], smearLine[j]]
                let area = Self.signedArea(q)
                guard abs(area) > 4 else { continue }
                path.addLines(between: area > 0 ? q : q.reversed())
                path.closeSubpath()
            }
            node.path = path
            node.alpha = strength * band.opacity
        }
    }

    /// Points of the centreline at the material coordinates `us` (ascending), written into `out`.
    private static func resample(_ s: [Sample], at us: [Double], into out: inout [CGPoint]) {
        out.removeAll(keepingCapacity: true)
        guard var j = s.indices.first else { return }
        for u in us {
            while j < s.count - 2, s[j + 1].u < u { j += 1 }
            let a = s[j], b = s[min(j + 1, s.count - 1)]
            let t = CGFloat(WhipMath.clamp((u - a.u) / max(b.u - a.u, 1e-9), 0, 1))
            out.append(CGPoint(x: a.point.x + (b.point.x - a.point.x) * t, y: a.point.y + (b.point.y - a.point.y) * t))
        }
    }

    /// Comet streak through the tip's most recent path, only while it moves fast: it tapers from nothing
    /// at the old end to a bright head at the tip.
    private func updateStreak(_ newSamples: [WhipRope.TipSample]) {
        tipTrail.append(contentsOf: newSamples)
        // Keep just enough of the newest trail to cover the streak length.
        var covered: CGFloat = 0
        var first = tipTrail.count - 1
        while first > 0, covered < Self.streakLength, tipTrail.count - first < 400 {
            covered += CGFloat((tipTrail[first].position - tipTrail[first - 1].position).whipLength)
            first -= 1
        }
        tipTrail.removeFirst(first)
        let speed = tipTrail.last?.speed ?? 0
        // Only the throw and the snap: slower swings (and the wind-up, while the rope grows) get the smear.
        let strength = CGFloat(WhipMath.smoothstep((speed - 5000) / 8000))
        let visible = strength > 0.01 && tipTrail.count > 2
        streakHalo.isHidden = !visible
        streakCore.isHidden = !visible
        guard visible else { return }
        streakHalo.path = Self.ribbon(tipTrail, headWidth: 9)
        streakHalo.alpha = strength * 0.22
        streakCore.path = Self.ribbon(tipTrail, headWidth: 3.2)
        streakCore.alpha = strength * 0.9
    }

    /// A filled ribbon along `trail` whose width grows from 0 at the oldest sample to `headWidth` at the newest.
    /// The centreline is lightly smoothed (the head stays put), so substep-level jitter doesn't show as steps.
    private static func ribbon(_ trail: [WhipRope.TipSample], headWidth: CGFloat) -> CGPath {
        let n = trail.count
        let centre: [WhipVec] = (0..<n).map { i in
            guard i > 0, i < n - 1 else { return trail[i].position }
            return (trail[i - 1].position + trail[i].position * 2 + trail[i + 1].position) / 4
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0..<n {
            let d = centre[min(n - 1, i + 1)] - centre[max(0, i - 1)]
            let len = d.whipLength
            let normal = len > 1e-6 ? WhipVec(-d.y, d.x) / len : WhipVec(0, 0)
            let t = Double(i) / Double(n - 1)
            let half = Double(headWidth) / 2 * t * t.squareRoot()
            left.append((centre[i] + normal * half).whipPoint)
            right.append((centre[i] - normal * half).whipPoint)
        }
        let path = CGMutablePath()
        path.addLines(between: left + right.reversed())
        path.closeSubpath()
        return path
    }

    // MARK: - Handle

    static let gripLength: CGFloat = 44

    /// Grip, pommel and brass collar in handle space: x runs from the pommel (0) to the thong (44).
    private static func makeHandle() -> SKNode {
        let node = SKNode()
        let grip = SKShapeNode(rect: CGRect(x: 2, y: -5, width: gripLength - 4, height: 10), cornerRadius: 4.5)
        grip.fillColor = Palette.wood
        grip.strokeColor = Palette.woodDark
        grip.lineWidth = 1.3
        node.addChild(grip)

        // Leather wrap: diagonal bands across the grip.
        let wrap = CGMutablePath()
        var x: CGFloat = 9
        while x < gripLength - 9 {
            wrap.move(to: CGPoint(x: x, y: -4.5))
            wrap.addLine(to: CGPoint(x: x + 4, y: 4.5))
            x += 4.5
        }
        let bands = shape(stroke: Palette.woodDark.withAlphaComponent(0.75), width: 1.2)
        bands.path = wrap
        node.addChild(bands)

        let shine = SKShapeNode(rect: CGRect(x: 6, y: 1.6, width: gripLength - 14, height: 1.6), cornerRadius: 0.8)
        shine.fillColor = Palette.leatherLight.withAlphaComponent(0.55)
        shine.strokeColor = .clear
        node.addChild(shine)

        let collar = SKShapeNode(rect: CGRect(x: gripLength - 6, y: -5.6, width: 6, height: 11.2), cornerRadius: 1.5)
        collar.fillColor = Palette.brass
        collar.strokeColor = Palette.woodDark
        collar.lineWidth = 1
        node.addChild(collar)

        let pommel = SKShapeNode(circleOfRadius: 6.5)
        pommel.position = CGPoint(x: 0, y: 0)
        pommel.fillColor = Palette.woodDark
        pommel.strokeColor = NSColor.black.withAlphaComponent(0.6)
        pommel.lineWidth = 1
        node.addChild(pommel)
        let glint = SKShapeNode(circleOfRadius: 1.8)
        glint.position = CGPoint(x: -1.6, y: 2)
        glint.fillColor = Palette.leatherLight.withAlphaComponent(0.8)
        glint.strokeColor = .clear
        node.addChild(glint)
        return node
    }

    /// Where Lash's three fingers wrap the grip: (distance from the pommel, finger length). The pommel rests just
    /// inside the island's bottom edge (`IslandLayout.whipGripInset` minus the rest pose's 4 pt), so these show
    /// right under the edge, like the fist of a Lash hidden in the pill.
    static let fingers: [(along: CGFloat, length: CGFloat)] = [(9, 19), (13.5, 20), (18, 17.5)]

    /// Lash's paw in handle space (x from the pommel toward the thong): fluffy white toe pads across the grip, each with a
    /// warm rim light and a pink toe bean on the +y side (the right, while the whip hangs down).
    private static func makeFist() -> SKNode {
        let node = SKNode()
        let thickness: CGFloat = 5.2
        for (i, finger) in fingers.enumerated() {
            let shift = CGFloat(i % 2) * 0.8
            let rect = CGRect(x: finger.along - thickness / 2, y: -finger.length / 2 + shift, width: thickness, height: finger.length)
            let knuckle = SKShapeNode(rect: rect, cornerRadius: thickness / 2)
            knuckle.fillColor = Palette.knuckle
            knuckle.strokeColor = NSColor.black.withAlphaComponent(0.85)
            knuckle.lineWidth = 1
            node.addChild(knuckle)
            // The underside of the finger in shadow, the knuckle catching the light.
            let shade = SKShapeNode(rect: CGRect(x: rect.maxX - 2.2, y: rect.minY + 2.6, width: 1.6, height: rect.height - 5.2))
            shade.fillColor = Palette.knuckleShade
            shade.strokeColor = .clear
            node.addChild(shade)
            let rim = SKShapeNode()
            let line = CGMutablePath()
            line.move(to: CGPoint(x: rect.minX + 1.1, y: rect.minY + 2.5))
            line.addLine(to: CGPoint(x: rect.minX + 1.1, y: rect.maxY - 2.5))
            rim.path = line
            rim.strokeColor = Palette.knuckleRim
            rim.lineWidth = 0.8
            rim.lineCap = .round
            node.addChild(rim)
            let bean = SKShapeNode(ellipseOf: CGSize(width: thickness * 0.72, height: thickness * 0.95))
            bean.position = CGPoint(x: rect.midX, y: rect.maxY - thickness * 0.75)
            bean.fillColor = Palette.claw
            bean.strokeColor = .clear
            node.addChild(bean)
        }
        return node
    }

    /// Grip and pommel as one outline, for the shadow (one fill, so overlaps don't double up).
    private static let handleSilhouette: CGPath = {
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 2, y: -5.6, width: gripLength - 2, height: 11.2), cornerWidth: 4.5, cornerHeight: 4.5)
        path.addEllipse(in: CGRect(x: -6.5, y: -6.5, width: 13, height: 13))
        return path
    }()

    // MARK: - Helpers

    private static func shape(fill: NSColor, antialiased: Bool = true) -> SKShapeNode {
        let node = SKShapeNode()
        node.fillColor = fill
        node.strokeColor = .clear
        node.lineWidth = 0
        node.isAntialiased = antialiased
        return node
    }

    private static func shape(stroke: NSColor, width: CGFloat) -> SKShapeNode {
        let node = SKShapeNode()
        node.fillColor = .clear
        node.strokeColor = stroke
        node.lineWidth = width
        node.lineJoin = .round
        node.isAntialiased = true
        return node
    }
}
