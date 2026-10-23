import CoreGraphics
import simd

/// Timing and feel of scripted strikes and of the manual whip.
struct WhipTuning {
    /// Tip speed (points/s) that cracks in manual mode.
    var crackSpeed = 5200.0
    var crackCooldown = 0.25
    /// Fraction of the rope's velocity left after a manual crack (the user's throw keeps most of its life).
    var manualCrackKeep = 0.45
    /// After a manual crack the tip must drop below this fraction of `crackSpeed` before it can crack again.
    var crackRearm = 0.45
    /// A manual crack needs the hand to have moved faster than this (points/s) within `flickWindow` seconds: a real
    /// flick. (Slower, e.g. ~1000 pt/s for a lazy wind-up, would crack on the wind-up or the recoil, and the cooldown
    /// would then swallow the actual snap.)
    var flickHandSpeed = 1800.0
    var flickWindow = 0.22
    /// Right after the whip is grabbed the hand glides to the cursor at this speed (points/s) at most.
    var grabGlideSpeed = 900.0
    /// Rope length when the whip is grabbed.
    var restingLength = 380.0
    /// Shortest rope a strike uses.
    var minimumStrikeLength = 150.0

    // Scripted strike choreography (seconds).
    /// Extra time a strike takes to drop the whip out of the notch when it starts reeled in.
    var unfurlDuration = 0.28
    var windUpDuration = 0.32
    var flickDuration = 0.2
    /// The natural snap is searched for this long after the flick starts.
    var snapSearchWindow = (earliest: 0.1, latest: 0.45)
    var followThrough = 0.25
    /// Follow-through when the next strike is already queued: the volley flows straight on into the next wind-up.
    var chainedFollowThrough = 0.1
    var retractDuration = 0.45

    /// How far the hand travels toward the target during the flick, and sideways during the wind-up.
    var handForward = 70.0
    var handBack = 50.0
    /// How far below the anchor the hand may go during a strike (wind-up and flick). The anchor sits just inside the
    /// island's bottom edge, so Lash's paw slides and twists along that edge instead of leaving the island.
    var handDip = 8.0
    var windUpDip = 6.0
    /// Throw field per point of rope length, points/s² (so strikes take the same time at any length).
    var fieldPerLength = 46.0
    /// Extra wind-up angle beyond perpendicular to the aim, radians.
    var windUpExtraAngle = 20.0 * .pi / 180
    /// The wound-up rope points at least this far below the horizon (radians), so it stays on screen.
    var windUpMinimumDip = 16.0 * .pi / 180
    /// Long ropes wind up steeper so their far end stays at least this far inside the screen's sides.
    var windUpMargin = 24.0
    /// How far past the aim the wrist snaps, radians.
    var flickOvershoot = 15.0 * .pi / 180
    /// First guess (refined by the predictor) of how far the snap reaches relative to the rope's rest length.
    var reachRatio = 1.08
    /// The crack fires when the tip passes within this distance of the target.
    var captureRadius = 30.0
    /// Fraction of the rope's velocity left after a scripted crack: the crack spends the throw's energy, so
    /// the thong stops dead, extended toward the target, instead of wheeling on round the hand.
    var crackKeep = 0.2
    /// Damping (1/s) that makes the thong go limp after a scripted crack, fading out over `limpDuration`.
    var limpDamping = 5.0
    var limpDuration = 0.6
    /// Spring rate (1/s²) of the guide that poses the rope during the wind-up (critically damped).
    var windUpStiffness = 600.0
    /// Preview ticks the predictor may run per real tick while the whip winds up.
    var predictorBudget = 12
}

/// One scripted strike's choreography. Every control is a pure function of the elapsed time and the rope's
/// state, so `WhipStrikePredictor` can run it ahead of time on a copy of the rope and get the same result.
struct WhipStrikePlan {
    /// Adjustment to the throw found by the predictor.
    struct Correction {
        /// Radians added to the throw direction and to the flick.
        var rotation = 0.0
        /// Factor on the rope length during the throw.
        var scale = 1.0
    }

    /// What drives the rope during one tick.
    struct Controls {
        var pose: WhipHandPose
        var gravity: WhipVec
        var length: Double
        var guide: WhipRope.Guide?
        /// While the handle slides out of the notch it carries the rope along (see `WhipRope.step`).
        var carry: Double { WhipRig.carry(ropeLength: length) }
    }

    let target: WhipVec
    let tuning: WhipTuning
    let rest: WhipHandPose
    let startGravity: WhipVec
    let restGravity: WhipVec
    let startLength: Double
    /// Seconds spent first dropping the rope straight out of the notch (0 unless it starts reeled in).
    let unfurl: Double
    /// Hand pose, rope length and rope direction when the wind-up begins.
    let windUpPose: WhipHandPose
    let windUpLength: Double
    let windUpAngle: Double
    let back: WhipHandPose
    let forward: WhipHandPose
    /// Rope length after the wind-up.
    let length: Double
    let aimAngle: Double
    /// +1 when the rope swings counter-clockwise from the wind-up onto the target, −1 clockwise.
    let swing: Double
    let layoutAngle: Double
    var correction = Correction()

    var flickStart: Double { unfurl + tuning.windUpDuration }

    /// `bounds` is the visible screen (scene coordinates), if known.
    init(target requested: WhipVec, anchor: WhipVec, rest: WhipHandPose, rope: WhipRope, tuning: WhipTuning,
         bounds: CGRect? = nil) {
        self.tuning = tuning
        self.rest = rest
        // Keep the target below the notch so there is always room to swing down onto it.
        var target = requested
        target.y = min(target.y, anchor.y - 60)
        self.target = target

        let handle = rope.config.handleLength
        let toTarget = target - anchor
        let distance = max(1, toTarget.whipLength)
        let direction = toTarget / distance
        // Close targets get a smaller wrist action, so the hand doesn't overpower a short thong.
        let action = WhipMath.clamp(distance / 700, 0.3, 1)
        var forwardPosition = anchor + direction * (tuning.handForward * action)
        forwardPosition.y = max(forwardPosition.y, anchor.y - tuning.handDip)
        let root = forwardPosition + direction * handle
        let reach = max(1, (target - root).whipLength)
        let lineAngle = (target - root).whipAngle

        // Lay the rope out on the side where it stays on screen, then swing it round onto the target.
        let lineX = cos(lineAngle)
        let swing: Double = abs(lineX) > 0.05 ? (lineX < 0 ? -1 : 1) : (rope.tip.x < anchor.x ? 1 : -1)
        var layout = lineAngle - swing * (.pi / 2 + tuning.windUpExtraAngle)
        // Keep it below the horizon: the notch is at the very top of the screen.
        let lowest = -tuning.windUpMinimumDip
        if sin(layout) > sin(lowest) { layout = swing > 0 ? .pi - lowest : lowest }

        let length = max(tuning.minimumStrikeLength, reach / tuning.reachRatio)
        if let bounds, bounds.width > 0 {
            // A long rope laid out sideways would run off the screen: tip it down until it fits. The hand and
            // handle sit up to `handBack + handle` further out on that side, and the throw may still stretch
            // the rope a little (see `WhipStrikePredictor`).
            let right = cos(layout) >= 0
            let edge = right ? Double(bounds.maxX) - anchor.x : anchor.x - Double(bounds.minX)
            let room = edge - tuning.windUpMargin - (tuning.handBack * action + handle) * abs(cos(layout))
            let span = length * 1.15
            if room > 0, span > room {
                let dip = acos(WhipMath.clamp(room / span, 0, 1))
                if -sin(layout) < sin(dip) { layout = right ? -dip : -.pi + dip }
            }
        }

        let backDirection = WhipVec.whipUnit(layout)
        var backPosition = anchor + WhipVec(backDirection.x * tuning.handBack * action, -tuning.windUpDip)
        backPosition.y = min(backPosition.y, anchor.y - 4)

        self.swing = swing
        aimAngle = lineAngle
        layoutAngle = layout
        self.length = length
        back = WhipHandPose(position: backPosition, angle: layout - swing * 0.35)
        forward = WhipHandPose(position: forwardPosition, angle: lineAngle + swing * tuning.flickOvershoot)
        startGravity = rope.gravity
        restGravity = rope.config.gravity
        startLength = rope.length
        // Swinging a stub around would crumple it (and growing it would inflate the crumples into knots),
        // so a whip that starts reeled in first drops out of the notch, hanging straight.
        if rope.length < min(120, length * 0.3) {
            unfurl = tuning.unfurlDuration
            windUpPose = rest
            windUpLength = min(length, max(tuning.minimumStrikeLength, length * 0.55))
            windUpAngle = -.pi / 2
        } else {
            unfurl = 0
            windUpPose = rope.hand
            windUpLength = rope.length
            windUpAngle = (rope.positions[rope.count / 2] - rope.thongRoot).whipAngle
        }
    }

    /// The hand pose the flick ends in (after the predictor's correction).
    var correctedForward: WhipHandPose {
        WhipHandPose(position: forward.position, angle: forward.angle + correction.rotation)
    }

    func controls(at elapsed: Double, rope: WhipRope) -> Controls {
        let settle = WhipMath.smoothstep(elapsed / 0.08)
        let gravity = startGravity + (restGravity - startGravity) * settle
        if elapsed < unfurl {
            // Unfurl: the thong drops out of the notch with a little spring.
            let length = WhipMath.mix(startLength, windUpLength, WhipMath.easeOutBack(elapsed / unfurl, overshoot: 1.1))
            let pose = WhipRig.emerging(rest, rest: rest, ropeLength: length, handleLength: rope.config.handleLength)
            return Controls(pose: pose, gravity: gravity, length: length, guide: nil)
        }
        let windUp = elapsed - unfurl
        if elapsed < flickStart {
            // Wind-up: cock the handle back and swing the rope out to the side (anticipation).
            let duration = tuning.windUpDuration
            let u = WhipMath.smootherstep(windUp / duration)
            let length = WhipMath.mix(windUpLength, self.length, WhipMath.smootherstep(windUp / (duration * 0.9)))
            let pose = WhipRig.emerging(windUpPose.mixed(with: back, u), rest: rest, ropeLength: length,
                                        handleLength: rope.config.handleLength)
            return Controls(pose: pose, gravity: gravity, length: length,
                            guide: windUpGuide(rope: rope, time: windUp, strength: WhipMath.smoothstep(windUp / 0.08)))
        }
        // The throw: a fast flick toward the target while a field hurls the rope round onto it.
        let tau = elapsed - flickStart
        let length = WhipMath.mix(self.length, self.length * correction.scale, WhipMath.smoothstep(tau / 0.12))
        let aim = WhipVec.whipUnit(aimAngle + correction.rotation)
        let throwField = aim * (tuning.fieldPerLength * length)
        let field = restGravity + (throwField - restGravity) * WhipMath.smoothstep(tau / 0.05)
        let pose = back.mixed(with: correctedForward, WhipMath.smoothstep(tau / tuning.flickDuration))
        return Controls(pose: pose, gravity: field, length: length, guide: nil)
    }

    /// Targets for the wind-up: the rope swung from where it was round to the layout direction, its far end
    /// cocked back a little like a raised tail (which makes the throw's fold form cleanly and predictably).
    /// The sweep eases out, so the rope arrives at rest.
    private func windUpGuide(rope: WhipRope, time: Double, strength: Double) -> WhipRope.Guide {
        let duration = tuning.windUpDuration
        let progress = WhipMath.smootherstep(time / duration)
        let x = WhipMath.clamp(time / duration, 0, 1)
        let progressRate = 30 * x * x * (1 - x) * (1 - x) / duration
        let sweep = WhipMath.angleDelta(from: windUpAngle, to: layoutAngle)
        let root = rope.thongRoot
        var targets = rope.positions
        var velocities = [WhipVec](repeating: .zero, count: rope.count)
        for i in 2..<rope.count {
            let s = rope.arcLengths[i]
            let f = s / max(1, rope.length)
            let curl = swing * 0.2 * f * f
            let angle = windUpAngle + sweep * progress - curl * progress
            let angularRate = (sweep - curl) * progressRate
            let radial = WhipVec.whipUnit(angle)
            targets[i] = root + radial * s
            velocities[i] = WhipVec(-radial.y, radial.x) * (s * angularRate)
        }
        return WhipRope.Guide(targets: targets, targetVelocities: velocities,
                              stiffness: tuning.windUpStiffness, damping: 2 * tuning.windUpStiffness.squareRoot(),
                              strength: strength)
    }

    /// Applies `controls(at:rope:)` and advances the rope by one tick.
    static func advance(_ rope: inout WhipRope, plan: WhipStrikePlan, elapsed: Double, dt: Double) {
        let c = plan.controls(at: elapsed, rope: rope)
        rope.gravity = c.gravity
        rope.setLength(c.length)
        rope.guide = c.guide
        rope.step(dt: dt, hand: c.pose, carry: c.carry)
    }
}

/// Aims a strike by rehearsing it: runs the plan ahead on a copy of the rope, sees where the snap passes
/// the target, and rotates/stretches the throw until it passes right through it (a shooting method).
/// Work is spread over the wind-up in small budgets so there is never a frame hitch.
final class WhipStrikePredictor {
    /// Where and when the rehearsed snap passes closest to the target.
    struct Snap {
        var point: WhipVec
        /// Strike time (seconds since the strike began) of the tick in which it happens.
        var elapsed: Double
        var miss: Double
    }

    /// The plan with the best correction found so far (final once `advance` has run to completion).
    private(set) var plan: WhipStrikePlan
    /// The best rehearsed snap, once finished.
    private(set) var snap: Snap?

    private var isFinished = false
    private var iterations = 0

    private let dt: Double
    private var rope: WhipRope
    private var ticks = 0
    private var flick: (rope: WhipRope, ticks: Int)?
    /// Tip samples of the current rehearsal: (segment start, end, speed, tick, thong root).
    private var samples: [(a: WhipVec, b: WhipVec, speed: Double, ticks: Int, root: WhipVec)] = []
    private var peakSpeed = 0.0
    private var peakTicks = 0
    private var best: (correction: WhipStrikePlan.Correction, snap: Snap)?
    private var lastRehearsal: (applied: (rotation: Double, scale: Double), error: (rotation: Double, scale: Double))?
    private var gain = (rotation: 1.0, scale: 1.0)

    static let maxIterations = 8
    /// Good enough: the snap passes this close to the target.
    static let tolerance = 2.0
    /// Samples slower than this fraction of the peak tip speed don't count as the snap.
    static let snapSpeedFraction = 0.55

    init(plan: WhipStrikePlan, rope: WhipRope, dt: Double) {
        self.plan = plan
        self.rope = rope
        self.dt = dt
    }

    /// Runs up to `budget` preview ticks.
    func advance(budget: Int) {
        var budget = budget
        while budget > 0, !isFinished {
            budget -= 1
            guard let flick else {
                // Rehearse the wind-up once; every throw starts from wherever it leaves the rope.
                if Double(ticks + 1) * dt >= plan.flickStart {
                    self.flick = (rope, ticks)
                } else {
                    ticks += 1
                    WhipStrikePlan.advance(&rope, plan: plan, elapsed: Double(ticks) * dt, dt: dt)
                }
                continue
            }
            ticks += 1
            WhipStrikePlan.advance(&rope, plan: plan, elapsed: Double(ticks) * dt, dt: dt)
            let tau = Double(ticks) * dt - plan.flickStart
            if tau >= plan.tuning.snapSearchWindow.earliest {
                let path = rope.tipPath
                for k in 1..<path.count {
                    samples.append((path[k - 1].position, path[k].position, path[k].speed, ticks, rope.thongRoot))
                    if path[k].speed > peakSpeed { peakSpeed = path[k].speed; peakTicks = ticks }
                }
            }
            let settled = peakSpeed > 0 && ticks > peakTicks + Int(0.08 / dt) && rope.tipSpeed < peakSpeed * 0.3
            if tau >= plan.tuning.snapSearchWindow.latest || settled {
                finishRehearsal()
                rope = flick.rope
                ticks = flick.ticks
                samples.removeAll()
                peakSpeed = 0
            }
        }
    }

    private func finishRehearsal() {
        iterations += 1
        let target = plan.target
        var closest: (snap: Snap, root: WhipVec)?
        for sample in samples where sample.speed >= peakSpeed * Self.snapSpeedFraction {
            let p = WhipMath.closestPoint(on: sample.a, sample.b, to: target)
            let miss = (p - target).whipLength
            if miss < closest?.snap.miss ?? .infinity {
                closest = (Snap(point: p, elapsed: Double(sample.ticks) * dt, miss: miss), sample.root)
            }
        }
        guard let closest else { return finish() }
        if closest.snap.miss < best?.snap.miss ?? .infinity { best = (plan.correction, closest.snap) }
        guard closest.snap.miss > Self.tolerance, iterations < Self.maxIterations else { return finish() }
        let reached = closest.snap.point - closest.root
        let wanted = target - closest.root
        guard reached.whipLength > 1 else { return finish() }
        // Secant step per axis: how much the snap moved per unit of correction last time.
        let error = (rotation: WhipMath.angleDelta(from: reached.whipAngle, to: wanted.whipAngle),
                     scale: log(wanted.whipLength / reached.whipLength))
        let applied = (rotation: plan.correction.rotation, scale: log(plan.correction.scale))
        if let last = lastRehearsal {
            gain.rotation = Self.secantGain(errorChange: last.error.rotation - error.rotation,
                                            step: applied.rotation - last.applied.rotation, fallback: gain.rotation)
            gain.scale = Self.secantGain(errorChange: last.error.scale - error.scale,
                                         step: applied.scale - last.applied.scale, fallback: gain.scale)
        }
        lastRehearsal = (applied, error)
        let relax = 0.85
        plan.correction.rotation = WhipMath.clamp(applied.rotation + relax * error.rotation / gain.rotation, -0.6, 0.6)
        plan.correction.scale = exp(WhipMath.clamp(applied.scale + relax * error.scale / gain.scale, log(0.6), log(1.6)))
    }

    /// Estimated response of the snap to a change of correction, kept within sane bounds.
    private static func secantGain(errorChange: Double, step: Double, fallback: Double) -> Double {
        guard abs(step) > 1e-4 else { return fallback }
        return WhipMath.clamp(errorChange / step, 0.35, 3)
    }

    private func finish() {
        isFinished = true
        guard let best else { return }
        plan.correction = best.correction
        snap = best.snap
    }
}
