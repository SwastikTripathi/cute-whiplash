import Combine
import SwiftUI

/// Island state that belongs to the UI rather than to `IslandModel`: the geometry it is laid out for, whether the
/// cursor is hovering it, and whether the dashboard shows the snooze choices. Written by `NotchController`, the
/// dashboard itself, or a demo.
final class IslandUIState: ObservableObject {
    @Published var layout: IslandLayout
    @Published var isHovering: Bool
    /// The dashboard's Snooze button was pressed: its action row shows the durations. Reset when the dashboard closes.
    @Published var choosingSnooze: Bool

    init(layout: IslandLayout, isHovering: Bool = false, choosingSnooze: Bool = false) {
        self.layout = layout
        self.isHovering = isHovering
        self.choosingSnooze = choosingSnooze
    }
}

/// A heart that floats up from Lash while it is being petted.
struct HeartPuff: Identifiable, Equatable {
    let id: Int
    /// When it spawned, seconds since the reference date (the clock `TimelineView` gives).
    let born: TimeInterval
    /// Where it drifts sideways, -1 (far left) ... 1 (far right), relative to Lash's size.
    let drift: CGFloat
    /// Seconds a heart lives.
    static let lifetime: TimeInterval = 1.5
}

/// Lash's live behaviour: where it looks, blinking, naps, and its reactions to pokes, petting, head pats and
/// double-clicks. All state changes happen on the main thread.
final class LashState: ObservableObject {
    /// Pupil deflection (see `Gaze`), quantized so only visible changes publish.
    @Published private(set) var gaze: CGVector = .zero
    /// 0...1, animated by the blink timer.
    @Published private(set) var blink: CGFloat = 0
    /// A short reaction that overrides the mood's face (dizzy, blissful).
    @Published private(set) var reaction: LashExpression?
    /// Bumped on every poke; the view squashes and stretches whenever it changes.
    @Published private(set) var squishes = 0
    @Published private(set) var hearts: [HeartPuff] = []
    /// Bumped on every head pat; the view dips Lash's head under the hand.
    @Published private(set) var pats = 0
    /// Bumped on a double-click; the view spins Lash round with a hop.
    @Published private(set) var spins = 0

    static let dizzySeconds: TimeInterval = 2.2
    static let blissSeconds: TimeInterval = 1.6
    /// Two clicks this close together are a double-click (a spin).
    static let doubleClickWindow: TimeInterval = 0.3
    /// No cursor movement for this long, while nothing is going on and you're not working, and Lash dozes off.
    static let napAfter: TimeInterval = 90

    private let model: IslandModel
    private var pokes = PokeCounter()
    private var petting = PetDetector()
    private var patting = PatDetector()
    private var patsInARow = 0
    private var lastPurr: TimeInterval = -.infinity
    private var lastTap: TimeInterval = -.infinity
    private var lastCursorActivity = ProcessInfo.processInfo.systemUptime
    private var napTimer: Timer?
    private var isNapping = false
    private var phaseWatch: AnyCancellable?
    private var quips = QuipPicker()
    private var blinkTimer: Timer?
    private var reactionReset: DispatchWorkItem?
    private var nextHeartID = 0

    init(model: IslandModel, gaze: CGVector = .zero, reaction: LashExpression? = nil, hearts: [HeartPuff] = []) {
        self.model = model
        self.gaze = gaze
        self.reaction = reaction
        self.hearts = hearts
        // A nap never outlasts a quiet island: anything happening (a nudge, the whip) wakes Lash on the spot.
        phaseWatch = model.$phase.dropFirst().sink { [weak self] phase in
            if phase != .idle { self?.wake(quietly: true) }
        }
    }

    deinit {
        blinkTimer?.invalidate()
        napTimer?.invalidate()
    }

    /// The face to draw for `mood`: the current reaction, if any, wins.
    func expression(for mood: CritterMood) -> LashExpression { reaction ?? .mood(mood) }

    // MARK: Looking

    /// Points the pupils from `eye` toward `target` (same coordinate space, y down).
    func look(at target: CGPoint, from eye: CGPoint) {
        let next = Gaze.quantized(Gaze.vector(from: eye, to: target))
        if next != gaze { gaze = next }
    }

    // MARK: Blinking

    /// Blinks every 2.5–6 s (sometimes twice) until `stopBlinking()`. One single-shot timer at a time, never per-frame.
    func startBlinking() {
        blinkTimer?.invalidate()
        let timer = Timer(timeInterval: .random(in: 2.5...6), repeats: false) { [weak self] _ in
            self?.blinkOnce(thenAgain: Double.random(in: 0...1) < 0.18)
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    /// Whether the face Lash shows right now has open eyes that a blink could close.
    var eyesAreOpen: Bool {
        if case .open = LashFace(expression(for: model.mood)).eyes { return true }
        return false
    }

    private func blinkOnce(thenAgain: Bool) {
        // Asleep, laughing or dizzy: nothing to blink, so don't redraw Lash for nothing (snoozes last hours).
        guard eyesAreOpen else {
            startBlinking()
            return
        }
        withAnimation(.easeIn(duration: 0.06)) { blink = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.13)) { self.blink = 0 }
            guard self.blinkTimer != nil else { return } // stopped meanwhile
            if thenAgain {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.blinkOnce(thenAgain: false) }
            } else {
                self.startBlinking()
            }
        }
    }

    // MARK: Poking & petting

    /// A click on Lash: squish, boop, and a quip — or, on the fifth poke in two seconds, dizziness.
    func poke() {
        squishes += 1
        if pokes.poke(at: ProcessInfo.processInfo.systemUptime) {
            react(.dizzy, for: Self.dizzySeconds)
            play(.giggle)
            model.quip = quips.next(for: .dizzy)
        } else {
            play(.boop)
            model.quip = quips.next(for: reaction == .dizzy ? .dizzy : .mood(model.mood))
        }
    }

    /// The cursor moved to `point` (panel space). Resting or moving on Lash's head pats it; rubbing back and forth
    /// over Lash is petting; any movement wakes a napping Lash.
    func cursorMoved(to point: CGPoint, overLash: Bool, overHead: Bool = false) {
        lastCursorActivity = ProcessInfo.processInfo.systemUptime
        if isNapping { wake(quietly: false) }
        scheduleNapCheck()
        headPat(at: point, onHead: overHead)
        guard overLash else {
            petting.reset()
            return
        }
        guard petting.feed(x: point.x, at: ProcessInfo.processInfo.systemUptime) else { return }
        react(.blissful, for: Self.blissSeconds)
        spawnHearts(count: 3)
        play(.giggle)
        model.quip = quips.next(for: .petted)
    }

    // MARK: Head pats

    /// The cursor moved to `point`. Only a hand actually moving across the head pats; a cursor resting there doesn't.
    private func headPat(at point: CGPoint, onHead: Bool) {
        guard onHead else {
            patting.reset()
            patsInARow = 0
            return
        }
        guard patting.feed(point, at: ProcessInfo.processInfo.systemUptime) else { return }
        pats += 1
        patsInARow += 1
        react(.blissful, for: 1.1)
        play(.pat)
        if patsInARow % 2 == 0 { spawnHearts(count: 1) }
        let now = ProcessInfo.processInfo.systemUptime
        if patsInARow >= 3, now - lastPurr > 2.5 {
            lastPurr = now
            play(.purr)
        }
        if patsInARow == 3 { model.quip = quips.next(for: .headPats) }
    }

    // MARK: Clicking

    /// A click on Lash: a poke — or, right after another click, a spin.
    func tapped() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTap < Self.doubleClickWindow {
            lastTap = -.infinity
            spin()
        } else {
            lastTap = now
            poke()
        }
    }

    /// A happy spin with a hop.
    func spin() {
        spins += 1
        react(.blissful, for: 0.9)
        play(.wheee)
        model.quip = quips.next(for: .spun)
    }

    // MARK: Napping

    /// Checks for a nap `napAfter` after the cursor last moved (one timer at a time, never per-frame).
    private func scheduleNapCheck() {
        guard napTimer == nil else { return }
        let due = max(1, Self.napAfter - (ProcessInfo.processInfo.systemUptime - lastCursorActivity))
        let timer = Timer(timeInterval: due, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.napTimer = nil
            let still = ProcessInfo.processInfo.systemUptime - self.lastCursorActivity
            guard still >= Self.napAfter else { return self.scheduleNapCheck() }
            self.napIfQuiet()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        napTimer = timer
    }

    /// Dozes off if nothing is going on: no reaction, the island idle, and the user not working.
    func napIfQuiet() {
        guard !isNapping, reaction == nil, model.phase == .idle, !model.streakAdvancing else { return }
        isNapping = true
        reactionReset?.cancel()
        withAnimation(.easeInOut(duration: 0.6)) { reaction = .mood(.sleepy) }
    }

    private func wake(quietly: Bool) {
        guard isNapping else { return }
        isNapping = false
        guard !quietly else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { reaction = nil }
            return
        }
        squishes += 1
        react(.mood(.curious), for: 1.4)
        play(.boop)
        model.quip = quips.next(for: .wokeUp)
    }

    /// Lash says something about `topic` (sets `model.quip`; the controller clears it after a few seconds).
    func say(_ topic: QuipTopic) {
        model.quip = quips.next(for: topic)
    }

    private func react(_ expression: LashExpression, for seconds: TimeInterval) {
        reactionReset?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { reaction = expression }
        let reset = DispatchWorkItem { [weak self] in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { self?.reaction = nil }
        }
        reactionReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: reset)
    }

    private func spawnHearts(count: Int) {
        let now = Date().timeIntervalSinceReferenceDate
        for i in 0..<count {
            nextHeartID += 1
            // Fan the hearts out left, middle, right (with some wobble) so they never clump.
            let lane = count > 1 ? CGFloat(i) / CGFloat(count - 1) * 2 - 1 : 0
            let drift = max(-1, min(1, lane * 0.8 + .random(in: -0.2...0.2)))
            hearts.append(HeartPuff(id: nextHeartID, born: now + Double(i) * 0.12, drift: drift))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + HeartPuff.lifetime + Double(count) * 0.12) { [weak self] in
            let cutoff = Date().timeIntervalSinceReferenceDate - HeartPuff.lifetime
            self?.hearts.removeAll { $0.born < cutoff }
        }
    }

    private func play(_ sfx: SFX) {
        guard model.soundEnabled else { return }
        SoundBoard.shared.play(sfx)
    }
}
