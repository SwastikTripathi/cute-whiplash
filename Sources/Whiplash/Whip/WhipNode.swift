import SpriteKit

/// A physically simulated whip that hangs from the notch. Add it to a scene at position .zero:
/// every point it takes or reports is in SCENE coordinates. Call `step(dt:)` once per frame.
///
/// Behaviour in short:
/// * Created with `length > 0` it unfurls out of the notch at once; with 0 it stays reeled in until a
///   strike, manual control or a new `length` brings it out.
/// * `strike`s queue up and chain from mid-motion. Each cracks exactly once, within a few points of its
///   target, ~0.55 s after it starts (plus ~0.3 s to drop out of the notch first if it was reeled in); its
///   completion runs ~0.25 s after the crack (≈0.8 s per strike). The crack spends the throw: the tip stops
///   on the target and the thong drops from there.
/// * Once in a scene, the thong stays inside the scene's bounds (the whip lives behind the glass).
/// * The handle is drawn in Lash's paw, which lets go while the mouse holds the whip (manual control).
/// * `retract` and `beginManualControl` cut scripted strikes short; their completions still run once.
/// * Callbacks and completions only ever run from inside `step(dt:)`.
final class WhipNode: SKNode {
    /// Where the handle is held (the notch), scene coords.
    var anchor: CGPoint {
        get { rig.anchor.whipPoint }
        set { rig.anchor = newValue.whipVec }
    }
    /// Fired the instant the tip breaks the sound barrier: (tip position, intensity 0...1).
    var onCrack: ((CGPoint, CGFloat) -> Void)?
    /// Fired as a swing starts (for the whoosh sound).
    var onWhoosh: (() -> Void)?
    /// Rope length in points. Cartoon physics: may be changed at any time (the whip grows to reach far
    /// targets). Setting it animates the change; strikes pick their own length.
    var length: CGFloat {
        get { CGFloat(rig.length) }
        set { rig.length = Double(newValue) }
    }
    /// True while a scripted strike / retract is running.
    var isBusy: Bool { rig.isBusy }
    /// Lash's paw holds the handle at rest. Off for the whip you pull out of the island yourself: that one is yours.
    var hasPaw = true {
        didSet { if !hasPaw { fistAlpha = 0 } }
    }

    /// The simulation behind the drawing (exposed for tests and demos).
    let rig: WhipRig
    private let skin = WhipSkin()
    private let burstLayer = SKNode()
    private var bursts: [WhipCrackBurst] = []
    private var random = WhipRandom(seed: 0x5EED_CAFE)
    private var lastWord: String?
    private var time = 0.0
    /// Lash's paw on the handle: hidden while the user holds the whip (the cursor is the hand), back once the hand
    /// has returned to the island.
    private var fistShown = true
    private var fistAlpha = 1.0
    /// How close to its rest pose the hand must be for Lash to take the whip back, points.
    private static let fistReturnDistance = 12.0
    /// Fist fade time, seconds.
    private static let fistFade = 0.15

    init(anchor: CGPoint, length: CGFloat) {
        rig = WhipRig(anchor: anchor.whipVec, length: Double(length))
        super.init()
        addChild(skin)
        burstLayer.zPosition = 100
        addChild(burstLayer)
        rig.onEvent = { [weak self] event in self?.handle(event) }
        WhipCrackBurst.prepareTextures()
        skin.update(rope: rig.rope, presence: rig.presence, time: 0, tipPath: [])
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Scripted strike: unfurl from the anchor if retracted, wind up, and flick so the crack lands near `target`.
    func strike(at target: CGPoint, completion: (() -> Void)? = nil) {
        rig.strike(at: target.whipVec, completion: completion)
    }

    /// Manual mode: the handle follows the mouse; fast flicks crack wherever the tip is.
    func beginManualControl(at point: CGPoint) { rig.beginManualControl(at: point.whipVec) }
    func moveHandle(to point: CGPoint) { rig.moveHandle(to: point.whipVec) }
    func endManualControl() { rig.endManualControl() }

    /// Pull the whip back up into the notch.
    func retract(completion: (() -> Void)? = nil) { rig.retract(completion: completion) }

    /// A comic burst ("THWACK!") at `point` without the whip cracking: a smash of the screen during the break.
    func burst(at point: CGPoint, intensity: CGFloat) { spawnBurst(at: point, intensity: intensity) }

    func step(dt: TimeInterval) {
        let dt = WhipMath.clamp(dt.isFinite ? dt : 0, 0, 1.0 / 30)
        time += dt
        rig.bounds = scene.map { CGRect(origin: .zero, size: $0.size) }
        let ticks = rig.tickCount
        rig.step(dt: dt)
        if rig.isManual || !hasPaw {
            fistShown = false
        } else if rig.handDistanceFromRest < Self.fistReturnDistance {
            fistShown = true
        }
        fistAlpha = WhipMath.clamp(fistAlpha + (fistShown ? 1 : -1) * dt / Self.fistFade, 0, 1)
        // Redraw only when the rope moved (a display faster than the 120 Hz simulation gets frames without
        // a tick; redrawing those would make the motion smear flicker) and not while reeled in.
        if rig.tickCount != ticks, !(rig.isRetracted && skin.isHidden) {
            skin.update(rope: rig.rope, presence: rig.presence, time: time, tipPath: rig.frameTipPath, fist: fistAlpha)
        }
        bursts.removeAll { burst in
            guard burst.advance(dt: dt) else {
                burst.removeFromParent()
                return true
            }
            return false
        }
    }

    private func handle(_ event: WhipRig.Event) {
        switch event {
        case .whoosh:
            onWhoosh?()
        case .crack(let point, let intensity):
            spawnBurst(at: point.whipPoint, intensity: CGFloat(intensity))
            onCrack?(point.whipPoint, CGFloat(intensity))
        }
    }

    private func spawnBurst(at point: CGPoint, intensity: CGFloat) {
        var word = WhipCrackBurst.words.randomElement(using: &random) ?? "CRACK!"
        if word == lastWord, let other = WhipCrackBurst.words.filter({ $0 != word }).randomElement(using: &random) {
            word = other
        }
        lastWord = word
        let burst = WhipCrackBurst(at: point, intensity: intensity, word: word,
                                   wordOffset: wordOffset(for: point), random: &random)
        burstLayer.addChild(burst)
        bursts.append(burst)
    }

    /// Put the word just above the crack, nudged to stay on screen.
    private func wordOffset(for point: CGPoint) -> CGPoint {
        let bounds = scene.map { CGRect(origin: .zero, size: $0.size) } ?? .infinite
        var offset = CGPoint(x: 0, y: 72)
        if bounds.isInfinite { return offset }
        let halfWidth: CGFloat = 130, halfHeight: CGFloat = 50
        let x = point.x + offset.x, y = point.y + offset.y
        offset.x += max(0, bounds.minX + halfWidth - x) - max(0, x + halfWidth - bounds.maxX)
        if y + halfHeight > bounds.maxY - 40 { offset.y = -72 }
        offset.y += max(0, bounds.minY + halfHeight - (point.y + offset.y))
        return offset
    }
}
