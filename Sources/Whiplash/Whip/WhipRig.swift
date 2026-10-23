import CoreGraphics
import simd

/// The whip's brain: drives the hand, the rope length and the throw field of a `WhipRope`, aims scripted
/// strikes and decides when the whip cracks. Pure Swift (no SpriteKit), so it is unit-testable; `WhipNode`
/// wraps it and draws it. All points are scene coordinates.
///
/// Time advances in fixed 1/120 s ticks whatever the frame rate, so a strike rehearsed by
/// `WhipStrikePredictor` plays out exactly as predicted.
///
/// Commands (`strike`, `retract`) queue up and run in order; `retract` and manual control cut the queue
/// short. Every completion runs exactly once, always from inside `step(dt:)`.
final class WhipRig {
    enum Event: Equatable {
        /// A swing started (whoosh sound).
        case whoosh
        /// The tip broke the sound barrier at `point`; `intensity` is 0...1.
        case crack(point: WhipVec, intensity: Double)
    }

    static let tick = 1.0 / 120

    var tuning = WhipTuning()
    var anchor: WhipVec {
        didSet { if isRetracted { rope.teleport(hand: stowedPose) } }
    }
    /// The visible screen, scene coordinates, when known: the thong can't leave it, and strikes wind long
    /// ropes up steeper so they don't pile up against its sides.
    var bounds: CGRect? {
        didSet {
            rope.walls = bounds.flatMap { b in
                b.isNull || b.isInfinite || b.isEmpty ? nil : (Double(b.minX), Double(b.minY), Double(b.maxX), Double(b.maxY))
            }
        }
    }
    var onEvent: ((Event) -> Void)?

    private(set) var rope: WhipRope
    /// Simulated seconds since creation.
    private(set) var time = 0.0
    /// The tip's path through every tick of the last `step(dt:)` (for motion streaks).
    private(set) var frameTipPath: [WhipRope.TipSample] = []
    /// Fixed ticks run so far; unchanged by a `step(dt:)` shorter than half a tick.
    private(set) var tickCount = 0

    /// True while a scripted strike or retract is running or queued.
    var isBusy: Bool { current != nil || !queue.isEmpty }
    var isManual: Bool { manual != nil }
    /// Fully reeled into the notch: nothing to draw, nothing to simulate.
    private(set) var isRetracted = true
    /// 0 when reeled in, 1 once enough rope is out to show the whole handle.
    var presence: Double { Self.presence(ropeLength: rope.length) }
    /// How far the hand is from where it rests at the anchor, points.
    var handDistanceFromRest: Double { (rope.hand.position - restPose.position).whipLength }

    /// Rope length the whip is heading for. Setting it animates the change (unfurling from the notch when
    /// retracted). Strikes set it themselves to reach their target and ignore changes while they run.
    var length: Double {
        get { lengthTween?.to ?? (isRetracted ? 0 : rope.length) }
        set {
            let target = max(0, newValue.isFinite ? newValue : 0)
            guard current == nil, abs(target - length) > 0.5 else { return }
            let delta = abs(target - rope.length)
            startLengthTween(to: target, duration: WhipMath.clamp(0.3 + delta / 4000, 0.3, 0.5))
        }
    }

    private enum Task {
        case strike(Strike)
        case retract(Retract)
    }

    private final class Strike {
        let target: WhipVec
        let completion: (() -> Void)?
        var plan: WhipStrikePlan?
        var predictor: WhipStrikePredictor?
        /// The snap the rehearsal saw.
        var predictedSnap: WhipStrikePredictor.Snap?
        var ticks = 0
        var crackedAt: Double?
        var closest: (distance: Double, point: WhipVec, speed: Double)?
        var armed = false

        init(target: WhipVec, completion: (() -> Void)?) {
            self.target = target
            self.completion = completion
        }

        var elapsed: Double { Double(ticks) * WhipRig.tick }
    }

    private final class Retract {
        let completion: (() -> Void)?
        var elapsed = 0.0
        var fromLength: Double?

        init(completion: (() -> Void)?) { self.completion = completion }
    }

    private struct LengthTween {
        var from: Double
        var to: Double
        var duration: Double
        var elapsed = 0.0
    }

    private struct Manual {
        var target: WhipVec
        var velocity = WhipVec.zero
        var angle: Double
        /// Seconds since the whip was grabbed.
        var held = 0.0
        /// Right after the grab the hand glides over to the cursor instead of teleporting there.
        var gliding = true
        /// When the hand last moved fast enough to count as a flick.
        var lastFlick = -Double.infinity
        /// Cracks re-arm only once the tip has slowed down again: one crack per flick, not one per recoil.
        var armed = false
    }

    private var accumulator = 0.0
    private var current: Task?
    private var queue: [Task] = []
    private var lengthTween: LengthTween?
    private var manual: Manual?
    private var pendingCompletions: [() -> Void] = []
    private var lastCrackTime = -Double.infinity
    /// After a scripted crack: when it happened, and the pose the follow-through recoils from.
    private var recoil: (time: Double, from: WhipHandPose)?
    private var fieldBlend: (from: WhipVec, to: WhipVec, elapsed: Double, duration: Double)?
    /// Seconds since the rope went limp after a scripted crack.
    private var limp: Double?

    /// `length` 0 starts reeled in; anything else unfurls out of the notch right away.
    init(anchor: WhipVec, length: Double, config: WhipRope.Config = WhipRope.Config()) {
        self.anchor = anchor
        let stowed = WhipHandPose(position: anchor + WhipVec(0, config.handleLength), angle: -.pi / 2)
        rope = WhipRope(config: config, hand: stowed, length: 0)
        if length > 0 { self.length = length }
    }

    // MARK: - Commands

    /// Queues a scripted strike that cracks near `target`.
    func strike(at target: WhipVec, completion: (() -> Void)? = nil) {
        manual = nil
        guard target.isWhipFinite else {
            if let completion { pendingCompletions.append(completion) }
            return
        }
        queue.append(.strike(Strike(target: target, completion: completion)))
    }

    /// Reels the whip into the notch. Cancels queued strikes and cuts a running one short (their
    /// completions still run, without cracking).
    func retract(completion: (() -> Void)? = nil) {
        manual = nil
        cancelScripted()
        if isRetracted {
            lengthTween = nil
            if let completion { pendingCompletions.append(completion) }
            return
        }
        current = .retract(Retract(completion: completion))
    }

    /// Hands the whip to the mouse. Cancels scripted strikes (their completions still run).
    func beginManualControl(at point: WhipVec) {
        cancelScripted()
        manual = Manual(target: point.isWhipFinite ? point : restPose.position, angle: rope.hand.angle)
        if rope.length < tuning.restingLength * 0.5 || (lengthTween?.to ?? 1) < 1 {
            startLengthTween(to: tuning.restingLength, duration: 0.35)
        }
    }

    func moveHandle(to point: WhipVec) {
        guard manual != nil, point.isWhipFinite else { return }
        manual?.target = point
    }

    /// The hand drifts back to the notch; the whip keeps hanging there.
    func endManualControl() {
        manual = nil
    }

    private func cancelScripted() {
        var tasks = queue
        if let current { tasks.insert(current, at: 0) }
        for task in tasks {
            switch task {
            case .strike(let s): if let c = s.completion { pendingCompletions.append(c) }
            case .retract(let r): if let c = r.completion { pendingCompletions.append(c) }
            }
        }
        queue.removeAll()
        current = nil
        rope.guide = nil
        if rope.gravity != rope.config.gravity { setField(rope.config.gravity, over: 0.1) }
    }

    // MARK: - Stepping

    /// Advances by `dt` seconds of real time (clamped to 1/30 s) in fixed ticks.
    func step(dt: Double) {
        defer { flushCompletions() }
        frameTipPath.removeAll(keepingCapacity: true)
        accumulator += WhipMath.clamp(dt.isFinite ? dt : 0, 0, 1.0 / 30)
        // A tick runs once half of it has accrued (the clock may run up to half a tick ahead), so a 60 or
        // 120 Hz display gets the same number of ticks every frame even when its timestamps jitter —
        // waiting for a whole tick would stutter between 0 and 2 ticks per frame.
        while accumulator >= Self.tick * 0.5 {
            accumulator -= Self.tick
            tickCount += 1
            advance()
            if !isRetracted { frameTipPath.append(contentsOf: rope.tipPath.dropFirst()) }
        }
    }

    private func flushCompletions() {
        while !pendingCompletions.isEmpty {
            let completions = pendingCompletions
            pendingCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    private func advance() {
        let dt = Self.tick
        time += dt
        if current == nil, !queue.isEmpty { current = queue.removeFirst() }
        if isRetracted, current == nil, lengthTween == nil, manual == nil { return }
        isRetracted = false

        switch current {
        case .strike(let s)?:
            advanceStrike(s)
        case .retract(let r)?:
            advanceRetract(r)
        case nil:
            advanceFieldBlend(dt)
            advanceLimp(dt)
            advanceLengthTween(dt)
            let pose = manual != nil ? manualPose(dt: dt) : idlePose(dt: dt)
            rope.step(dt: dt, hand: emerging(pose), carry: Self.carry(ropeLength: rope.length))
            if manual != nil { detectManualCrack() }
        }
    }

    // MARK: - Poses

    private var restPose: WhipHandPose { WhipHandPose(position: anchor + WhipVec(0, -4), angle: -.pi / 2) }
    private var stowedPose: WhipHandPose {
        WhipHandPose(position: anchor + WhipVec(0, rope.config.handleLength), angle: -.pi / 2)
    }

    static func presence(ropeLength: Double) -> Double { WhipMath.clamp((ropeLength - 2) / 60, 0, 1) }

    /// While the handle is sliding out of (or into) the notch, the short rope moves rigidly with it.
    static func carry(ropeLength: Double) -> Double { presence(ropeLength: ropeLength) < 1 ? 1 : 0 }

    /// While only a little rope is out, the handle slides out of (or back into) the notch.
    static func emerging(_ pose: WhipHandPose, rest: WhipHandPose, ropeLength: Double, handleLength: Double) -> WhipHandPose {
        let hidden = 1 - presence(ropeLength: ropeLength)
        guard hidden > 0 else { return pose }
        var p = pose.mixed(with: rest, hidden)
        p.position.y += handleLength * hidden
        return p
    }

    private func emerging(_ pose: WhipHandPose) -> WhipHandPose {
        Self.emerging(pose, rest: restPose, ropeLength: rope.length, handleLength: rope.config.handleLength)
    }

    private func idlePose(dt: Double) -> WhipHandPose {
        var target = restPose
        // Lash fidgets: a slow sway keeps the hanging whip alive.
        target.position.x += 5 * sin(time * 1.3) + 2 * sin(time * 3.1)
        target.angle += 0.06 * sin(time * 1.7 + 0.4)
        if let recoil {
            // Settle back from the follow-through with a little overshoot.
            let u = (time - recoil.time) / 0.45
            if u < 1 { return recoil.from.mixed(with: target, WhipMath.easeOutBack(u, overshoot: 1.2)) }
            self.recoil = nil
        }
        // While the handle slides out of the notch, `emerging` moves it; afterwards ease toward the rest pose.
        if presence < 1 { return target }
        return rope.hand.mixed(with: target, WhipMath.approach(dt, tau: 0.12))
    }

    private func manualPose(dt: Double) -> WhipHandPose {
        guard var m = manual else { return rope.hand }
        m.held += dt
        let previous = rope.hand.position
        // Slight smoothing so the handle feels weighty but never laggy; right after the grab the hand
        // glides over from the notch instead of teleporting (which would crack on the spot).
        var travel = (m.target - previous) * WhipMath.approach(dt, tau: 0.025)
        if m.gliding {
            let limit = tuning.grabGlideSpeed * dt
            if travel.whipLength > limit { travel *= limit / travel.whipLength }
            m.gliding = (m.target - previous).whipLength > 12 && m.held < 1.5
        }
        let position = previous + travel
        let handVelocity = travel / dt
        m.velocity += (handVelocity - m.velocity) * WhipMath.approach(dt, tau: 0.05)
        if !m.gliding, handVelocity.whipLength > tuning.flickHandSpeed { m.lastFlick = time }
        // The handle leads along the motion when moving and drifts back toward hanging when still.
        let speed = m.velocity.whipLength
        let motionWeight = WhipMath.smoothstep((speed - 120) / 700)
        let desired = motionWeight > 0 ? m.velocity.whipAngle : -Double.pi / 2
        let blended = m.angle + WhipMath.angleDelta(from: m.angle, to: desired) * max(motionWeight, 0.25)
        m.angle += WhipMath.angleDelta(from: m.angle, to: blended) * WhipMath.approach(dt, tau: 0.06)
        manual = m
        return WhipHandPose(position: position, angle: m.angle)
    }

    // MARK: - Length

    private func startLengthTween(to target: Double, duration: Double) {
        if target > 0, isRetracted {
            rope.teleport(hand: stowedPose)
            rope.hangStraight()
        }
        lengthTween = LengthTween(from: rope.length, to: target, duration: duration)
    }

    private func advanceLengthTween(_ dt: Double) {
        guard var tween = lengthTween else { return }
        tween.elapsed += dt
        let u = tween.elapsed / tween.duration
        // Unfurling springs out a little too far and settles; shortening glides.
        let eased = tween.to > tween.from ? WhipMath.easeOutBack(u) : WhipMath.smootherstep(u)
        rope.setLength(max(0, WhipMath.mix(tween.from, tween.to, eased)))
        guard u >= 1 else { lengthTween = tween; return }
        lengthTween = nil
        if tween.to < 1 { stow() }
    }

    // MARK: - Field and limpness

    private func setField(_ field: WhipVec, over duration: Double) {
        fieldBlend = (rope.gravity, field, 0, max(duration, 1e-3))
    }

    private func advanceFieldBlend(_ dt: Double) {
        guard var blend = fieldBlend else { return }
        blend.elapsed += dt
        let u = WhipMath.smoothstep(blend.elapsed / blend.duration)
        rope.gravity = blend.from + (blend.to - blend.from) * u
        fieldBlend = u >= 1 ? nil : blend
    }

    /// After a crack the thong goes limp: heavy damping that fades, so it drops instead of swinging on.
    private func advanceLimp(_ dt: Double) {
        guard let t = limp.map({ $0 + dt }) else { return }
        let fade = 1 - WhipMath.smoothstep(t / tuning.limpDuration)
        rope.extraDamping = tuning.limpDamping * fade
        limp = fade > 0 ? t : nil
    }

    // MARK: - Retract

    private func advanceRetract(_ r: Retract) {
        let dt = Self.tick
        advanceFieldBlend(dt)
        advanceLimp(dt)
        lengthTween = nil
        let from = r.fromLength ?? rope.length
        r.fromLength = from
        r.elapsed += dt
        let u = WhipMath.clamp(r.elapsed / tuning.retractDuration, 0, 1)
        // Reel in steadily, then slurp the last of it up.
        rope.setLength(from * (1 - (0.35 * u * u * (2 - u) + 0.65 * u * u * u)))
        rope.step(dt: dt, hand: emerging(rope.hand.mixed(with: restPose, WhipMath.approach(dt, tau: 0.06))),
                  carry: Self.carry(ropeLength: rope.length))
        guard u >= 1 else { return }
        current = nil
        stow()
        if let c = r.completion { pendingCompletions.append(c) }
    }

    private func stow() {
        rope.setLength(0)
        rope.gravity = rope.config.gravity
        rope.extraDamping = 0
        rope.guide = nil
        fieldBlend = nil
        limp = nil
        recoil = nil
        rope.teleport(hand: stowedPose)
        rope.hangStraight()
        isRetracted = true
    }

    // MARK: - Scripted strike

    private func advanceStrike(_ s: Strike) {
        let dt = Self.tick
        if s.plan == nil {
            // Take over from whatever the whip was doing, mid-motion.
            recoil = nil
            limp = nil
            fieldBlend = nil
            lengthTween = nil
            rope.extraDamping = 0
            let plan = WhipStrikePlan(target: s.target, anchor: anchor, rest: restPose, rope: rope, tuning: tuning,
                                      bounds: bounds)
            s.plan = plan
            s.predictor = WhipStrikePredictor(plan: plan, rope: rope, dt: dt)
        }
        guard var plan = s.plan else { return }
        s.ticks += 1
        let elapsed = s.elapsed

        if let cracked = s.crackedAt {
            advanceFieldBlend(dt)
            advanceLimp(dt)
            let recoilPose = plan.correctedForward.mixed(with: restPose, WhipMath.easeOutBack((elapsed - cracked) / 0.45, overshoot: 1.2))
            rope.step(dt: dt, hand: recoilPose)
            // With the next strike already queued the volley flows straight on (it takes over mid-motion).
            let followThrough = queue.isEmpty ? tuning.followThrough : tuning.chainedFollowThrough
            if elapsed - cracked >= followThrough {
                // Hand the rest of the follow-through to the idle pose so the next command chains mid-motion.
                current = nil
                recoil = (time - (elapsed - cracked), plan.correctedForward)
                if let c = s.completion { pendingCompletions.append(c) }
            }
            return
        }

        if let predictor = s.predictor {
            if elapsed >= plan.flickStart {
                predictor.advance(budget: .max)
                plan = predictor.plan
                s.plan = plan
                s.predictedSnap = predictor.snap
                s.predictor = nil
                onEvent?(.whoosh)
            } else {
                predictor.advance(budget: tuning.predictorBudget)
            }
        }
        WhipStrikePlan.advance(&rope, plan: plan, elapsed: elapsed, dt: dt)
        if elapsed >= plan.flickStart { detectScriptedCrack(s, plan: plan) }
    }

    private func detectScriptedCrack(_ s: Strike, plan: WhipStrikePlan) {
        // Closest approach of the tip's continuous path to the target during this tick.
        let path = rope.tipPath
        var tickBest: (distance: Double, point: WhipVec, speed: Double)?
        var tickBestSubstep = 0
        for k in 1..<path.count {
            let p = WhipMath.closestPoint(on: path[k - 1].position, path[k].position, to: plan.target)
            let d = (p - plan.target).whipLength
            if d < tickBest?.distance ?? .infinity {
                tickBest = (d, p, path[k].speed)
                tickBestSubstep = k
            }
        }
        guard let tickBest else { return }
        if tickBest.distance < s.closest?.distance ?? .infinity { s.closest = tickBest }

        let hit: (distance: Double, point: WhipVec, speed: Double)
        if let snap = s.predictedSnap {
            // The rehearsal is exact: crack in the tick where it saw the snap pass the target.
            guard s.elapsed >= snap.elapsed - Self.tick * 0.5 else { return }
            hit = s.elapsed <= snap.elapsed + Self.tick * 0.5 ? tickBest : (s.closest ?? tickBest)
        } else {
            // No rehearsal (should not happen): crack as the tip leaves the target, or at the deadline.
            if tickBest.distance <= tuning.captureRadius { s.armed = true }
            let receding = s.armed && (rope.tip - plan.target).whipLength > (s.closest?.distance ?? 0) + 1
            guard receding || s.elapsed >= plan.flickStart + tuning.snapSearchWindow.latest else { return }
            hit = s.closest ?? tickBest
        }

        s.crackedAt = s.elapsed
        // The crack spends the throw: stop the tip where it broke the sound barrier (not a whole fast tick
        // further on) and let the thong drop from there instead of wheeling on round the hand.
        if hit.point == tickBest.point { rope.rewind(toSubstep: tickBestSubstep) }
        rope.absorb(keep: tuning.crackKeep)
        setField(rope.config.gravity, over: 0.12)
        limp = 0
        lastCrackTime = time
        // Scale-free snap speed, in rope lengths per second: ~80–120 for a typical strike.
        let snapRate = hit.speed / max(rope.length, 1)
        let intensity = 0.55 + 0.45 * WhipMath.smoothstep((snapRate - 50) / 100)
        onEvent?(.crack(point: hit.point, intensity: intensity))
    }

    // MARK: - Manual

    private func detectManualCrack() {
        let path = rope.tipPath
        guard var m = manual, path.count > 1,
              let peakIndex = path.indices.dropFirst().max(by: { path[$0].speed < path[$1].speed }) else { return }
        let peak = path[peakIndex]
        defer { manual = m }
        guard m.armed else {
            m.armed = !m.gliding && time - lastCrackTime >= tuning.crackCooldown
                && peak.speed < tuning.crackSpeed * tuning.crackRearm
            return
        }
        // Only a flick cracks: lazy waving can still snap the light tip, but that's not the user cracking it.
        guard peak.speed > tuning.crackSpeed, time - m.lastFlick <= tuning.flickWindow else { return }
        m.armed = false
        lastCrackTime = time
        // As with a scripted crack, draw the tip where it cracked and let the crack spend some of the energy.
        rope.rewind(toSubstep: peakIndex)
        rope.absorb(keep: tuning.manualCrackKeep)
        let intensity = WhipMath.clamp(0.35 + 0.65 * (peak.speed - tuning.crackSpeed) / (tuning.crackSpeed * 1.2), 0.35, 1)
        onEvent?(.crack(point: peak.position, intensity: intensity))
    }
}
