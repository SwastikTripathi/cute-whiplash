import AppKit
import SpriteKit

/// The text on screen as individual letters. Every hit knocks a patch of letters loose around its impact right
/// away (`release`): they jiggle, pop away from the impact, drop and recede INTO the screen. At the shatter the
/// letters on the broken glass and a ring around the hits follow (`loosen`): they drop out of the screen and pile up
/// on its bottom edge. Letters nowhere near a hit stay put. Custom kinematics — no physics bodies.
///
/// A resting letter is hidden: the backdrop already shows it. Its sprite and its eraser only appear once it comes
/// loose, so a full screen of text costs next to nothing until it is hit.
///
/// Owns two layers the DestructionLayer places: `erasers` (paint over the spots letters leave; above the crack
/// refraction cells, which are copies of the screenshot) and `surface` (the loose letters).
final class GlyphField {
    let erasers = SKNode()
    let surface = SKNode()
    /// A letter hit the floor (throttling is up to the caller).
    var onLanded: (() -> Void)?
    /// The letters' atlas (nil when there are none), e.g. to upload it ahead of the shatter.
    private(set) var texture: SKTexture?

    enum Tuning {
        static let gravity = 2600.0
        static let sinkDuration = 0.75...1.15
        static let returnDuration = 1.1
        static let returnStagger = 0.35
        /// A hit's loosening wave: speed (pt/s) and how long each letter jiggles before it lets go.
        static let hitWaveSpeed = 2200.0
        static let hitJiggle = 0.05...0.12
        /// Kick away from the impact for letters right next to it, pt/s (fades to nothing at the patch edge).
        static let hitPop = 90.0...300.0
        /// How long a letter knocked loose by a hit drops before it recedes into the screen.
        static let hitDropTime = 0.16...0.42
        /// A hit's patch widens until it takes at least this many letters (if there are that many near enough).
        static let hitMinimumLetters = 40
        /// Speed of the shatter's loosening wave through the letters around the hole, pt/s.
        static let shatterWaveSpeed = 3500.0
        /// At the shatter, letters this far out (in patch reach; 1 = a hit's patch edge) come loose too.
        static let shatterReach = 1.35
        /// A letter tumbles down a steep spot of the pile at most this often before it stays where it is.
        static let maxSlides = 24
    }

    private enum Phase {
        case resting
        case jiggling(start: Double, detach: Double)
        case falling
        /// Knocked loose by a hit: slipping through the cracks, receding into the screen towards `target`.
        case sinking(start: Double, duration: Double, entry: FXPose, velocity: FXVec, target: FXVec, tumble: Double)
        case landed
        case gone
        case returning(start: Double, from: FXPose)
    }

    private struct Glyph {
        let node: SKSpriteNode
        let home: FXVec
        let halfSize: FXVec
        let background: NSColor
        /// Paints its spot once it comes loose (screenshot mode); nil while at rest.
        var eraser: SKSpriteNode?
        /// The hit that knocked it loose (nil: the shatter did, or it is at rest).
        var impact: FXVec?
        /// When a hit-loosened letter stops dropping and recedes into the screen.
        var sinkAt: Double?
        var phase = Phase.resting
        var pose: FXPose
        var velocity = FXVec.zero
        var spin = 0.0
        var bounces = 0
        /// Times it slid off a steep spot of the pile.
        var slides = 0
        /// When it came loose (scene time), for the reverse stagger on rewind.
        var loosenAt = 0.0
        /// Glass mode: hidden where it stands for this shatter (it is off the broken glass; see `loosen`).
        var sitsOut = false
    }

    private let sceneSize: CGSize
    private let backdropMode: Bool
    private var rng: FXRandom
    private var glyphs: [Glyph] = []
    private var plan: ShatterPlan?
    /// Every hit so far this round. Kept across `install`, so text that arrives after a hit still drops its patch.
    private var patches: [LetterPatch] = []
    /// Height of the letter pile per 6-pt column along the bottom edge.
    private var pile: [Double]
    private let pileColumn = 6.0

    init(sceneSize: CGSize, backdropMode: Bool, seed: UInt64) {
        self.sceneSize = sceneSize
        self.backdropMode = backdropMode
        rng = FXRandom(seed: seed)
        pile = Array(repeating: 0, count: Int(ceil(sceneSize.width / pileColumn)) + 1)
        erasers.isHidden = true
        surface.isHidden = true
    }

    var isEmpty: Bool { glyphs.isEmpty }
    var count: Int { glyphs.count }

    /// Letters still moving (a shatter is "settled" when none are). Letters that never came loose count as settled.
    var isSettled: Bool {
        glyphs.allSatisfy {
            switch $0.phase {
            case .resting, .landed, .gone: return true
            default: return false
            }
        }
    }

    /// Where the letters that have come loose (by a hit or the shatter) used to sit. (Not the ones sitting a glass-mode
    /// shatter out: they never show.)
    var looseHomes: [CGPoint] {
        glyphs.compactMap {
            if case .resting = $0.phase { return nil }
            return $0.sitsOut ? nil : $0.home.cgPoint
        }
    }

    var isHome: Bool {
        glyphs.allSatisfy {
            if case .resting = $0.phase { return true }
            return false
        }
    }

    /// Spots the letters leave behind, for the shard bake: (rect, background).
    var erasedSpots: [(CGRect, NSColor)] {
        glyphs.map { (CGRect(x: $0.home.x - $0.halfSize.x, y: $0.home.y - $0.halfSize.y,
                             width: $0.halfSize.x * 2, height: $0.halfSize.y * 2), $0.background) }
    }

    // MARK: - Setup

    /// Builds sprites (hidden until `loosen`) and erasers for `samples`, replacing any previous set.
    func install(_ samples: [GlyphSample], backdropScale: CGFloat?) {
        install(GlyphAtlas.build(glyphs: samples, sceneHeight: sceneSize.height, backdropScale: backdropScale))
    }

    /// Same, from an atlas built elsewhere (e.g. on a background queue); nil clears.
    func install(_ atlas: GlyphAtlas?) {
        removeAll()
        guard let atlas else { return }
        let texture = atlas.texture()
        self.texture = texture
        for entry in atlas.entries {
            let node = SKSpriteNode(texture: SKTexture(rect: entry.textureRect, in: texture), size: entry.rect.size)
            let home = FXVec(entry.rect.midX, entry.rect.midY)
            node.position = home.cgPoint
            node.color = .black
            node.isHidden = true
            surface.addChild(node)
            glyphs.append(Glyph(node: node, home: home, halfSize: FXVec(entry.rect.width / 2, entry.rect.height / 2),
                                background: entry.background, pose: FXPose(position: home)))
        }
    }

    /// Paints over the spot `g` leaves (screenshot mode), the moment it comes loose.
    private func showEraser(_ g: inout Glyph) {
        guard backdropMode, g.eraser == nil else { return }
        let node = SKSpriteNode(color: g.background, size: CGSize(width: g.halfSize.x * 2, height: g.halfSize.y * 2))
        node.position = g.home.cgPoint
        erasers.addChild(node)
        g.eraser = node
    }

    /// Takes `g` off the screen: sprite on show over its eraser (identical to the backdrop until it moves).
    private func comeLoose(_ g: inout Glyph) {
        showEraser(&g)
        g.node.isHidden = false
        erasers.isHidden = false
        surface.isHidden = false
    }

    /// Back to the pristine state after a rewind: every letter home and hidden, ready for the next shatter.
    func reset() {
        for i in glyphs.indices {
            glyphs[i].phase = .resting
            glyphs[i].pose = FXPose(position: glyphs[i].home)
            glyphs[i].velocity = .zero
            glyphs[i].bounces = 0
            glyphs[i].slides = 0
            glyphs[i].sitsOut = false
            glyphs[i].impact = nil
            glyphs[i].sinkAt = nil
            glyphs[i].eraser = nil
            let node = glyphs[i].node
            if node.parent !== surface {
                node.removeFromParent()
                surface.addChild(node)
            }
            node.isHidden = true
            apply(glyphs[i])
        }
        erasers.removeAllChildren()
        patches = []
        plan = nil
        for i in pile.indices { pile[i] = 0 }
        erasers.isHidden = true
        surface.isHidden = true
    }

    func removeAll() {
        erasers.removeAllChildren()
        surface.removeAllChildren()
        glyphs = []
        texture = nil
        plan = nil
        for i in pile.indices { pile[i] = 0 }
        erasers.isHidden = true
        surface.isHidden = true
    }

    // MARK: - Hits

    /// A hit at `patch.center`: the letters in its patch come loose right away, in a fast wave from the impact.
    /// Remembered, so letters installed later (OCR finishing after the hit) drop too — see `replayHits`.
    func release(_ patch: LetterPatch, at time: Double) {
        patches.append(patch)
        drop(patch, at: time)
    }

    /// A hit at the edge of the text still knocks a handful loose: the patch widens (up to 1.8×) until it takes
    /// at least `Tuning.hitMinimumLetters`, when there are that many near enough.
    private func effectivePatch(for patch: LetterPatch) -> LetterPatch {
        var widened = patch
        for factor in [1.0, 1.4, 1.8] {
            widened = patch.scaled(by: factor)
            if candidates(for: widened).count >= Tuning.hitMinimumLetters { break }
        }
        return widened
    }

    private func candidates(for patch: LetterPatch) -> [Int] {
        let bounds = patch.bounds
        return glyphs.indices.filter { i in
            guard case .resting = glyphs[i].phase, !glyphs[i].sitsOut else { return false }
            let home = glyphs[i].home
            return bounds.contains(home.cgPoint) && patch.takes(i, at: home)
        }
    }

    /// Drops every earlier hit's patch again from the letters just installed (late text catches up at once).
    func replayHits(at time: Double) {
        for patch in patches { drop(patch, at: time) }
    }

    /// A smash on the broken screen during the break: the letters still standing around it are knocked off and drop
    /// to the pile. (Glass mode: nothing — the live screen still shows the real ones.)
    func smash(_ patch: LetterPatch, at time: Double) {
        guard plan != nil, backdropMode else { return }
        loosen(patch, at: time)
    }

    private func drop(_ patch: LetterPatch, at time: Double) {
        guard plan == nil else { return } // after the shatter, `loosen` has taken over
        loosen(patch, at: time)
    }

    private func loosen(_ patch: LetterPatch, at time: Double) {
        let patch = effectivePatch(for: patch)
        for i in candidates(for: patch) {
            let home = glyphs[i].home
            let start = time + 0.015 + home.distance(to: patch.center) / Tuning.hitWaveSpeed + rng.range(0...0.03)
            glyphs[i].phase = .jiggling(start: start, detach: start + rng.range(Tuning.hitJiggle))
            glyphs[i].impact = patch.center
            glyphs[i].loosenAt = start
            comeLoose(&glyphs[i])
        }
    }

    // MARK: - Shatter

    /// Starts the loosening wave. `shardRelease(i)` is when shard i starts falling (seconds after `time`): letters
    /// sitting on a shard go with it. `lateArrival`: the glass already broke, so letters on it are gone (they were
    /// part of the shards' picture).
    ///
    /// Glass mode (no screenshot): the live screen keeps showing the real text wherever the glass is still whole,
    /// so a synthetic copy of it there would read as doubled text. Only the letters on the broken glass show and
    /// fall — the dead panel covers the real text under the hole; the others sit it out, hidden.
    ///
    /// Only letters still at rest take part, and only those on the broken glass or near a hit (`Tuning.shatterReach`
    /// of a hit's patch); the rest of the screen's text stays where it is.
    func loosen(at time: Double, plan: ShatterPlan, impacts: [FXVec], shardRelease: (Int) -> Double, lateArrival: Bool = false) {
        self.plan = plan
        for i in glyphs.indices {
            guard case .resting = glyphs[i].phase else { continue }
            let home = glyphs[i].home
            let wave: Double
            let shard = plan.shard(containing: home)
            if shard == nil, !isNearHit(home, impacts: impacts) { continue }
            if (lateArrival && shard != nil) || (!backdropMode && shard == nil) {
                glyphs[i].phase = .gone
                glyphs[i].pose.alpha = 0
                glyphs[i].node.isHidden = true
                glyphs[i].sitsOut = !backdropMode
                continue
            }
            if let shard {
                // On the broken glass: gone at once (ahead of its shard if that one is slow to fall).
                wave = min(shardRelease(shard), 0.06) + rng.range(0...0.03)
                glyphs[i].phase = .jiggling(start: time, detach: time + wave)
            } else {
                let distance = impacts.map { $0.distance(to: home) }.min() ?? 0
                wave = min(0.3, 0.02 + distance / Tuning.shatterWaveSpeed + rng.range(0...0.04))
                glyphs[i].phase = .jiggling(start: time + wave, detach: time + wave + rng.range(Tuning.hitJiggle))
            }
            glyphs[i].loosenAt = time + wave
            comeLoose(&glyphs[i])
        }
    }

    /// Within `Tuning.shatterReach` of a hit's patch (or, with no hits recorded, of an impact's typical patch).
    private func isNearHit(_ p: FXVec, impacts: [FXVec]) -> Bool {
        if patches.isEmpty {
            let radius = LetterPatch.radius(intensity: 1) * Tuning.shatterReach
            return impacts.contains { $0.distance(to: p) <= radius }
        }
        return patches.contains { $0.reach(of: p) <= Tuning.shatterReach }
    }

    // MARK: - Rewind

    func beginReturn(at time: Double) {
        let loose = glyphs.filter { if case .resting = $0.phase { return false } else { return !$0.sitsOut } }.map(\.loosenAt)
        let earliest = loose.min() ?? 0
        let span = max((loose.max() ?? 0) - earliest, 0.01)
        for i in glyphs.indices {
            if case .resting = glyphs[i].phase { continue }
            if glyphs[i].sitsOut {
                glyphs[i].phase = .resting
                continue
            }
            // Reverse stagger: the last to leave comes back first.
            let delay = (1 - (glyphs[i].loosenAt - earliest) / span) * Tuning.returnStagger
            var from = glyphs[i].pose
            if case .gone = glyphs[i].phase { from.alpha = 0 }
            glyphs[i].phase = .returning(start: time + delay, from: from)
            glyphs[i].node.isHidden = false
        }
    }

    // MARK: - Per frame

    func step(time: Double, dt: Double) {
        guard !glyphs.isEmpty, !surface.isHidden else { return }
        for i in glyphs.indices { update(&glyphs[i], time: time, dt: dt) }
    }

    private func update(_ g: inout Glyph, time: Double, dt: Double) {
        switch g.phase {
        case .resting, .gone:
            return
        case let .jiggling(start, detach):
            guard time >= start else { return }
            if time >= detach {
                detachGlyph(&g, time: time)
            } else {
                let u = (time - start) / max(detach - start, 0.01)
                let amplitude = 0.35 + 1.1 * u
                g.pose.position = g.home + FXVec(sin(time * 71 + g.home.x) * amplitude, cos(time * 83 + g.home.y) * amplitude * 0.6)
                g.pose.rotation = sin(time * 57 + g.home.x * 0.3) * 0.09 * u
            }
        case .falling:
            if plan == nil, let sinkAt = g.sinkAt, time >= sinkAt, g.bounces == 0 {
                // Knocked loose by a hit, no hole yet: it slips through the cracks, receding into the screen.
                let target = g.pose.position + FXVec(g.velocity.x * 0.3, -110 - 0.12 * max(0, -g.velocity.y))
                startSinking(&g, time: time, target: target)
                break
            }
            fall(&g, time: time, dt: dt)
        case let .sinking(start, duration, entry, velocity, target, tumble):
            let u = (time - start) / duration
            if u >= 1 {
                g.phase = .gone
                g.pose.alpha = 0
                g.node.isHidden = true
                return
            }
            let s = FXDepth.scale(u)
            let momentum = velocity * (0.1 * FXEase.outCubic(u))
            g.pose.position = target + (entry.position + momentum - target) * s
            g.pose.scale = entry.scale * s
            g.pose.rotation = entry.rotation + tumble * pow(u, 1.2)
            g.pose.flip = max(0.25, abs(cos(tumble * 0.7 * u)))
            g.pose.darkness = 1 - FXDepth.brightness(atScale: s)
            g.pose.alpha = 1 - FXEase.smoothstep(0.5, 0.95, u)
        case .landed:
            return
        case let .returning(start, from):
            let u = (time - start) / Tuning.returnDuration
            var home = FXPose(position: g.home)
            // Glass mode: the real letter is back on the live screen once the hole closes, so the copy flies home
            // and melts into it rather than landing on top of it.
            if !backdropMode { home.alpha = 0 }
            if u >= 1 {
                g.phase = .resting
                g.pose = home
            } else if u > 0 {
                g.pose = FXPose.blend(from, home, motion: FXEase.inOutCubic(u), fade: FXEase.inOutCubic(u))
                if !backdropMode { g.pose.alpha = max(g.pose.alpha, 0.9 * sin(.pi * u)) }
            }
        }
        apply(g)
    }

    private func detachGlyph(_ g: inout Glyph, time: Double) {
        g.spin = rng.signed() * 5
        if let impact = g.impact {
            // Knocked off by a hit: flung away from the impact (hardest right next to it), then it drops — before the
            // shatter slipping through the cracks into the screen, after it (a smash in the break) to the pile.
            let away = g.home - impact
            let nearness = 1 - FXEase.clamp01(away.length / (LetterPatch.radius(intensity: 1) * 1.2))
            let kick = away.normalized * (rng.range(Tuning.hitPop) * (0.25 + 0.75 * nearness))
            g.velocity = kick + FXVec(rng.signed() * 50, rng.range(30...140))
            g.spin = rng.signed() * (4 + 6 * nearness)
            if plan == nil { g.sinkAt = time + rng.range(Tuning.hitDropTime) }
            g.phase = .falling
        } else {
            // Shaken off by the shatter: out of the screen, down to the pile.
            g.velocity = FXVec(rng.signed() * 70, rng.range(40...150))
            g.phase = .falling
        }
    }

    private func startSinking(_ g: inout Glyph, time: Double, target: FXVec) {
        g.phase = .sinking(start: time, duration: rng.range(Tuning.sinkDuration), entry: g.pose, velocity: g.velocity,
                           target: target, tumble: g.spin * 0.5 + rng.signed() * 2.5)
    }

    private func fall(_ g: inout Glyph, time: Double, dt: Double) {
        g.velocity = g.velocity * max(0, 1 - 0.5 * dt) + FXVec(0, -Tuning.gravity) * dt
        g.pose.position += g.velocity * dt
        g.pose.rotation += g.spin * dt

        // Walls.
        if g.pose.position.x < g.halfSize.x { g.pose.position.x = g.halfSize.x; g.velocity.x = abs(g.velocity.x) * 0.4 }
        if g.pose.position.x > sceneSize.width - g.halfSize.x {
            g.pose.position.x = sceneSize.width - g.halfSize.x
            g.velocity.x = -abs(g.velocity.x) * 0.4
        }
        // Floor, raised by the pile.
        let floor = pileHeight(at: g.pose.position.x) + g.halfSize.y * 0.8
        guard g.pose.position.y <= floor, g.velocity.y < 0 else { return }
        g.pose.position.y = floor
        let reach = max(g.halfSize.x * 2, pileColumn * 1.5)
        let left = pileHeight(at: g.pose.position.x - reach), right = pileHeight(at: g.pose.position.x + reach)
        let here = pileHeight(at: g.pose.position.x)
        if g.bounces < 2, -g.velocity.y > 260 {
            g.bounces += 1
            g.velocity = FXVec(g.velocity.x * 0.6, -g.velocity.y * 0.3)
            g.spin *= 0.5
            if g.bounces == 1 { onLanded?() }
        } else if g.slides < Tuning.maxSlides, min(left, right) < here - g.halfSize.y * 0.9 {
            // Too steep to rest on: tumble down the side of the pile (angle of repose).
            g.slides += 1
            let direction: Double = left < right ? -1 : (right < left ? 1 : rng.sign())
            g.velocity = FXVec(direction * rng.range(110...190), 40)
            g.spin = direction * -rng.range(3...6)
        } else {
            g.phase = .landed
            g.velocity = .zero
            // Lie down: settle towards the nearest side.
            g.pose.rotation = (g.pose.rotation / (.pi / 2)).rounded() * (.pi / 2) + rng.signed() * 0.25
            // A lying letter is about half its height thick.
            let top = here + g.halfSize.y * 0.9
            let first = max(0, Int((g.pose.position.x - g.halfSize.x) / pileColumn))
            let last = min(pile.count - 1, Int((g.pose.position.x + g.halfSize.x) / pileColumn))
            if first <= last { for c in first...last { pile[c] = max(pile[c], top) } }
            if g.bounces == 0 { onLanded?() }
        }
    }

    /// Highest point of the pile under a letter centred at `x`.
    private func pileHeight(at x: Double) -> Double {
        let column = min(pile.count - 1, max(0, Int(x / pileColumn)))
        return pile[column]
    }

    private func apply(_ g: Glyph) {
        let node = g.node
        node.position = g.pose.position.cgPoint
        node.zRotation = CGFloat(g.pose.rotation)
        node.xScale = CGFloat(g.pose.scale)
        node.yScale = CGFloat(g.pose.scale * g.pose.flip)
        node.alpha = CGFloat(g.pose.alpha)
        node.colorBlendFactor = CGFloat(g.pose.darkness)
    }
}
