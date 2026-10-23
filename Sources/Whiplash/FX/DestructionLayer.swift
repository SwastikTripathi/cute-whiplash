import AppKit
import SpriteKit

enum DestructionEvent {
    case cracked(intensity: CGFloat)
    case shatterBegan
    case glyphLanded
    case reassembleBegan
    case reassembled
}

/// The screen-breaking effects: cracks, shattering (the glass falls out, the display behind it dies, the text
/// drops), and reassembly.
/// Add at position .zero in a scene whose size == `size`; all points are scene coordinates.
/// Call `step(dt:)` once per frame.
///
/// Lifecycle: `crack` any number of times → `shatter` → (hold) → `reassemble`. `reassemble` works at any moment
/// (mid-crack, mid-shatter, after) and always ends with nothing but the pristine backdrop on screen, after which
/// the layer is ready to crack again. Every completion handler is called exactly once: a `shatter` completion
/// still pending when `reassemble` starts is called right then. `crack` is ignored once the glass has shattered
/// or while it rewinds.
///
/// Main-thread cost: how the glass breaks (the "shatter kit") is worked out on a background queue as soon as the
/// cracks change (or, with `defersShatterPreparation`, once that is turned off) and its textures are uploaded on a
/// quiet frame, so `shatter()` only builds nodes (`isShatterReady`).
/// When that is not ready yet (a crack or text arrived a moment before), `shatter()` flashes the impacts right away
/// and the glass gives way `Tuning.breakDelay` later, once the background work is done — never a long stall in the
/// middle of the money shot. The kit is delivered through the main queue, which the app's run loop drains.
final class DestructionLayer: SKNode {
    var onEvent: ((DestructionEvent) -> Void)?
    /// While true, the shatter is not prepared in the background after every crack. Set it while more damage is on
    /// its way (a volley of strikes): each preparation costs ~100 MB of bitmaps and textures at 2x, and a crack that
    /// lands meanwhile throws it away. Turn it off once the damage is final; a shatter that comes before the kit is
    /// ready simply takes the deferred path.
    var defersShatterPreparation = false

    let size: CGSize
    private let backdrop: SKTexture?
    /// Pixels per point of the backdrop texture (nil in glass mode).
    private let backdropScale: CGFloat?
    private var time = 0.0
    private var rng: FXRandom
    private let particles: FXParticles
    private let cracks: CrackField
    private let glyphs: GlyphField
    /// Uploads textures ahead of the frames that need them.
    private let primer = FXPrimer()

    private enum Phase { case intact, breaking, shattering, shattered, reassembling }
    private var phase = Phase.intact
    /// When `shatter()` was called.
    private var shatterStart = 0.0
    private var shatterCompletions: [() -> Void] = []
    private var reassembleCompletions: [() -> Void] = []
    /// Glyphs that arrived during the rewind; installed once the glass is whole again.
    private var pendingGlyphs: [GlyphSample]?
    /// Glyphs that arrived while the glass was about to break; handed over right after it breaks.
    private var lateGlyphs: [GlyphSample]?
    /// Glyphs whose atlas is being baked in the background (installed when it lands, or at the shatter).
    private var glyphRequest: (id: Int, samples: [GlyphSample])?
    private var glyphRequests = 0
    private var lastLanded = -Double.infinity
    /// Bumped whenever what a shatter would look like changes (a crack, new glyphs, a rewind).
    private var generation = 0
    /// A shatter kit prepared in the background for `generation` (cracks baked fully grown), with its textures.
    private var preparedKit: (generation: Int, kit: ShatterKit?, textures: ShatterTextures?)?
    /// Generation of the kit being prepared in the background, if any.
    private var preparing: Int?
    /// Cracks (by index in `cracks.patterns`) that don't flash when the glass gives way: the glass creaking.
    private var quietCracks: Set<Int> = []

    /// A shatter waiting for its background work; the glass gives way at `at`.
    private struct PendingBreak {
        let at: Double
        let work: FXBackground<BreakWork>
        /// Letters taken over from a still-baking `setGlyphs` (handed back if a rewind cancels the break).
        let samples: [GlyphSample]?
        /// As soon as the work is done — a few frames before the break — the letters' sprites and the kit's textures
        /// are made and uploaded, leaving the break's own frame only the shards and the dead panel to build.
        var collected = false
        var textures: ShatterTextures?
    }
    private struct BreakWork {
        var atlas: GlyphAtlas?
        var kit: ShatterKit?
    }
    private var pendingBreak: PendingBreak?

    private struct Shattered {
        let plan: ShatterPlan
        let shards: ShardField
        let panel: DeadPanel
        /// The vector cracks took over from the baked ones during the rewind.
        var cracksRestored = false
    }
    private var shattered: Shattered?

    /// Draw order, bottom → top. Erasers sit above the crack refraction cells (copies of the screenshot, which would
    /// otherwise still show a letter that fell) and below the dead panel, so they never paint over it. The panel is
    /// the display, under the glass and its cracks; the pieces of glass fall out in front of it all.
    private enum Z {
        static let backdrop: CGFloat = 0
        static let cells: CGFloat = 1
        static let erasers: CGFloat = 2
        static let panel: CGFloat = 3
        static let rim: CGFloat = 4
        static let glyphs: CGFloat = 5
        static let cracks: CGFloat = 6
        static let shards: CGFloat = 7
        static let particles: CGFloat = 8
    }

    enum Tuning {
        /// Longest a shatter may take (from the call) before its completion fires, whatever is still moving.
        static let shatterSettleLimit = 2.2
        /// When the shatter kit is not ready at the call: how long the impacts flash before the glass gives way,
        /// while the kit is finished off the main thread.
        static let breakDelay = 0.07
        /// The vector cracks retract after the pieces are back: long enough to see the web zip back into the impact.
        static let crackRetract = 0.7
        static let landedEventInterval = 0.045
    }

    /// `backdrop`: screenshot texture filling the scene (nil = transparent "glass" mode over the live screen).
    /// `glyphs`: text to peel off and drop, scene coordinates.
    convenience init(size: CGSize, backdrop: SKTexture?, glyphs: [GlyphSample]) {
        self.init(size: size, backdrop: backdrop, glyphs: glyphs, seed: UInt64.random(in: 1...UInt64.max))
    }

    /// First use of SpriteKit textures and shaders and of the heavy font costs tens of milliseconds: pay it when the
    /// layer is created rather than in the middle of the first crack or the shatter.
    private static let warmUp: Void = {
        _ = [FXTextures.softDot, FXTextures.sparkle, FXTextures.chip]
        _ = GlassPieces.shader(.backdropShard, uniforms: GlassPieces.Uniforms(masks: FXTextures.softDot))
    }()

    /// Same as `init(size:backdrop:glyphs:)` with a fixed random seed, for reproducible demos and tests.
    init(size: CGSize, backdrop: SKTexture?, glyphs samples: [GlyphSample], seed: UInt64) {
        _ = Self.warmUp
        self.size = size
        self.backdrop = backdrop
        backdropScale = backdrop.map { $0.size().width / max(size.width, 1) }
        rng = FXRandom(seed: seed)
        particles = FXParticles(seed: rng.next())
        cracks = CrackField(sceneSize: size, backdrop: backdrop, particles: particles, seed: rng.next())
        glyphs = GlyphField(sceneSize: size, backdropMode: backdrop != nil, seed: rng.next())
        super.init()
        if let backdrop {
            let sprite = SKSpriteNode(texture: backdrop, size: size)
            sprite.anchorPoint = .zero
            sprite.zPosition = Z.backdrop
            addChild(sprite)
        }
        for (node, z) in [(glyphs.erasers, Z.erasers), (cracks.cellLayer, Z.cells), (glyphs.surface, Z.glyphs),
                          (cracks.lineLayer, Z.cracks), (particles, Z.particles), (primer, Z.particles)] {
            node.zPosition = z
            addChild(node)
        }
        glyphs.onLanded = { [weak self] in self?.glyphLanded() }
        glyphs.install(samples, backdropScale: backdropScale)
        primer.prime([FXTextures.softDot, FXTextures.sparkle, FXTextures.chip] + (glyphs.texture.map { [$0] } ?? []))
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shards of the current shatter (0 when the glass is whole).
    var shardCount: Int { shattered?.shards.count ?? 0 }
    /// Cracks in the glass, the ones from smashes in the break included (tests and diagnostics).
    var crackCount: Int { cracks.patterns.count }
    /// Letters installed and ready to (or already) peel off.
    var letterCount: Int { glyphs.count }
    /// Where the letters that have come loose used to sit (tests and diagnostics).
    var looseLetterHomes: [CGPoint] { glyphs.looseHomes }
    /// Letters handed over by `setGlyphs` are still being baked off the main thread.
    var isPreparingLetters: Bool { glyphRequest != nil }
    /// Whether `shatter()` would break the glass on the spot — its background preparation has landed and the cracks
    /// have grown as far as it baked them — rather than `Tuning.breakDelay` later.
    var isShatterReady: Bool {
        phase == .intact && glyphRequest == nil && preparedKit?.generation == generation && cracks.isSettled(at: time)
    }

    /// Supplies (or replaces) the text to drop. May arrive late — OCR runs while the whip is striking —
    /// but always before `shatter` when possible; glyphs arriving after `shatter` may simply fall immediately.
    /// (The letter atlas is baked on a background queue so a strike never stutters; if the shatter comes first it
    /// is finished with the shatter's own background work. After the shatter a new set is only taken if no letters
    /// are in play yet — minus the ones on the broken glass, which already fell with it; during the rewind it is
    /// kept for the next round.)
    func setGlyphs(_ samples: [GlyphSample]) {
        switch phase {
        case .intact:
            glyphRequests += 1
            let id = glyphRequests
            glyphRequest = (id, samples)
            let height = size.height, scale = backdropScale
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let atlas = GlyphAtlas.build(glyphs: samples, sceneHeight: height, backdropScale: scale)
                DispatchQueue.main.async {
                    guard let self, self.glyphRequest?.id == id, self.phase == .intact else { return }
                    self.glyphRequest = nil
                    self.glyphs.install(atlas)
                    self.glyphs.texture.map { self.primer.prime([$0]) }
                    // Text that arrives after hits: their patches drop at once.
                    self.glyphs.replayHits(at: self.time)
                    self.generation += 1
                }
            }
        case .breaking:
            lateGlyphs = samples
        case .shattering, .shattered:
            guard glyphs.isEmpty, let shattered else { return }
            glyphs.install(samples, backdropScale: backdropScale)
            glyphs.loosen(at: time, plan: shattered.plan, impacts: cracks.patterns.map(\.center), shardRelease: { _ in 0 },
                          lateArrival: true)
        case .reassembling:
            pendingGlyphs = samples
        }
    }

    /// Adds an animated fracture at `point`. Cumulative: more hits, more damage.
    /// Intensity is clamped to 0.2...2; non-finite input is ignored (point) or treated as 1 (intensity).
    /// `bursts: false` (the glass creaking) skips the flash of light this impact would give when the glass shatters.
    func crack(at point: CGPoint, intensity: CGFloat, bursts: Bool = true) {
        guard phase == .intact, point.x.isFinite, point.y.isFinite else { return }
        let intensity = intensity.isFinite ? min(max(intensity, 0.2), 2) : 1
        let pattern = CrackPattern.generate(center: point, intensity: intensity, bounds: CGRect(origin: .zero, size: size),
                                            seed: rng.next(), obstacles: cracks.obstacles)
        if !bursts { quietCracks.insert(cracks.patterns.count) }
        cracks.add(pattern, at: time)
        generation += 1
        // A real hit (not the glass creaking) knocks the letters around it loose right away.
        if bursts {
            glyphs.release(LetterPatch(center: FXVec(point), intensity: Double(intensity), seed: rng.next()), at: time)
        }
        onEvent?(.cracked(intensity: intensity))
    }

    /// Breaks the fractured glass: the shards and the text around the hits fall out of the screen, and the display
    /// behind the hole is dead.
    func shatter(completion: (() -> Void)? = nil) {
        switch phase {
        case .reassembling, .shattered:
            completion?()
            return
        case .breaking, .shattering:
            if let completion { shatterCompletions.append(completion) }
            return
        case .intact:
            break
        }
        if cracks.isEmpty {
            // Nothing cracked yet: break it in the middle, fully grown.
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let pattern = CrackPattern.generate(center: centre, intensity: 1, bounds: CGRect(origin: .zero, size: size),
                                                seed: rng.next())
            cracks.add(pattern, at: time - pattern.growthDuration)
            cracks.step(time: time)
            generation += 1
        }
        if let completion { shatterCompletions.append(completion) }
        shatterStart = time
        cracks.freeze(at: time)
        // The glass gives way: light bursts out of every impact, with a spray of chips.
        for (index, pattern) in cracks.patterns.enumerated() where !quietCracks.contains(index) {
            let disc = ShatterKit.damageDisc(for: pattern)
            particles.emitGlow(at: pattern.center, size: max(disc.radius, 60) * 1.6, life: 0.3, alpha: 0.6)
            particles.emitSparkle(at: pattern.center, size: 150, life: 0.3)
            particles.emitChips(at: pattern.center, count: 34, speed: 150...620, size: 3...9, lift: 1.6)
        }

        if isShatterReady, let prepared = preparedKit {
            preparedKit = nil
            breakGlass(kit: prepared.kit, textures: prepared.textures)
            // (After the state change, so a handler may rewind right away; not at all if nothing could break.)
            if phase == .shattering { onEvent?(.shatterBegan) }
            return
        }
        // Otherwise finish it (and any letters still baking) off the main thread; the glass gives way a moment later.
        let request = glyphRequest
        glyphRequest = nil
        let input = kitInput(cracks: cracks.snapshot)
        let height = size.height, scale = backdropScale
        let work = FXBackground { () -> BreakWork in
            guard let request else { return BreakWork(atlas: nil, kit: ShatterKit.make(input)) }
            let atlas = GlyphAtlas.build(glyphs: request.samples, sceneHeight: height, backdropScale: scale)
            var input = input
            if input.screenshotMode {
                input.erasedSpots = (atlas?.entries ?? []).map { ($0.rect, $0.background.cgColor) }
            }
            return BreakWork(atlas: atlas, kit: ShatterKit.make(input))
        }
        phase = .breaking
        pendingBreak = PendingBreak(at: time + Tuning.breakDelay, work: work, samples: request?.samples)
        onEvent?(.shatterBegan)
    }

    /// Another blow once the glass has broken (you, smashing the screen during the break): a fresh crack where there's
    /// glass left, knocking the letters around it off, with the display dying a little more under it; on the bare,
    /// dead panel where the glass is gone, a spray of chips and another dead pixel column. Ignored before the glass
    /// breaks (that's `crack`) and once it rewinds.
    func smash(at point: CGPoint, intensity: CGFloat) {
        guard phase == .shattering || phase == .shattered, let shattered, point.x.isFinite, point.y.isFinite else { return }
        let intensity = intensity.isFinite ? min(max(intensity, 0.2), 1.5) : 1
        let p = FXVec(point)
        let onGlass = shattered.plan.shard(containing: p) == nil
        if onGlass {
            let pattern = CrackPattern.generate(center: point, intensity: intensity, bounds: CGRect(origin: .zero, size: size),
                                                seed: rng.next(), obstacles: cracks.obstacles)
            cracks.add(pattern, at: time)
            glyphs.smash(LetterPatch(center: p, intensity: Double(intensity), seed: rng.next()), at: time)
        } else {
            particles.emitChips(at: p, count: 18, speed: 80...320, size: 2...5, lift: 1.2)
            particles.emitSparkle(at: p, size: 40, life: 0.22)
        }
        shattered.panel.addDamage(at: p, onGlass: onGlass, time: time)
        onEvent?(.cracked(intensity: intensity))
    }

    /// Rewinds everything back into place, then calls completion.
    func reassemble(completion: (() -> Void)? = nil) {
        if let completion { reassembleCompletions.append(completion) }
        guard phase != .reassembling else { return }
        if let pending = pendingBreak {
            // Called off before the glass gave way: keep its letters for the next round.
            pendingBreak = nil
            if let samples = pending.samples { pendingGlyphs = samples }
        }
        if let late = lateGlyphs {
            lateGlyphs = nil
            pendingGlyphs = late
        }
        phase = .reassembling
        runShatterCompletions()
        onEvent?(.reassembleBegan)
        particles.fadeAll(within: 0.2)
        if let shattered {
            shattered.shards.beginReturn(at: time)
            shattered.panel.beginClosing(at: time)
            glyphs.beginReturn(at: time)
        } else {
            cracks.beginRetract(at: time, duration: Tuning.crackRetract)
            // Letters the hits knocked loose fly back too.
            glyphs.beginReturn(at: time)
        }
        finishReassemblyIfDone()
    }

    func step(dt: TimeInterval) {
        let dt = min(max(dt.isFinite ? dt : 0, 0), 1.0 / 30)
        time += dt
        primer.step()
        if phase == .breaking, let pending = pendingBreak {
            if time >= pending.at {
                completeBreak()
            } else if !pending.collected, pending.work.isDone {
                pendingBreak?.textures = collectBreakWork(pending)
                pendingBreak?.collected = true
            }
        }
        cracks.step(time: time)
        prepareKitIfNeeded()
        glyphs.step(time: time, dt: dt)
        if let shattered {
            shattered.shards.step(time: time)
            shattered.panel.step(time: time)
        }
        particles.step(dt: dt)

        switch phase {
        case .shattering:
            let settled = (shattered?.shards.isGone ?? true) && glyphs.isSettled
            if settled || time - shatterStart >= Tuning.shatterSettleLimit {
                phase = .shattered
                runShatterCompletions()
            }
        case .reassembling:
            if var current = shattered, !current.cracksRestored, current.shards.isHome, glyphs.isHome {
                // The pieces are back: hand the crack lines from the baked shard textures back to the vector layer
                // (identical look), then let them retract into the impacts.
                current.cracksRestored = true
                // The dead panel goes too: it would otherwise peek through the hairline gaps between the pieces as a
                // ghost outline of the hole while the cracks retract.
                current.panel.hide()
                shattered = current
                current.shards.uniforms.setCrackAlpha(0)
                cracks.setHole(nil, at: time)
                cracks.beginRetract(at: time, duration: Tuning.crackRetract)
            }
            finishReassemblyIfDone()
        case .intact, .breaking, .shattered:
            break
        }
    }

    // MARK: - Breaking

    /// Collects the background work of a deferred shatter (waiting for it only if it is running late) and breaks.
    private func completeBreak() {
        guard let pending = pendingBreak else { return }
        pendingBreak = nil
        let textures = pending.collected ? pending.textures : collectBreakWork(pending)
        breakGlass(kit: pending.work.wait().kit, textures: textures)
        if let late = lateGlyphs {
            lateGlyphs = nil
            setGlyphs(late)
        }
    }

    /// Installs the letters a deferred shatter baked and makes its kit's textures, priming both.
    private func collectBreakWork(_ pending: PendingBreak) -> ShatterTextures? {
        let work = pending.work.wait()
        if pending.samples != nil {
            glyphs.install(work.atlas)
            glyphs.texture.map { primer.prime([$0]) }
            glyphs.replayHits(at: time)
            generation += 1
        }
        let textures = work.kit.map(ShatterTextures.init)
        textures.map { primer.prime($0.all) }
        return textures
    }

    /// Builds the falling shards, the dead panel and the loosening wave. A nil kit (degenerate damage, nothing can
    /// break out) leaves the glass cracked.
    private func breakGlass(kit: ShatterKit?, textures: ShatterTextures?) {
        guard let kit else {
            phase = .intact
            cracks.thaw()
            runShatterCompletions()
            return
        }
        let impacts = cracks.patterns.map(\.center)
        let plan = kit.plan
        phase = .shattering

        let textures = textures ?? ShatterTextures(kit: kit)
        let shards = ShardField(kit: kit, textures: textures, impacts: impacts, backdrop: backdrop, sceneSize: size, time: time,
                                rng: &rng)
        let panel = DeadPanel(kit: kit, textures: textures, sceneSize: size, time: time, release: { shards.release(of: $0) })
        for (node, z) in [(panel.node, Z.panel), (panel.rim, Z.rim), (shards.node, Z.shards)] {
            node.zPosition = z
            addChild(node)
        }
        shattered = Shattered(plan: plan, shards: shards, panel: panel)

        glyphs.loosen(at: time, plan: plan, impacts: impacts, shardRelease: { shards.release(of: $0) })
        cracks.setHole({ plan.shard(containing: $0) != nil }, at: time)
        for edge in plan.rim.shuffled(using: &rng).prefix(10) {
            particles.emitSparkle(at: edge.a, size: rng.range(18...34), life: rng.range(0.25...0.45))
        }
        panel.step(time: time)
        shards.step(time: time)
    }

    // MARK: - Private

    private func finishReassemblyIfDone() {
        guard phase == .reassembling else { return }
        if let shattered {
            guard shattered.cracksRestored, cracks.isRetracted else { return }
        } else {
            guard cracks.isEmpty || cracks.isRetracted, glyphs.isHome else { return }
        }
        // Everything is back where it started: drop it all, leaving the pristine backdrop.
        if let shattered {
            for node in [shattered.panel.node, shattered.panel.rim, shattered.shards.node] { node.removeFromParent() }
        }
        shattered = nil
        cracks.removeAll()
        quietCracks.removeAll()
        glyphs.reset()
        generation += 1
        preparedKit = nil
        phase = .intact
        if let pendingGlyphs {
            self.pendingGlyphs = nil
            setGlyphs(pendingGlyphs)
        }
        onEvent?(.reassembled)
        let completions = reassembleCompletions
        reassembleCompletions = []
        completions.forEach { $0() }
    }

    // MARK: - Background preparation

    private func kitInput(cracks: [(pattern: CrackPattern, time: Double)]) -> ShatterKit.Input {
        ShatterKit.Input(cracks: cracks,
                         erasedSpots: backdrop == nil ? [] : glyphs.erasedSpots.map { ($0.0, $0.1.cgColor) },
                         sceneSize: size, scale: backdropScale ?? 2, screenshotMode: backdrop != nil, seed: rng.next())
    }

    /// Works out the shatter on a background queue as soon as the cracks change (baking them fully grown), one job
    /// at a time, so the `shatter()` call itself stays cheap. A result that no longer matches is dropped. Delivered
    /// through the main queue, which the app's run loop drains; headless renders simply take the deferred path.
    private func prepareKitIfNeeded() {
        guard phase == .intact, !defersShatterPreparation, !cracks.isEmpty, preparing == nil,
              preparedKit?.generation != generation else { return }
        let input = kitInput(cracks: cracks.settledSnapshot)
        let wanted = generation
        preparing = wanted
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let kit = ShatterKit.make(input)
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = nil
                guard self.generation == wanted else { return }
                // Textures now, uploaded on this quiet frame rather than the shatter's.
                let textures = kit.map(ShatterTextures.init)
                textures.map { self.primer.prime($0.all) }
                self.preparedKit = (wanted, kit, textures)
            }
        }
    }

    private func runShatterCompletions() {
        let completions = shatterCompletions
        shatterCompletions = []
        completions.forEach { $0() }
    }

    private func glyphLanded() {
        guard time - lastLanded >= Tuning.landedEventInterval else { return }
        lastLanded = time
        onEvent?(.glyphLanded)
    }
}

