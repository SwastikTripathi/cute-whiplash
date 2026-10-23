import AppKit
import SpriteKit

/// The glass that breaks out. One sprite per shard — its own piece of the screenshot with the letters erased and
/// the cracks baked in, cut to shape by the kit's mask atlas, all drawn in one batch (see `GlassPieces`). Shards
/// loosen in a wave from the impacts with a small outward jolt, then fall out of the screen: flung a little away from
/// the impact, tipping towards you and tumbling as gravity takes them down and off the bottom edge.
final class ShardField {
    /// In front of everything on the glass: the pieces fall out towards you.
    let node = SKNode()
    let uniforms: GlassPieces.Uniforms

    enum Tuning {
        /// Release delay at the rim; shards at the impacts go first.
        static let maxDelay = 0.2
        static let pop = 0.09
        /// pt/s², the same as the letters'.
        static let gravity = 2600.0
        /// Fling away from the impact, and up, as a piece comes loose, pt/s.
        static let fling = 60.0...240.0
        static let lift = 30.0...170.0
        /// Tumble rate around the piece's own horizontal axis, rad/s.
        static let tumble = 2.0...7.0
        /// How much bigger a piece looks once it has tipped out towards you.
        static let tipOut = 0.1
        /// A piece still on screen this long after it let go fades out.
        static let maxFall = 2.4
        static let returnDuration = 1.1
        static let returnStagger = 0.35
        static let edgeAlpha = 0.5
        /// Glass mode: pane opacity of a loose sliver.
        static let glassTint = 0.1...0.18
    }

    private enum Phase {
        case waiting, popping, falling, gone, home
        case returning(start: Double, from: FXPose, edge: Double, loose: Double)
    }

    private struct Shard {
        let node: SKSpriteNode
        let home: FXVec
        /// Half the diagonal of its box: once its centre is that far below the screen, it's gone.
        let radius: Double
        /// Seconds after the shatter.
        let release: Double
        let popOffset: FXVec
        /// Velocity as it comes loose, pt/s.
        let velocity: FXVec
        /// rad/s.
        let spin: Double
        /// Tumble rate around the shard's own axis (fake 3-D), rad/s.
        let flip: Double
        /// Glass mode: pane opacity once loose (0 in screenshot mode).
        let tint: Double
        var phase = Phase.waiting
        var pose: FXPose
        var edge = 0.0
        /// 0 while still part of the screen, 1 once it has broken loose (glass panes only show when loose).
        var loose = 0.0
        var sheen = 0.0
        /// Direction of the specular band across the piece, and where it starts in its sweep.
        let glintAngle: Double
        let glintPhase: Double
        /// The band's offset from the piece's centre and its strength.
        var glint = (offset: 0.0, strength: 0.0)
    }

    private let start: Double
    private var shards: [Shard] = []

    /// `impacts`: crack centres (indexed by `ShatterPlan.Shard.nearestImpact`). `backdrop` nil = glass mode.
    init(kit: ShatterKit, textures: ShatterTextures, impacts: [FXVec], backdrop: SKTexture?, sceneSize: CGSize, time: Double,
         rng: inout FXRandom) {
        start = time
        let plan = kit.plan
        let overlay = kit.overlayRect
        let masks = textures.masks
        let cracks = textures.cracks
        if backdrop != nil {
            uniforms = GlassPieces.Uniforms(
                masks: masks, erase: textures.erase, cracks: cracks,
                overlayRect: CGRect(x: overlay.minX / sceneSize.width, y: overlay.minY / sceneSize.height,
                                    width: overlay.width / sceneSize.width, height: overlay.height / sceneSize.height))
        } else {
            uniforms = GlassPieces.Uniforms(masks: masks)
        }
        let shader = GlassPieces.shader(backdrop != nil ? .backdropShard : .glassShard, uniforms: uniforms)
        for (index, source) in plan.shards.enumerated() {
            let box = kit.masks.boxes[index]
            let texture: SKTexture, textureRect: CGRect
            if let backdrop {
                texture = backdrop
                textureRect = CGRect(x: box.minX / sceneSize.width, y: box.minY / sceneSize.height,
                                     width: box.width / sceneSize.width, height: box.height / sceneSize.height)
            } else {
                texture = cracks
                textureRect = CGRect(x: (box.minX - overlay.minX) / overlay.width, y: (box.minY - overlay.minY) / overlay.height,
                                     width: box.width / overlay.width, height: box.height / overlay.height)
            }
            let tint = backdrop == nil ? rng.range(Tuning.glassTint) : 0
            let sprite = GlassPieces.sprite(texture: texture, textureRect: textureRect, box: box, pivot: source.centroid,
                                            maskCell: kit.masks.cells[index], shader: shader, tint: tint * 0.2)
            GlassPieces.setGlint(angle: 0, offset: 0, strength: 0, on: sprite)
            node.addChild(sprite)

            let outward = (source.centroid - impacts[source.nearestImpact]).normalized
            let release = min(Tuning.maxDelay, Tuning.maxDelay * pow(source.impactDistance, 0.9) + rng.range(0...0.04))
            let fling = (outward + FXVec.polar(rng.unit() * 2 * .pi, 0.6)).normalized * rng.range(Tuning.fling)
            shards.append(Shard(
                node: sprite, home: source.centroid, radius: hypot(box.width, box.height) / 2, release: release,
                popOffset: (outward + FXVec.polar(rng.unit() * 2 * .pi, 0.5)).normalized * rng.range(2...6),
                velocity: fling + FXVec(0, rng.range(Tuning.lift)),
                spin: rng.sign() * rng.range(1.2...3.5), flip: rng.range(Tuning.tumble), tint: tint,
                pose: FXPose(position: source.centroid), glintAngle: rng.unit() * 2 * .pi, glintPhase: rng.unit()))
        }
    }

    var count: Int { shards.count }

    /// When shard `index` starts to move, seconds after the shatter.
    func release(of index: Int) -> Double { shards[index].release }

    var isGone: Bool {
        shards.allSatisfy {
            if case .gone = $0.phase { return true }
            return false
        }
    }

    var isHome: Bool {
        shards.allSatisfy {
            switch $0.phase {
            case .home, .waiting: return true
            default: return false
            }
        }
    }

    func step(time: Double) {
        for i in shards.indices { update(&shards[i], time: time) }
    }

    func beginReturn(at time: Double) {
        let latest = max(shards.map(\.release).max() ?? 0, 0.01)
        for i in shards.indices {
            switch shards[i].phase {
            case .waiting, .home:
                shards[i].phase = .home
            default:
                var from = shards[i].pose
                if case .gone = shards[i].phase { from.alpha = 0 }
                // Reverse stagger: the last to leave comes back first.
                let delay = (1 - shards[i].release / latest) * Tuning.returnStagger
                shards[i].phase = .returning(start: time + delay, from: from, edge: shards[i].edge, loose: shards[i].loose)
                shards[i].node.isHidden = false
            }
        }
    }

    private func update(_ s: inout Shard, time: Double) {
        let t = time - start - s.release
        switch s.phase {
        case .waiting:
            guard t >= 0 else { return }
            s.phase = .popping
            update(&s, time: time)
            return
        case .popping:
            let u = t / Tuning.pop
            if u >= 1 {
                s.phase = .falling
                update(&s, time: time)
                return
            }
            // The loosening jolt: a little outwards and towards the viewer, edges catching the light.
            let e = FXEase.outCubic(u)
            s.pose.position = s.home + s.popOffset * e
            s.pose.scale = 1 + 0.04 * e
            s.edge = Tuning.edgeAlpha * e
            s.loose = e
            s.glint = (-0.8 + 0.5 * e, 0.3 * e)
        case .falling:
            let u = t - Tuning.pop
            let position = s.home + s.popOffset + s.velocity * u + FXVec(0, -0.5 * Tuning.gravity * u * u)
            if position.y < -s.radius || u >= Tuning.maxFall {
                s.phase = .gone
                s.node.isHidden = true
                return
            }
            s.pose.position = position
            s.pose.scale = 1.04 + Tuning.tipOut * FXEase.outCubic(u / 0.6)
            s.pose.rotation = s.spin * u
            let phi = s.flip * u
            s.pose.flip = max(0.08, abs(cos(phi)))
            // The back of a piece of screen is dark; tumbling pieces flash as they catch the light.
            s.pose.darkness = cos(phi) < 0 ? 0.45 : 0
            s.pose.alpha = 1 - FXEase.smoothstep(Tuning.maxFall - 0.4, Tuning.maxFall, u)
            s.sheen = 0.18 * pow(max(0, sin(2 * phi)), 8)
            // Light catching the tumbling glass: a bright band sweeps across the piece as it flips.
            let sweep = (phi / 2.4 + s.glintPhase).truncatingRemainder(dividingBy: 1)
            s.glint = (-0.8 + 1.6 * sweep, 0.42)
            s.edge = Tuning.edgeAlpha
            s.loose = 1
        case .gone, .home:
            return
        case let .returning(start, from, edge, loose):
            let u = (time - start) / Tuning.returnDuration
            guard u > 0 else { return }
            if u >= 1 {
                s.phase = .home
                s.pose = FXPose(position: s.home)
                s.edge = 0
                s.loose = 0
            } else {
                s.pose = FXPose.blend(from, FXPose(position: s.home), motion: FXEase.inOutCubic(u), fade: FXEase.inOutCubic(u))
                s.edge = edge + (Tuning.edgeAlpha - edge) * FXEase.smoothstep(0, 0.4, u) - Tuning.edgeAlpha * FXEase.smoothstep(0.6, 1, u)
                s.loose = loose * (1 - FXEase.inOutCubic(u))
            }
            s.sheen = 0
            s.glint = (0, 0)
        }
        apply(s)
    }

    private func apply(_ s: Shard) {
        let node = s.node
        node.position = s.pose.position.cgPoint
        node.zRotation = CGFloat(s.pose.rotation)
        node.xScale = CGFloat(s.pose.scale)
        node.yScale = CGFloat(s.pose.scale * s.pose.flip)
        // Nearer (bigger) pieces draw on top.
        node.zPosition = CGFloat(s.pose.scale)
        // Glass slivers get brighter edges: the edge is most of what you see of them.
        GlassPieces.setShade(brightness: 1 - s.pose.darkness, opacity: s.pose.alpha, sheen: s.sheen,
                             edge: max(0, s.edge) * (s.tint > 0 ? 1.5 : 1), on: node)
        if s.tint > 0 { GlassPieces.setTint(s.tint * (0.2 + 0.8 * s.loose), on: node) }
        GlassPieces.setGlint(angle: s.glintAngle - s.pose.rotation, offset: s.glint.offset, strength: s.glint.strength, on: node)
    }
}
