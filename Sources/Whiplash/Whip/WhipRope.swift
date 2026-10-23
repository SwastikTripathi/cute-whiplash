import CoreGraphics
import simd

/// 2-D vector used by the whip simulation (scene points, y-up).
typealias WhipVec = SIMD2<Double>

// Helpers carry a `whip` prefix so they can't clash with other modules' geometry extensions.
extension SIMD2 where Scalar == Double {
    var whipPoint: CGPoint { CGPoint(x: x, y: y) }
    var whipLength: Double { simd_length(self) }
    /// Unit vector at `angle` radians (0 = +x, counter-clockwise).
    static func whipUnit(_ angle: Double) -> WhipVec { WhipVec(cos(angle), sin(angle)) }
    var whipAngle: Double { atan2(y, x) }
    var isWhipFinite: Bool { x.isFinite && y.isFinite }
}

extension CGPoint {
    var whipVec: WhipVec { WhipVec(Double(x), Double(y)) }
}

/// Where the hand holds the whip: the pommel position and the direction the handle points (pommel → thong).
struct WhipHandPose: Equatable {
    var position: WhipVec
    /// Radians, 0 = +x, counter-clockwise. −π/2 hangs straight down.
    var angle: Double

    /// Blend towards `other` by `t`, rotating the short way round. `t` may leave 0...1 to overshoot.
    func mixed(with other: WhipHandPose, _ t: Double) -> WhipHandPose {
        WhipHandPose(position: position + (other.position - position) * t,
                     angle: angle + WhipMath.angleDelta(from: angle, to: other.angle) * t)
    }
}

enum WhipMath {
    /// Signed shortest rotation from `a` to `b`, in (−π, π].
    static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d <= -.pi { d += 2 * .pi }
        return d
    }

    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
    static func smoothstep(_ t: Double) -> Double { let t = clamp(t, 0, 1); return t * t * (3 - 2 * t) }
    static func smootherstep(_ t: Double) -> Double { let t = clamp(t, 0, 1); return t * t * t * (t * (6 * t - 15) + 10) }
    /// Ease-out with a small overshoot past 1 before settling (`overshoot` ≈ 1.7 gives ~10 %).
    static func easeOutBack(_ t: Double, overshoot: Double = 1.4) -> Double {
        let t = clamp(t, 0, 1) - 1
        return 1 + t * t * ((overshoot + 1) * t + overshoot)
    }
    static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Frame-rate independent exponential approach factor for a time constant `tau` over `dt`.
    static func approach(_ dt: Double, tau: Double) -> Double { tau <= 0 ? 1 : 1 - exp(-dt / tau) }

    /// Closest point to `p` on the segment a–b.
    static func closestPoint(on a: WhipVec, _ b: WhipVec, to p: WhipVec) -> WhipVec {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-12 else { return a }
        return a + ab * clamp(simd_dot(p - a, ab) / len2, 0, 1)
    }
}

/// A tapered bullwhip as a position-based (Verlet) particle chain.
///
/// Particles 0...1 are the rigid handle (pommel → thong root) and particle 2 continues the handle's
/// direction, so the hand has leverage to throw loops. Those three are kinematic: the hand places them.
/// The rest is simulated in substeps (more of them while the tip is fast): a uniform field (gravity), light
/// damping, quadratic air drag on the thin end, inextensible distance constraints and bending stiffness that
/// falls off toward the tip. Mass falls off toward the tip too, so a fold that runs down the rope concentrates
/// its energy into ever lighter particles and the tip accelerates — which is what makes a whip crack.
struct WhipRope {
    struct Config {
        /// Total particles, including the three kinematic handle particles.
        var particleCount = 52
        var handleLength = 44.0
        var gravity = WhipVec(0, -1900)
        /// Substeps per `step` at rest; more are added automatically while the tip is fast.
        var substeps = 3
        var maxSubsteps = 12
        var iterations = 12
        /// Fraction of velocity lost per second.
        var damping = 0.35
        /// Mass of the last particle relative to the first rope particle.
        var tipMassRatio = 0.06
        /// Length of the last segment relative to the first (finer resolution where the tip curls).
        var segmentTaper = 0.45
        /// Per-iteration bending stiffness at the handle end; falls off with (1 − t)² toward the tip.
        var rootBendStiffness = 0.1
        /// Hard limit on how far any particle may move in 1/360 s, per 450 pt of rope.
        var maxSubstepTravel = 90.0
        /// The rope never gets shorter than this internally.
        var minimumLength = 2.0
        /// Segments may stretch at most this fraction past their rest length.
        var stretchTolerance = 0.045
        /// Quadratic air drag at the tip (1/pt) for a rope of `referenceLength`, scaled inversely with the
        /// length like everything else, and falling off toward the handle with the thong's thickness.
        /// Real whips are tamed by drag on their thin end — without it the light tip whips about wildly.
        var tipDrag = 1.0e-3
        /// Below this length the rope is kept straight along the handle when its length changes.
        var straightLength = 24.0
    }

    /// A damped spring pulling every free particle toward a moving target shape (used to pose the wind-up).
    struct Guide {
        /// One target per particle (entries for the kinematic particles are ignored).
        var targets: [WhipVec]
        /// How fast each target moves, points/s (the spring damps toward this velocity).
        var targetVelocities: [WhipVec]
        /// Spring rate, 1/s².
        var stiffness: Double
        /// Velocity damping, 1/s.
        var damping: Double
        /// 0...1 master strength.
        var strength: Double
    }

    /// One sample of the tip's path during the last `step` (one per substep).
    struct TipSample {
        var position: WhipVec
        var speed: Double
    }

    let config: Config
    private(set) var positions: [WhipVec]
    private var previous: [WhipVec]
    private let inverseMass: [Double]
    /// Rest length of segment i (between particle i and i+1). Segment 0 is the rigid handle.
    private(set) var restLengths: [Double] { didSet { arcLengths = Self.cumulativeArc(restLengths) } }
    /// Distance along the rope from the thong root to particle i, at rest.
    private(set) var arcLengths: [Double] = []
    private let segmentWeights: [Double]
    private let bendStiffness: [Double]
    private let drag: [Double]
    /// Rope length (particle 1 → tip) the constraints currently enforce.
    private(set) var length: Double
    /// The hand pose at the end of the last step.
    private(set) var hand: WhipHandPose
    /// Tip velocity after the last substep, points/s.
    private(set) var tipVelocity = WhipVec.zero
    /// The tip's path through the last `step`, starting with where it was before the step.
    private(set) var tipPath: [TipSample] = []
    /// Every particle's position before and after each substep of the last `step` (substep-major), so the
    /// rope can be rewound to the instant of a crack.
    private var substepPositions: [WhipVec] = []
    /// Number of times the simulation had to be reset because it produced non-finite values.
    private(set) var resetCount = 0

    /// Uniform acceleration on every free particle, points/s². Starts as `config.gravity`; scripted strikes
    /// swing it around (a cartoon "throw field") so the rope flies where the throw sends it.
    var gravity: WhipVec
    /// Extra velocity damping (1/s) on top of `config.damping`, e.g. to make the rope go limp after a crack.
    var extraDamping = 0.0
    var guide: Guide?
    /// The screen's edges, when known: the thong can't leave it (the whip lives behind the glass). Contact
    /// is inelastic with a little friction. The first `wallClearance` points of thong are exempt, so the
    /// handle can still slide out of the notch.
    var walls: (minX: Double, minY: Double, maxX: Double, maxY: Double)?
    static let wallClearance = 60.0

    /// Number of kinematic particles at the root (pommel, thong root, first rope particle).
    static let kinematicCount = 3
    /// Rope length the per-substep limits are tuned for.
    static let referenceLength = 450.0

    var count: Int { positions.count }
    var tip: WhipVec { positions[positions.count - 1] }
    var tipSpeed: Double { tipVelocity.whipLength }
    /// Where the thong leaves the handle.
    var thongRoot: WhipVec { positions[1] }

    init(config: Config = Config(), hand: WhipHandPose, length: Double) {
        self.config = config
        let n = max(8, config.particleCount)
        let ropeSegments = n - 2
        var weights: [Double] = []
        for j in 0..<ropeSegments {
            let t = Double(j) / Double(max(1, ropeSegments - 1))
            weights.append(1 - (1 - config.segmentTaper) * t)
        }
        let sum = weights.reduce(0, +)
        segmentWeights = weights.map { $0 / sum }

        var inv = [Double](repeating: 0, count: n)
        var bend = [Double](repeating: 0, count: n)
        let dynamicSpan = Double(n - Self.kinematicCount)
        for i in Self.kinematicCount..<n {
            let t = Double(i - Self.kinematicCount + 1) / dynamicSpan
            let taper = 1 - (1 - config.tipMassRatio.squareRoot()) * t
            inv[i] = 1 / (taper * taper)
        }
        for i in 1..<(n - 1) {
            let t = Double(i - 1) / Double(n - 2)
            bend[i] = config.rootBendStiffness * (1 - t) * (1 - t)
        }
        inverseMass = inv
        bendStiffness = bend
        // Drag per unit mass ∝ surface / mass ∝ 1 / thickness.
        drag = (0..<n).map { i in
            let t = Double(max(0, i - Self.kinematicCount + 1)) / dynamicSpan
            let thickness = 1 - (1 - config.tipMassRatio.squareRoot()) * t
            return i < Self.kinematicCount ? 0 : config.tipDrag * config.tipMassRatio.squareRoot() / thickness
        }
        self.length = max(config.minimumLength, length)
        self.hand = hand
        gravity = config.gravity
        restLengths = Self.restLengths(ropeLength: self.length, handleLength: config.handleLength, weights: segmentWeights)
        arcLengths = Self.cumulativeArc(restLengths)
        positions = []
        previous = []
        hangStraight()
    }

    private static func restLengths(ropeLength: Double, handleLength: Double, weights: [Double]) -> [Double] {
        [handleLength] + weights.map { $0 * ropeLength }
    }

    private func kinematicPositions(for pose: WhipHandPose) -> (WhipVec, WhipVec, WhipVec) {
        let dir = WhipVec.whipUnit(pose.angle)
        let root = pose.position + dir * config.handleLength
        return (pose.position, root, root + dir * restLengths[1])
    }

    private static func cumulativeArc(_ rest: [Double]) -> [Double] {
        var arc = [Double](repeating: 0, count: rest.count + 1)
        for i in 2..<arc.count { arc[i] = arc[i - 1] + rest[i - 1] }
        return arc
    }

    /// Lays the rope out straight along the handle, at rest.
    mutating func hangStraight() {
        let n = max(8, config.particleCount)
        let dir = WhipVec.whipUnit(hand.angle)
        var p = hand.position
        positions = [p]
        for i in 0..<(n - 1) {
            p += dir * restLengths[i]
            positions.append(p)
        }
        previous = positions
        tipVelocity = .zero
        tipPath = [TipSample(position: p, speed: 0)]
    }

    /// Moves the hand instantly (no motion is imparted) — for re-anchoring, not for animation.
    mutating func teleport(hand newHand: WhipHandPose) {
        let offset = newHand.position - hand.position
        hand = newHand
        for i in positions.indices {
            positions[i] += offset
            previous[i] += offset
        }
        let (k0, k1, k2) = kinematicPositions(for: newHand)
        positions[0] = k0; positions[1] = k1; positions[2] = k2
        previous[0] = k0; previous[1] = k1; previous[2] = k2
    }

    /// Puts the rope back to where it was after substep `substep` (1...) of the last `step` — `tipPath[substep]`
    /// — moving as it was then. Lets a crack stop the tip where it broke the sound barrier rather than a
    /// fast tip's whole step further on.
    mutating func rewind(toSubstep substep: Int) {
        let n = positions.count
        let steps = substepPositions.count / n - 1
        guard substep >= 1, substep < steps, tipPath.count == steps + 1 else { return }
        for i in 0..<n {
            positions[i] = substepPositions[substep * n + i]
            previous[i] = substepPositions[(substep - 1) * n + i]
        }
        let travel = positions[n - 1] - previous[n - 1]
        let length = travel.whipLength
        tipVelocity = length > 1e-9 ? travel * (tipPath[substep].speed / length) : .zero
        tipPath.removeLast(steps - substep)
        substepPositions.removeLast((steps - substep) * n)
    }

    /// Keeps only `keep` (0...1) of every free particle's velocity: the energy a crack spends.
    mutating func absorb(keep: Double) {
        let keep = WhipMath.clamp(keep.isFinite ? keep : 1, 0, 1)
        for i in Self.kinematicCount..<positions.count {
            previous[i] = positions[i] - (positions[i] - previous[i]) * keep
        }
        tipVelocity *= keep
    }

    /// Changes the rope length immediately, scaling the rope's current shape about the thong root while
    /// every particle keeps its velocity — so growing or reeling in never injects energy. A rope shorter than
    /// `config.straightLength` has no visible shape (just sub-point crumples), so it is laid out straight
    /// along the handle instead; scaling would inflate the crumples into knots.
    mutating func setLength(_ newLength: Double) {
        let target = max(config.minimumLength, newLength.isFinite ? newLength : length)
        guard abs(target - length) > 1e-9 else { return }
        let ratio = target / length
        let wasStub = length < config.straightLength
        length = target
        restLengths = Self.restLengths(ropeLength: target, handleLength: config.handleLength, weights: segmentWeights)
        let root = positions[1]
        let direction = WhipVec.whipUnit(hand.angle)
        var straight = root
        for i in 2..<positions.count {
            let velocity = positions[i] - previous[i]
            if wasStub {
                straight += direction * restLengths[i - 1]
                positions[i] = straight
            } else {
                positions[i] = root + (positions[i] - root) * ratio
            }
            previous[i] = positions[i] - velocity
        }
    }

    /// Advances the simulation by `dt` (clamped to 1/30 s) while the hand moves linearly to `newHand`.
    /// `carry` (0...1) moves that fraction of the hand's travel rigidly with the free rope, without imparting
    /// motion — used while the handle slides out of the notch, so it doesn't plough through the rope.
    mutating func step(dt: Double, hand newHand: WhipHandPose, carry: Double = 0) {
        let dt = WhipMath.clamp(dt.isFinite ? dt : 0, 0, 1.0 / 30)
        let n = positions.count
        tipPath.removeAll(keepingCapacity: true)
        tipPath.append(TipSample(position: positions[n - 1], speed: tipSpeed))
        substepPositions.removeAll(keepingCapacity: true)
        guard dt > 0, newHand.position.isWhipFinite, newHand.angle.isFinite else { return }
        substepPositions.append(contentsOf: positions)
        let startHand = hand
        let scale = max(1, length / Self.referenceLength)
        // Keep the tip's travel per substep to about one tip segment while it is fast.
        let tipSegment = max(1, restLengths[n - 2])
        let wanted = Int((tipSpeed * dt / (2 * tipSegment)).rounded(.up))
        let substeps = min(max(config.substeps, wanted), config.maxSubsteps)
        let h = dt / Double(substeps)
        let keep = max(0, 1 - (config.damping + max(0, extraDamping)) * h)
        let g = gravity * (h * h)
        let maxTravel = config.maxSubstepTravel * scale * dt * 360 / Double(substeps)
        let dragScale = Self.referenceLength / max(length, 60)

        let carried = (newHand.position - startHand.position) * (WhipMath.clamp(carry, 0, 1) / Double(substeps))
        for s in 1...substeps {
            let pose = startHand.mixed(with: newHand, Double(s) / Double(substeps))
            if carry > 0 {
                for i in Self.kinematicCount..<n {
                    positions[i] += carried
                    previous[i] += carried
                }
            }
            let (k0, k1, k2) = kinematicPositions(for: pose)
            previous[0] = positions[0]; previous[1] = positions[1]; previous[2] = positions[2]
            positions[0] = k0; positions[1] = k1; positions[2] = k2

            integrate(h: h, keep: keep, gravityStep: g, maxTravel: maxTravel, dragScale: dragScale)

            for iteration in 0..<config.iterations {
                if iteration % 2 == 0 {
                    for i in 1..<(n - 1) { solveDistance(i) }
                } else {
                    for i in stride(from: n - 2, through: 1, by: -1) { solveDistance(i) }
                }
                for i in 2..<(n - 1) where bendStiffness[i] > 0 { solveBend(i) }
            }
            limitStretch()
            if let walls { collide(with: walls) }

            tipVelocity = (positions[n - 1] - previous[n - 1]) / h
            tipPath.append(TipSample(position: positions[n - 1], speed: tipVelocity.whipLength))
            substepPositions.append(contentsOf: positions)
        }
        hand = newHand

        if !positions.allSatisfy(\.isWhipFinite) || !previous.allSatisfy(\.isWhipFinite) {
            resetCount += 1
            hangStraight()
        }
    }

    private mutating func integrate(h: Double, keep: Double, gravityStep: WhipVec, maxTravel: Double, dragScale: Double) {
        let n = positions.count
        var pd: (k: Double, c: Double, guide: Guide)?
        if let gd = guide, gd.targets.count == n, gd.targetVelocities.count == n, gd.strength > 0 {
            pd = (gd.stiffness * gd.strength * h * h, min(1, gd.damping * gd.strength * h), gd)
        }
        for i in Self.kinematicCount..<n {
            var v = (positions[i] - previous[i]) * keep
            if let pd {
                v += (pd.guide.targets[i] - positions[i]) * pd.k + (pd.guide.targetVelocities[i] * h - v) * pd.c
            }
            v += gravityStep
            // Quadratic drag, integrated implicitly so it can never reverse the motion.
            v /= 1 + drag[i] * dragScale * v.whipLength
            let travel = v.whipLength
            if travel > maxTravel { v *= maxTravel / travel }
            previous[i] = positions[i]
            positions[i] += v
        }
    }

    /// Inextensible segment i ↔ i+1, weighted by inverse mass.
    private mutating func solveDistance(_ i: Int) {
        let wa = inverseMass[i], wb = inverseMass[i + 1]
        let wsum = wa + wb
        guard wsum > 0 else { return }
        let delta = positions[i + 1] - positions[i]
        let dist = delta.whipLength
        guard dist > 1e-9 else { return }
        let correction = delta * ((dist - restLengths[i]) / (dist * wsum))
        positions[i] += correction * wa
        positions[i + 1] -= correction * wb
    }

    /// Follow-the-leader pass from the handle out: no segment may end up more than `stretchTolerance` longer
    /// than its rest length (Gauss-Seidel alone lets a fast, light tip stretch the thong visibly). The pull-back
    /// acts like an inextensible link — it cancels only the separating part of the relative velocity — so it
    /// adds no energy.
    private mutating func limitStretch() {
        for i in (Self.kinematicCount - 1)..<(positions.count - 1) {
            let delta = positions[i + 1] - positions[i]
            let dist = delta.whipLength
            let rest = restLengths[i] * (1 + config.stretchTolerance)
            guard dist > rest else { continue }
            let link = delta / dist
            var velocity = positions[i + 1] - previous[i + 1]
            let separating = simd_dot(velocity - (positions[i] - previous[i]), link)
            if separating > 0 { velocity -= link * separating }
            positions[i + 1] = positions[i] + link * rest
            previous[i + 1] = positions[i + 1] - velocity
        }
    }

    /// Pushes free particles back inside `walls`, cancelling their velocity into the wall and a little of
    /// their sliding.
    private mutating func collide(with walls: (minX: Double, minY: Double, maxX: Double, maxY: Double)) {
        guard walls.minX < walls.maxX, walls.minY < walls.maxY else { return }
        for i in Self.kinematicCount..<positions.count where arcLengths[i] > Self.wallClearance {
            let p = positions[i]
            let inside = WhipVec(WhipMath.clamp(p.x, walls.minX, walls.maxX), WhipMath.clamp(p.y, walls.minY, walls.maxY))
            guard inside != p else { continue }
            var velocity = p - previous[i]
            if inside.x != p.x { velocity.x = 0; velocity.y *= 0.9 }
            if inside.y != p.y { velocity.y = 0; velocity.x *= 0.9 }
            positions[i] = inside
            previous[i] = inside - velocity
        }
    }

    /// Resists bending at particle i by pushing its neighbours apart toward the straight distance.
    private mutating func solveBend(_ i: Int) {
        let a = i - 1, c = i + 1
        let wa = inverseMass[a], wc = inverseMass[c]
        let wsum = wa + wc
        guard wsum > 0 else { return }
        let delta = positions[c] - positions[a]
        let dist = delta.whipLength
        let straight = restLengths[a] + restLengths[i]
        guard dist < straight, dist > 1e-9 else { return }
        let correction = delta * (bendStiffness[i] * (dist - straight) / (dist * wsum))
        positions[a] += correction * wa
        positions[c] -= correction * wc
    }
}
