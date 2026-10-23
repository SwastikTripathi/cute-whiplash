import SpriteKit

/// Pooled, custom-integrated sprites: glass chips, sparkles, glints and bursts of light. They use the shared
/// `FXTextures` images with one blend mode per kind, so SpriteKit batches them.
final class FXParticles: SKNode {
    enum Kind { case chip, sparkle, glow }

    private struct Particle {
        var kind: Kind
        var node: SKSpriteNode
        var position: FXVec
        var velocity: FXVec
        var angle: Double
        var spin: Double
        var age = 0.0
        var life: Double
        var size: Double
        /// Scale multiplier reached at the end of life (>1: flying towards the viewer).
        var growth: Double
        var gravity: Double
        var drag: Double
        var alpha: Double
        /// Stretch, so the pooled chips don't all look alike.
        var aspect = 1.0
        /// Optional path to follow instead of integrating (glints running along a crack).
        var track: [FXVec]? = nil
    }

    private var live: [Particle] = []
    private var pool: [Kind: [SKSpriteNode]] = [:]
    private var rng: FXRandom

    init(seed: UInt64) {
        rng = FXRandom(seed: seed)
        super.init()
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Tiny white chips blasted out of an impact.
    func emitChips(at point: FXVec, count: Int, speed: ClosedRange<Double>, size: ClosedRange<Double>, lift: Double = 1) {
        for _ in 0..<count {
            let direction = rng.unit() * 2 * .pi
            let v = FXVec.polar(direction, rng.range(speed)) + FXVec(0, rng.range(0...160) * lift)
            spawn(.chip, at: point + FXVec.polar(direction, rng.range(0...4)), velocity: v, life: rng.range(0.35...0.8),
                  size: rng.range(size), growth: rng.range(1.3...2.2), gravity: 1500, drag: 1.6,
                  alpha: rng.range(0.75...1), spin: rng.signed() * 18, aspect: rng.range(0.6...1.6))
        }
    }

    /// A star flare that runs along `track` over `duration` (light catching the crack edge).
    func emitGlint(along track: [FXVec], duration: Double, size: Double) {
        guard track.count > 1 else { return }
        spawn(.sparkle, at: track[0], velocity: .zero, life: duration, size: size, growth: 1, gravity: 0, drag: 0,
              alpha: 1, spin: rng.signed() * 1.5, track: track)
    }

    /// A short stationary twinkle.
    func emitSparkle(at point: FXVec, size: Double, life: Double = 0.35) {
        spawn(.sparkle, at: point, velocity: .zero, life: life, size: size, growth: 0.6, gravity: 0, drag: 0, alpha: 1,
              spin: rng.signed() * 3)
    }

    /// A soft burst of light that swells and fades.
    func emitGlow(at point: FXVec, size: Double, life: Double, alpha: Double) {
        spawn(.glow, at: point, velocity: .zero, life: life, size: size, growth: 1.35, gravity: 0, drag: 0, alpha: alpha, spin: 0)
    }

    /// Fades everything out quickly (rewind).
    func fadeAll(within seconds: Double) {
        for i in live.indices { live[i].life = min(live[i].life, live[i].age + seconds) }
    }

    func step(dt: Double) {
        guard !live.isEmpty else { return }
        var i = 0
        while i < live.count {
            live[i].age += dt
            var p = live[i]
            if p.age >= p.life {
                p.node.isHidden = true
                pool[p.kind, default: []].append(p.node)
                live.swapAt(i, live.count - 1)
                live.removeLast()
                continue
            }
            let u = p.age / p.life
            if let track = p.track {
                p.position = Self.point(along: track, at: FXEase.inOutCubic(u))
            } else {
                p.velocity = p.velocity * max(0, 1 - p.drag * dt) + FXVec(0, -p.gravity * dt)
                p.position += p.velocity * dt
            }
            p.angle += p.spin * dt
            let envelope: Double
            let scale: Double
            if p.track != nil {
                envelope = sin(.pi * u)
                scale = 0.4 + 0.6 * sin(.pi * u)
            } else {
                envelope = 1 - FXEase.inQuad(u)
                scale = FXEase.lerp(1, p.growth, FXEase.outCubic(u))
            }
            p.node.position = p.position.cgPoint
            p.node.zRotation = CGFloat(p.angle)
            p.node.xScale = CGFloat(p.size * scale * p.aspect / 32)
            p.node.yScale = CGFloat(p.size * scale / p.aspect / 32)
            p.node.alpha = CGFloat(p.alpha * envelope)
            live[i] = p
            i += 1
        }
    }

    private func spawn(_ kind: Kind, at position: FXVec, velocity: FXVec, life: Double, size: Double, growth: Double,
                       gravity: Double, drag: Double, alpha: Double, spin: Double, aspect: Double = 1, track: [FXVec]? = nil) {
        let node = pool[kind]?.popLast() ?? makeNode(kind)
        node.isHidden = false
        node.alpha = 0
        node.position = position.cgPoint
        if node.parent == nil { addChild(node) }
        live.append(Particle(kind: kind, node: node, position: position, velocity: velocity, angle: rng.unit() * 2 * .pi, spin: spin,
                             life: life, size: size, growth: growth, gravity: gravity, drag: drag, alpha: alpha,
                             aspect: aspect, track: track))
    }

    private func makeNode(_ kind: Kind) -> SKSpriteNode {
        let texture: SKTexture
        switch kind {
        case .chip: texture = FXTextures.chip
        case .sparkle: texture = FXTextures.sparkle
        case .glow: texture = FXTextures.softDot
        }
        let node = SKSpriteNode(texture: texture, size: CGSize(width: 32, height: 32))
        node.blendMode = kind == .chip ? .alpha : .add
        return node
    }

    /// Point at fraction `f` of a polyline's length.
    static func point(along track: [FXVec], at f: Double) -> FXVec {
        var total = 0.0
        for i in 1..<track.count { total += track[i].distance(to: track[i - 1]) }
        var remaining = FXEase.clamp01(f) * total
        for i in 1..<track.count {
            let d = track[i].distance(to: track[i - 1])
            if remaining <= d, d > 0 { return track[i - 1] + (track[i] - track[i - 1]) * (remaining / d) }
            remaining -= d
        }
        return track[track.count - 1]
    }
}
