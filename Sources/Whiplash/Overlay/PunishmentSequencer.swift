import CoreGraphics
import Foundation

/// The punishment timeline as a pure state machine.
///
/// It owns no nodes and reads no clock: PunishmentScene feeds it frame time through `advance(by:)` and reports
/// what happened through `handle(_:)`; both return the `Command`s to perform right now. Every completion comes
/// back as an `Input` and every wait has a timeout, so the show goes on whether the whip and FX finish their
/// animations synchronously, a second later, or never — under an SKView, OffscreenRenderer, or a unit test.
///
///     auto:   intro → striking(0) → recovering(0) → striking(1) → striking(2) → … → recovering(n-1)
///               → creaking → [awaitingGlyphs] → shattering → holding → reassembling → fadingOut → finished
///
/// From the second strike on, the next strike is called right after the crack (`Timing.chainDelay`) and the whip
/// flows into it from mid-follow-through, so the volley speeds up into the shatter.
///     manual: manual ─(6 cracks)→ creaking → … same tail; `skip` (Esc) reassembles at any time.
///
/// `dismiss` and the hard timeout take the quick exit: reassembly at `timeScale` 3× plus a short fade, ≤ 0.4 s.
final class PunishmentSequencer {
    enum Mode: Equatable {
        case auto
        case manual
    }

    enum Phase: Equatable {
        /// A beat of stillness while the overlay silently replaces the live screen.
        case intro
        /// Waiting for strike `n` to complete.
        case striking(Int)
        /// A breath after strike `n` before the next wind-up.
        case recovering(Int)
        /// The user holds the whip.
        case manual
        /// The glass groans before it goes.
        case creaking
        /// Creaking some more while OCR finishes (bounded by `Timing.glyphGrace`).
        case awaitingGlyphs
        case shattering
        /// The screen lies broken: the break.
        case holding
        case reassembling(quick: Bool)
        case fadingOut(quick: Bool)
        case finished
    }

    enum Command: Equatable {
        case strike(index: Int, target: CGPoint)
        /// Strike `index` ended without the whip reporting a crack: crack the glass at its target anyway.
        case fallbackCrack(index: Int, at: CGPoint)
        case retract
        case creak
        case shatter
        case reassemble(quick: Bool)
    }

    enum Input: Equatable {
        case strikeFinished(index: Int)
        case cracked
        case glyphsReady
        case shatterFinished
        case reassembled
        /// Click / Esc (auto: only during the break) or Esc / right-click (manual: any time).
        case skip
        /// Leave now, whatever is happening.
        case dismiss
    }

    struct Timing {
        var intro: TimeInterval = 0.3
        /// Pause after a strike completes before the next one (strikes that are not chained).
        var strikeGap: TimeInterval = 0
        /// Strikes from this index on chain the next strike `chainDelay` after their crack.
        var chainFrom = 1
        var chainDelay: TimeInterval = 0.1
        /// Longest wait for a strike to report completion before moving on anyway.
        var strikeTimeout: TimeInterval = 2.5
        /// From the last strike to the shatter, when the final strike did not crack by itself (fallback crack).
        var creak: TimeInterval = 0.35
        /// From the final hit's crack to the shatter: just long enough for its web to spread. The glass gives way and
        /// the text lets go right on the final hit, without waiting for OCR (late text still drops as it arrives).
        var finalBreak: TimeInterval = 0.12
        /// Longest extra wait for harvested text before shattering without it.
        var glyphGrace: TimeInterval = 1.0
        /// While waiting for text, the glass creaks this often.
        var creakInterval: TimeInterval = 0.3
        /// Longest wait for the shatter to report completion before the hold starts.
        var shatterTimeout: TimeInterval = 2.5
        /// Hold for plans that only crack (no broken screen to stare at).
        var crackOnlyHold: TimeInterval = 1.2
        /// Longest wait for reassembly to report completion.
        var reassembleTimeout: TimeInterval = 4
        var fade: TimeInterval = 0.6
        /// Quick exit: reassembly budget (run at `quickTimeScale`) plus fade — together ≤ 0.4 s.
        var quickReassemble: TimeInterval = 0.3
        var quickFade: TimeInterval = 0.1
        var quickTimeScale: Double = 3
        var autoTimeout: TimeInterval = 40
        var manualTimeout: TimeInterval = 120
        /// Manual mode shatters by itself after this many cracks.
        var manualCracksToShatter = 6
    }

    let mode: Mode
    let targets: [CGPoint]
    let shatters: Bool
    let holdSeconds: TimeInterval
    let timing: Timing

    private(set) var phase: Phase
    /// Time spent in the current phase.
    private(set) var phaseTime: TimeInterval = 0
    /// Time since the sequence started.
    private(set) var elapsed: TimeInterval = 0
    /// Every crack that damaged the glass, including fallback cracks.
    private(set) var crackCount = 0
    private(set) var fallbackCrackCount = 0
    private(set) var glyphsReady: Bool
    private(set) var didShatter = false

    private var crackedThisStrike = false
    /// `phaseTime` of the current strike's crack.
    private var crackedAt: TimeInterval?
    private var whipOut: Bool
    /// How long the current creak lasts, and whether it may wait for text (see `Timing.finalBreak`).
    private var creakLimit: TimeInterval = 0
    private var waitsForGlyphs = true
    private var sinceCreak: TimeInterval = 0

    init(mode: Mode, targets: [CGPoint], shatters: Bool, holdSeconds: TimeInterval, glyphsReady: Bool,
         timing: Timing = Timing()) {
        self.mode = mode
        self.targets = mode == .manual ? [] : targets
        self.shatters = shatters
        self.holdSeconds = max(0, holdSeconds)
        self.glyphsReady = glyphsReady
        self.timing = timing
        phase = mode == .manual ? .manual : .intro
        whipOut = mode == .manual
    }

    // MARK: - State queries

    var isFinished: Bool { phase == .finished }

    var isWindingDown: Bool {
        switch phase {
        case .reassembling, .fadingOut, .finished: return true
        default: return false
        }
    }

    /// Whether a click / Esc does anything right now.
    var acceptsSkip: Bool {
        switch mode {
        case .manual: return !isWindingDown
        case .auto: return phase == .shattering || phase == .holding
        }
    }

    /// Whether new cracks still damage the glass (it is gone once it shatters).
    var acceptsDamage: Bool {
        switch phase {
        case .intro, .striking, .recovering, .manual, .creaking, .awaitingGlyphs: return true
        default: return false
        }
    }

    /// Whether harvested text is still useful (it may arrive until the shards are falling).
    var acceptsGlyphs: Bool { acceptsDamage || phase == .shattering }

    /// The strike in flight, if any.
    var currentStrike: Int? {
        if case .striking(let index) = phase { return index }
        return nil
    }

    /// How fast the whip and FX should run: sped up while hurrying out.
    var timeScale: Double {
        switch phase {
        case .reassembling(quick: true), .fadingOut(quick: true): return timing.quickTimeScale
        default: return 1
        }
    }

    /// Opacity of everything on screen: 1 until the final fade.
    var presentationAlpha: CGFloat {
        switch phase {
        case .fadingOut(let quick):
            let duration = quick ? timing.quickFade : timing.fade
            return duration > 0 ? CGFloat(max(0, 1 - phaseTime / duration)) : 0
        case .finished:
            return 0
        default:
            return 1
        }
    }

    /// Seconds left of the break while the screen lies broken; nil otherwise.
    var holdRemaining: TimeInterval? {
        phase == .holding ? max(0, holdDuration - phaseTime) : nil
    }

    var hardTimeout: TimeInterval { mode == .manual ? timing.manualTimeout : timing.autoTimeout }

    private var holdDuration: TimeInterval { shatters ? holdSeconds : min(holdSeconds, timing.crackOnlyHold) }

    // MARK: - Driving

    /// Moves time forward by `dt` seconds.
    func advance(by dt: TimeInterval) -> [Command] {
        guard !isFinished else { return [] }
        elapsed += dt
        phaseTime += dt
        if elapsed >= hardTimeout, !isWindingDown {
            return beginReassembly(quick: true)
        }
        switch phase {
        case .intro:
            return phaseTime >= timing.intro ? nextStrikeOrWrapUp(after: nil) : []
        case .striking(let index):
            if let crackedAt, index >= timing.chainFrom, index + 1 < targets.count, phaseTime - crackedAt >= timing.chainDelay {
                // Chain: the next wind-up starts from mid-follow-through (this strike's completion is then ignored).
                return nextStrikeOrWrapUp(after: index)
            }
            return phaseTime >= timing.strikeTimeout ? finishStrike(index) : []
        case .recovering(let index):
            return phaseTime >= timing.strikeGap ? nextStrikeOrWrapUp(after: index) : []
        case .manual, .finished:
            return []
        case .creaking:
            guard phaseTime >= creakLimit else { return [] }
            if glyphsReady || !waitsForGlyphs { return beginShatter() }
            enter(.awaitingGlyphs)
            sinceCreak = 0
            return []
        case .awaitingGlyphs:
            if phaseTime >= timing.glyphGrace { return beginShatter() }
            sinceCreak += dt
            guard sinceCreak >= timing.creakInterval else { return [] }
            sinceCreak = 0
            return [.creak]
        case .shattering:
            if phaseTime >= timing.shatterTimeout { enter(.holding) }
            return []
        case .holding:
            return phaseTime >= holdDuration ? beginReassembly(quick: false) : []
        case .reassembling(let quick):
            if phaseTime >= (quick ? timing.quickReassemble : timing.reassembleTimeout) { enter(.fadingOut(quick: quick)) }
            return []
        case .fadingOut(let quick):
            if phaseTime >= (quick ? timing.quickFade : timing.fade) { enter(.finished) }
            return []
        }
    }

    /// Reports something that happened.
    func handle(_ input: Input) -> [Command] {
        switch input {
        case .strikeFinished(let index):
            return phase == .striking(index) ? finishStrike(index) : []
        case .cracked:
            guard acceptsDamage else { return [] }
            crackCount += 1
            if case .striking(let index) = phase {
                crackedThisStrike = true
                if crackedAt == nil { crackedAt = phaseTime }
                // The final strike breaks the glass on the spot.
                if shatters, index == targets.count - 1 { return breakOnFinalHit(reelIn: true) }
            }
            if phase == .manual, crackCount >= timing.manualCracksToShatter {
                // The user keeps the whip through the break; it goes back into the notch with the rewind.
                return shatters ? breakOnFinalHit(reelIn: false) : beginReassembly(quick: false)
            }
            return []
        case .glyphsReady:
            glyphsReady = true
            return phase == .awaitingGlyphs ? beginShatter() : []
        case .shatterFinished:
            if phase == .shattering { enter(.holding) }
            return []
        case .reassembled:
            if case .reassembling(let quick) = phase { enter(.fadingOut(quick: quick)) }
            return []
        case .skip:
            return acceptsSkip ? beginReassembly(quick: false) : []
        case .dismiss:
            switch phase {
            case .finished, .fadingOut, .reassembling(quick: true):
                return []
            case .reassembling(quick: false):
                // Already on the way out: just hurry up (no second reassemble command).
                enter(.reassembling(quick: true))
                return []
            default:
                return beginReassembly(quick: true)
            }
        }
    }

    // MARK: - Transitions

    private func enter(_ next: Phase) {
        phase = next
        phaseTime = 0
    }

    private func nextStrikeOrWrapUp(after index: Int?) -> [Command] {
        let next = index.map { $0 + 1 } ?? 0
        guard next < targets.count else { return wrapUpStrikes() }
        enter(.striking(next))
        crackedThisStrike = false
        crackedAt = nil
        whipOut = true
        return [.strike(index: next, target: targets[next])]
    }

    private func finishStrike(_ index: Int) -> [Command] {
        enter(.recovering(index))
        guard !crackedThisStrike else { return [] }
        crackCount += 1
        fallbackCrackCount += 1
        return [.fallbackCrack(index: index, at: targets[index])]
    }

    private func wrapUpStrikes() -> [Command] {
        var commands: [Command] = whipOut ? [.retract] : []
        whipOut = false
        if shatters {
            commands += beginCreak()
        } else {
            enter(.holding)
        }
        return commands
    }

    private func beginCreak() -> [Command] {
        enter(.creaking)
        creakLimit = timing.creak
        waitsForGlyphs = true
        return [.creak]
    }

    /// The final hit landed: the glass gives way `Timing.finalBreak` later, text or not. `reelIn`: the scripted whip
    /// goes back into the notch right away.
    private func breakOnFinalHit(reelIn: Bool) -> [Command] {
        var commands: [Command] = reelIn && whipOut ? [.retract] : []
        if reelIn { whipOut = false }
        commands += beginCreak()
        creakLimit = timing.finalBreak
        waitsForGlyphs = false
        return commands
    }

    private func beginShatter() -> [Command] {
        enter(.shattering)
        didShatter = true
        return [.shatter]
    }

    private func beginReassembly(quick: Bool) -> [Command] {
        var commands: [Command] = whipOut ? [.retract] : []
        whipOut = false
        enter(.reassembling(quick: quick))
        commands.append(.reassemble(quick: quick))
        return commands
    }
}
