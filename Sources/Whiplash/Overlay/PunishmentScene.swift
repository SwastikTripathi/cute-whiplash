import SpriteKit

/// The show's big moments, reported to whoever staged it (the island plays along).
enum PunishmentBeat: Equatable {
    /// The glass just gave way.
    case shatter
    /// Everything starts rewinding into place.
    case reassemble
    /// The break after the shatter: this many seconds (rounded up) until the screen comes back. Reported each time
    /// it ticks down; Lash's island shows it.
    case breakLeft(seconds: Int)
}

/// One punishment, staged: the whip, the breaking glass, screen shake and sound.
///
/// Scene coordinates == the punished screen's points (origin bottom-left, y-up). PunishmentSequencer decides
/// *when* things happen; this scene decides *how*. Everything is driven from `update(_:)` — no `didMove(to:)`,
/// no view, no dispatch delays — so it plays identically in the overlay's SKView, under OffscreenRenderer and
/// in unit tests that call `update(_:)` directly.
///
/// Node tree: the camera carries the black bezel (backdrop mode only) so that, when the camera shakes, the
/// screenshot moves inside a fixed black frame like a physical screen; `world` holds the DestructionLayer at the
/// origin. The WhipNode lives in `whipLayer` (z 10), which also rides on the camera: the whip hangs from Lash's
/// island — a separate window that never shakes — so it must stay fixed to the screen while the glass shakes under
/// it. Whip coordinates are therefore screen coordinates; a crack is converted to the world point under the tip.
final class PunishmentScene: SKScene {
    struct Stats {
        /// Cracks reported by the whip itself (fallback cracks are counted by the sequencer).
        var whipCracks = 0
        /// Blows you landed on the broken screen during the break.
        var smashes = 0
        /// Harvested glyphs handed to the DestructionLayer.
        var glyphsDelivered = 0
    }

    private enum Tuning {
        static let maxFrameStep: TimeInterval = 1.0 / 30
        /// All the text on screen, not just the first lines: every hit drops the letters around it, wherever it
        /// lands. (A dense full-screen terminal has ~5,000; the cap only guards against absurd screens.)
        static let ocrGlyphs = 15_000
        static let syntheticGlyphs = 6_000
        static let minimumWhipLength: CGFloat = 260
        /// Rope length relative to the distance it has to reach.
        static let reachSlack: CGFloat = 1.08
        /// Manual whip length as a fraction of the screen height.
        static let manualLengthFraction: CGFloat = 0.34
        /// Manual flicks closer together than this count as one crack.
        static let manualCrackCooldown: TimeInterval = 0.1
        /// At most one landing tinkle per this many seconds.
        static let tinkleSpacing: TimeInterval = 0.06
        /// How far sounds pan at the screen edges.
        static let panWidth: CGFloat = 0.8
        /// Crack strength of strikes whose crack the whip never reported.
        static let fallbackStrength: CGFloat = 0.85
        /// Lash cackles this long after the glass gives way.
        static let giggleDelay: TimeInterval = 0.25
        /// Smashing the screen during the break: blows closer together than this count as one, and a break takes at
        /// most this many (each is a new crack web to draw).
        static let smashCooldown: TimeInterval = 0.12
        static let maxSmashes = 30
    }

    private enum HarvestJob {
        case ocr(ScreenSnapshot, focus: CGRect?)
        case synthetic(region: CGRect)
    }

    let sequencer: PunishmentSequencer
    /// Where the whip is held (just inside the island's bottom edge; see `NotchController.whipAnchor(on:)`), scene
    /// coordinates.
    let whipAnchor: CGPoint
    /// What the whip aims at, scene coordinates (nil = middle of the screen).
    let target: CGRect?

    /// Called once, from `update(_:)`, when the sequence has faded out completely.
    var onFinished: (() -> Void)?
    /// Called from `update(_:)` whenever `capturesInput` flips, so the overlay can take or release mouse and keys.
    var onCapturesInputChanged: ((Bool) -> Void)?
    /// Called from `update(_:)` at the show's big moments.
    var onBeat: ((PunishmentBeat) -> Void)?
    /// Manual mode: where the pointer is now (scene coordinates; nil when it's off this screen), read every frame — the
    /// whip stays in your hand even while another window has the mouse, like the island you pulled it out of.
    var pointerSource: (() -> CGPoint?)?
    var sound: SoundPlaying = SoundBoard.shared
    private(set) var stats = Stats()
    private(set) var isFinished = false

    private let intensity: CGFloat
    private let isManual: Bool
    /// A screenshot stands in for the live screen (vs transparent glass over it).
    private let backdropMode: Bool
    private let world = SKNode()
    /// Holds the whip, fixed to the screen (a child of the camera; see the type's doc).
    private let whipLayer = SKNode()
    private let cameraRig = SKCameraNode()
    private let bezel: SKSpriteNode?
    private let whip: WhipNode
    private let destruction: DestructionLayer
    private var shake: CameraShake
    private var rng: OverlayRandom

    private var inputs: [PunishmentSequencer.Input] = []
    private var lastUpdateTime: TimeInterval?
    private var clock: TimeInterval = 0
    private var capturingInput: Bool?
    private var pendingGiggle: TimeInterval?
    private var crackPoints: [CGPoint] = []
    private var lastTinkle: TimeInterval = -.infinity
    private var lastManualCrack: TimeInterval = -.infinity
    private var isHoldingWhip = false
    private var lastSmash: TimeInterval = -.infinity
    private var lastBreakLeft: Int?

    private var harvestJob: HarvestJob?
    private var harvestTask: Task<Void, Never>?
    private let mailbox = GlyphMailbox()
    private var glyphsSettled: Bool

    /// - Parameters:
    ///   - screenFrame: the punished screen, Cocoa global; the scene takes its size.
    ///   - anchor: where the whip is held, Cocoa global.
    ///   - seed: drives aim, creaks and shake, so demos and tests are reproducible.
    init(plan: PunishmentPlan, screenFrame: CGRect, anchor: CGPoint, seed: UInt64 = .random(in: 0 ... .max)) {
        let size = screenFrame.size
        var rng = OverlayRandom(seed: seed)
        let target = plan.targetRect.map { CoordinateSpace.scene(fromCocoa: $0, screenFrame: screenFrame) }
        let whipAnchor = CoordinateSpace.scene(fromCocoa: anchor, screenFrame: screenFrame)
        let strikes = min(6, max(1, plan.strikes))
        // Aim at the text (screenshot mode), so every hit has letters around it to knock loose.
        let ink = plan.isManual ? nil : plan.backdrop.flatMap { InkMap(image: $0.image, sceneSize: size) }
        let targets = plan.isManual ? [] : StrikeTargeting.targets(count: strikes, target: target, sceneSize: size, ink: ink,
                                                                    using: &rng)

        sequencer = PunishmentSequencer(mode: plan.isManual ? .manual : .auto, targets: targets, shatters: plan.shatter,
                                        holdSeconds: plan.holdSeconds, glyphsReady: !plan.glyphs.isEmpty)
        self.whipAnchor = whipAnchor
        self.target = target
        intensity = min(2, max(0.5, plan.intensity))
        isManual = plan.isManual
        backdropMode = plan.backdrop != nil

        let reach = targets.first.map { hypot($0.x - whipAnchor.x, $0.y - whipAnchor.y) * Tuning.reachSlack }
            ?? size.height * Tuning.manualLengthFraction
        whip = WhipNode(anchor: whipAnchor, length: max(Tuning.minimumWhipLength, reach))
        whip.hasPaw = !plan.isManual
        destruction = DestructionLayer(size: size, backdrop: plan.backdrop.map { SKTexture(cgImage: $0.image) },
                                       glyphs: plan.glyphs)
        bezel = plan.backdrop == nil ? nil : SKSpriteNode(color: .black, size: CGSize(width: size.width * 1.5, height: size.height * 1.5))
        shake = CameraShake(profile: plan.backdrop == nil ? .glass(intensity: intensity) : .backdrop(intensity: intensity),
                            seed: rng.next())
        self.rng = rng

        glyphsSettled = !plan.glyphs.isEmpty
        if plan.glyphs.isEmpty {
            // Only the part of the target that is on this screen has text worth peeling off.
            let visible = target.map { $0.intersection(CGRect(origin: .zero, size: size)) }
            let focus = visible.flatMap { $0.isNull || $0.isEmpty ? nil : $0 }
            if let backdrop = plan.backdrop {
                harvestJob = .ocr(backdrop, focus: focus)
            } else {
                harvestJob = .synthetic(region: focus ?? StrikeTargeting.fallbackRegion(in: size))
            }
        }

        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .fill
        // Every crack would otherwise re-bake the whole shatter in the background (~100 MB a time at 2x); bake once
        // the damage is final, when the glass starts to creak.
        destruction.defersShatterPreparation = true
        buildNodes()
        wireCallbacks()
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildNodes() {
        cameraRig.position = CGPoint(x: size.width / 2, y: size.height / 2)
        addChild(cameraRig)
        camera = cameraRig
        if let bezel {
            bezel.zPosition = -1000
            cameraRig.addChild(bezel)
        }
        world.position = .zero
        addChild(world)
        destruction.position = .zero
        destruction.zPosition = 0
        world.addChild(destruction)
        // The camera sits at the screen's centre: this puts the layer's origin on the screen's bottom-left corner.
        whipLayer.position = CGPoint(x: -size.width / 2, y: -size.height / 2)
        whipLayer.zPosition = 10
        cameraRig.addChild(whipLayer)
        whip.position = .zero
        whipLayer.addChild(whip)
    }

    private func wireCallbacks() {
        whip.onCrack = { [weak self] point, strength in self?.whipCracked(at: point, strength: strength) }
        whip.onWhoosh = { [weak self] in self?.whooshed() }
        destruction.onEvent = { [weak self] event in self?.destructionDidReport(event) }
    }

    // MARK: - External controls

    /// Click / Esc / right-click. Ignored unless the sequencer accepts it right now.
    func skip() {
        inputs.append(.skip)
    }

    /// A click or Esc in auto mode: during the break it skips the rest of the hold (a normal rewind); any
    /// earlier it leaves at once (the quick exit), so the screen is never held hostage. Returns whether it took
    /// the quick exit.
    @discardableResult
    func interrupt() -> Bool {
        let quick = !sequencer.acceptsSkip
        inputs.append(quick ? .dismiss : .skip)
        return quick
    }

    /// Whether the overlay should take the mouse and the keyboard right now. Manual mode: until it winds down.
    /// Auto mode over a screenshot: likewise, from the very first frame — the frozen picture hides the live screen,
    /// so clicks and keys must not reach it blind. Auto glass mode: only during the break (the live screen is visible
    /// around the damage, so clicks may go through to it).
    var capturesInput: Bool {
        if isManual || backdropMode { return !sequencer.isWindingDown }
        return sequencer.acceptsSkip
    }

    /// Quick exit: reassemble fast and fade (≤ 0.4 s).
    func dismiss() {
        inputs.append(.dismiss)
    }

    /// A click on the broken screen during the break (screen coordinates): you get to smash it some more — a crack
    /// where there's glass left, dead pixels where there isn't, a THWACK either way. Doesn't end the break (Esc does).
    func smash(at point: CGPoint) {
        guard !isManual, sequencer.phase == .holding, clock - lastSmash >= Tuning.smashCooldown,
              stats.smashes < Tuning.maxSmashes else { return }
        lastSmash = clock
        stats.smashes += 1
        let k = min(1.3, 0.85 * intensity)
        let pan = pan(for: point.x)
        sound.play(.crack, intensity: Float(k), pan: pan)
        sound.play(.glassCrack, intensity: Float(k * 0.8), pan: pan)
        shake.add(trauma: 0.32)
        shake.addPunch(0.55)
        whip.burst(at: point, intensity: k)
        // Like the whip's tip, the click is fixed to the screen while the glass shakes: hit the world point under it.
        destruction.smash(at: convert(point, from: whipLayer), intensity: k)
    }

    /// Manual mode: the pointer moved to `point` (scene coordinates). The first call puts the whip in hand.
    func pointerMoved(to point: CGPoint) {
        guard isManual, !sequencer.isWindingDown else { return }
        if isHoldingWhip {
            whip.moveHandle(to: point)
        } else {
            isHoldingWhip = true
            whip.beginManualControl(at: point)
        }
    }

    /// Blocks, spinning the current run loop, until the background text harvest has delivered or `timeout`
    /// passes. Only for headless rendering, where simulated time races ahead of OCR: it lets demos and the
    /// self-test show the timeline a real run has. Returns whether the harvest settled.
    @discardableResult
    func waitForGlyphs(timeout: TimeInterval) -> Bool {
        startHarvestIfNeeded()
        let deadline = Date().addingTimeInterval(timeout)
        while !glyphsSettled, !mailbox.isFilled, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return glyphsSettled || mailbox.isFilled
    }

    /// Headless support: runs the main run loop until the letters handed to the glass are baked and installed. The app
    /// bakes them in ~50 ms, well before the first hit; a debug-build demo needs seconds.
    func waitForLetters(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while destruction.isPreparingLetters, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Stops background work and releases every node and texture. Call once the overlay is gone.
    func tearDown() {
        harvestTask?.cancel()
        harvestTask = nil
        harvestJob = nil
        whip.onCrack = nil
        whip.onWhoosh = nil
        destruction.onEvent = nil
        onFinished = nil
        onCapturesInputChanged = nil
        onBeat = nil
        inputs.removeAll()
        removeAllActions()
        cameraRig.removeAllChildren()
        world.removeAllChildren()
        removeAllChildren()
        camera = nil
    }

    // MARK: - Frame loop

    override func update(_ currentTime: TimeInterval) {
        guard !isFinished else { return }
        let dt = lastUpdateTime.map { min(Tuning.maxFrameStep, max(0, currentTime - $0)) } ?? 0
        lastUpdateTime = currentTime
        clock += dt

        startHarvestIfNeeded()
        deliverHarvestedGlyphs()

        if isManual, let point = pointerSource?() { pointerMoved(to: point) }
        let substeps = max(1, Int(sequencer.timeScale.rounded()))
        for _ in 0..<substeps { whip.step(dt: dt) }
        pump()
        perform(sequencer.advance(by: dt))
        pump()
        for _ in 0..<substeps { destruction.step(dt: dt) }
        pump()
        // The break counts down (in Lash's island), so it's clear when the screen comes back.
        let breakLeft = sequencer.holdRemaining.map { Int($0.rounded(.up)) }
        if breakLeft != lastBreakLeft {
            lastBreakLeft = breakLeft
            if let breakLeft { onBeat?(.breakLeft(seconds: breakLeft)) }
        }

        if let giggle = pendingGiggle, clock >= giggle {
            pendingGiggle = nil
            if !sequencer.isWindingDown { sound.play(.giggle, intensity: 0.9, pan: 0) }
        }

        let pose = shake.step(dt: dt)
        cameraRig.position = CGPoint(x: size.width / 2 + pose.offset.dx, y: size.height / 2 + pose.offset.dy)
        cameraRig.zRotation = pose.rotation
        cameraRig.setScale(pose.scale)
        world.alpha = sequencer.presentationAlpha
        whipLayer.alpha = sequencer.presentationAlpha
        bezel?.alpha = sequencer.presentationAlpha

        let captures = capturesInput
        if capturingInput != captures {
            // (Not reported for the first frame: whoever presents the scene reads `capturesInput` up front.)
            if capturingInput != nil { onCapturesInputChanged?(captures) }
            capturingInput = captures
        }
        if sequencer.isFinished {
            isFinished = true
            onFinished?()
        }
    }

    /// Feeds queued inputs to the sequencer and performs its answers. Completions may queue more inputs
    /// (synchronously, even); the budget keeps a misbehaving collaborator from spinning this forever.
    private func pump() {
        var budget = 64
        while !inputs.isEmpty, budget > 0 {
            budget -= 1
            perform(sequencer.handle(inputs.removeFirst()))
        }
    }

    private func perform(_ commands: [PunishmentSequencer.Command]) {
        for command in commands {
            switch command {
            case let .strike(index, point):
                // (The whip is fixed to the screen, so screen = scene coordinates for aiming; it picks its own length.)
                whip.strike(at: point) { [weak self] in self?.inputs.append(.strikeFinished(index: index)) }
            case let .fallbackCrack(index, point):
                crack(at: point, strength: Tuning.fallbackStrength, strike: index)
            case .retract:
                if isHoldingWhip {
                    isHoldingWhip = false
                    whip.endManualControl()
                }
                whip.retract()
            case .creak:
                // The damage is final: bake the shatter now, in the background, while the glass groans.
                destruction.defersShatterPreparation = false
                creak()
            case .shatter:
                shatter()
            case .reassemble(let quick):
                destruction.reassemble { [weak self] in self?.inputs.append(.reassembled) }
                if !quick { sound.play(.reassemble, intensity: 0.9, pan: 0) }
                pendingGiggle = nil
                onBeat?(.reassemble)
            }
        }
    }

    // MARK: - Effects

    private func whipCracked(at point: CGPoint, strength: CGFloat) {
        if isManual {
            guard clock - lastManualCrack >= Tuning.manualCrackCooldown else { return }
            lastManualCrack = clock
        }
        stats.whipCracks += 1
        // The whip is fixed to the screen while the glass shakes: break the glass at the world point under the tip.
        crack(at: convert(point, from: whipLayer), strength: strength, strike: sequencer.currentStrike)
        inputs.append(.cracked)
    }

    /// How hard a crack hits the glass (the DestructionLayer's intensity) for a whip `strength` of 0...1.
    /// Scripted strikes always hit decently (the whip reports ~0.55–1) and each one of a volley harder than the last:
    /// the opening crack must read at once, and every web must be big enough to join the others into one hole.
    /// The user's own flicks (manual mode, no `strike`) crack as hard as they flick.
    private func crackIntensity(strength: CGFloat, strike: Int?) -> CGFloat {
        guard let strike else { return min(2, max(0.15, strength * intensity)) }
        let count = sequencer.targets.count
        let ramp = count > 1 ? 0.95 + 0.35 * CGFloat(strike) / CGFloat(count - 1) : 1.1
        return min(2, max(0.15, (0.55 + 0.6 * strength) * intensity * ramp))
    }

    /// The whip's crack always sounds and shakes; the glass only breaks while there is glass left.
    private func crack(at point: CGPoint, strength: CGFloat, strike: Int?) {
        let k = crackIntensity(strength: strength, strike: strike)
        let pan = pan(for: point.x)
        sound.play(.crack, intensity: Float(min(k, 1.3)), pan: pan)
        shake.add(trauma: 0.3 + 0.28 * min(k, 1.5))
        shake.addPunch(min(1, 0.45 + 0.45 * k))
        guard sequencer.acceptsDamage else { return }
        destruction.crack(at: point, intensity: k)
        crackPoints.append(point)
        sound.play(.glassCrack, intensity: Float(min(k, 1.3) * 0.8), pan: pan)
    }

    /// The glass groans: a small fracture creeps out next to existing damage.
    private func creak() {
        shake.add(trauma: 0.14)
        guard let base = crackPoints.randomElement(using: &rng) else {
            sound.play(.glassCrack, intensity: 0.3, pan: 0)
            return
        }
        let angle = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
        let reach = CGFloat.random(in: 24...64, using: &rng)
        let point = CGPoint(x: base.x + cos(angle) * reach, y: base.y + sin(angle) * reach)
        destruction.crack(at: point, intensity: min(0.4, 0.2 * intensity), bursts: false)
        sound.play(.glassCrack, intensity: 0.3, pan: pan(for: point.x))
    }

    private func shatter() {
        destruction.shatter { [weak self] in self?.inputs.append(.shatterFinished) }
        let centreX = crackPoints.isEmpty ? (target?.midX ?? size.width / 2)
            : crackPoints.map(\.x).reduce(0, +) / CGFloat(crackPoints.count)
        sound.play(.shatter, intensity: Float(min(1.3, 0.75 + 0.25 * intensity)), pan: pan(for: centreX))
        sound.play(.buzz, intensity: 0.8, pan: pan(for: centreX))
        shake.add(trauma: 0.85)
        shake.addPunch(1)
        pendingGiggle = clock + Tuning.giggleDelay
        onBeat?(.shatter)
    }

    private func whooshed() {
        let aim = sequencer.currentStrike.map { sequencer.targets[$0].x } ?? whipAnchor.x
        sound.play(.whoosh, intensity: 0.7, pan: pan(for: aim))
    }

    private func destructionDidReport(_ event: DestructionEvent) {
        guard case .glyphLanded = event, clock - lastTinkle >= Tuning.tinkleSpacing else { return }
        lastTinkle = clock
        sound.play(.tinkle, intensity: Float.random(in: 0.25...0.6, using: &rng),
                   pan: Float.random(in: -0.7...0.7, using: &rng))
    }

    private func pan(for x: CGFloat) -> Float {
        guard size.width > 0 else { return 0 }
        return Float(min(1, max(-1, x / size.width * 2 - 1)) * Tuning.panWidth)
    }

    // MARK: - Text harvest

    private func startHarvestIfNeeded() {
        guard let job = harvestJob else { return }
        harvestJob = nil
        let mailbox = self.mailbox
        switch job {
        case let .ocr(snapshot, focus):
            harvestTask = Task.detached(priority: .userInitiated) {
                mailbox.put(await TextHarvester.harvest(from: snapshot, focus: focus, maxGlyphs: Tuning.ocrGlyphs))
            }
        case let .synthetic(region):
            harvestTask = Task.detached(priority: .userInitiated) {
                mailbox.put(TextHarvester.synthetic(in: region, maxGlyphs: Tuning.syntheticGlyphs))
            }
        }
    }

    /// Hands finished harvest results to the DestructionLayer — on the main thread, inside the frame loop.
    private func deliverHarvestedGlyphs() {
        guard !glyphsSettled, let glyphs = mailbox.take() else { return }
        glyphsSettled = true
        // Too late (the hold has begun): the show went on without them.
        guard sequencer.acceptsGlyphs else { return }
        if !glyphs.isEmpty {
            destruction.setGlyphs(glyphs)
            stats.glyphsDelivered = glyphs.count
        }
        inputs.append(.glyphsReady)
    }
}

/// Passes harvested glyphs from a background task to the scene's frame loop. A mailbox rather than
/// `DispatchQueue.main.async`, because a headless render loop never yields to the main queue.
final class GlyphMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var glyphs: [GlyphSample]?

    var isFilled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return glyphs != nil
    }

    func put(_ value: [GlyphSample]) {
        lock.lock()
        glyphs = value
        lock.unlock()
    }

    func take() -> [GlyphSample]? {
        lock.lock()
        defer {
            glyphs = nil
            lock.unlock()
        }
        return glyphs
    }
}
