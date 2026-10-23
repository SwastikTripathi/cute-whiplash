import AppKit
import Combine

/// Something that can stage a punishment: OverlayController in the app, a fake in tests.
protocol PunishmentPresenting: AnyObject {
    var isActive: Bool { get }
    /// `onBeat` reports the show's big moments as they happen; `completion` runs once the overlay is gone.
    func run(plan: PunishmentPlan, on screen: NSScreen, anchor: CGPoint, onBeat: @escaping (PunishmentBeat) -> Void,
             completion: @escaping () -> Void)
    func dismiss()
}

extension OverlayController: PunishmentPresenting {}

/// The app's brain. Owns the subsystems, mirrors the work-session tracker into the island model, nudges for a break,
/// runs the warning countdown, stages punishments and keeps score. Every method runs on the main thread.
///
/// `init` only wires things up (no windows, no timers, no status item), so tests can build a coordinator with a
/// fake clock and a fake presenter and drive it through the `handle…`/`…DidChange` entry points. `start()` puts
/// the app on screen.
final class AppCoordinator {
    /// Everything the coordinator depends on that a test may want to replace.
    struct Environment {
        var settings: Settings = .shared
        /// Where the daily whip tally is kept.
        var defaults: UserDefaults = .standard
        var scheduler: TimerScheduling = MainRunLoopScheduler()
        var now: () -> Date = Date.init
        var calendar: Calendar = .current
        var sound: SoundPlaying = SoundBoard.shared
        /// nil: a real OverlayController.
        var presenter: PunishmentPresenting?
        /// Screen Recording: macOS privacy, System Settings, relaunching.
        var screenCapture: ScreenCaptureAccess.System = .live
        /// Warms up the text recognizer (see `TextHarvester.prewarm`).
        var prewarmText: () -> Void = { TextHarvester.prewarm() }
    }

    static let countdownSeconds = 5
    static let aftermathSeconds: TimeInterval = 4
    /// `--whip-now` / `--grab` wait this long after launch, so you can see it coming…
    static let launchActionDelay: TimeInterval = 2
    /// …plus, while the text recognizer is still warming up (see `TextHarvester.prewarm`), up to this much longer, so
    /// the letters can fall.
    static let launchWarmUpLimit: TimeInterval = 25
    /// How long Lash laughs its hardest after the glass shatters.
    static let bigLaughSeconds: TimeInterval = 1.6
    /// While a terminal ticks, the tally is re-read at most this often.
    static let slowRefreshInterval: TimeInterval = 5

    let settings: Settings
    let model = IslandModel()
    let notch: NotchController
    let tracker: WorkSessionTracker
    let overlay: PunishmentPresenting
    let screenCapture: ScreenCaptureAccess
    let options: LaunchOptions

    /// Seconds left on the warning countdown; nil when none is running.
    private(set) var countdownSecondsLeft: Int?
    /// Seconds left of Lash's "stretch break?" nudge before the countdown starts; nil when not nudging.
    private(set) var nudgeSecondsLeft: Int?

    private let scheduler: TimerScheduling
    private let now: () -> Date
    private let calendar: Calendar
    private let sound: SoundPlaying
    private let tally: WhipTally
    private let defaults: UserDefaults
    private let prewarmText: () -> Void
    private var rng = SystemRandomNumberGenerator()
    private var statusMenu: StatusMenuController?
    private var subscriptions = Set<AnyCancellable>()
    private var countdownTimer: AnyCancellable?
    private var nudgeTimer: AnyCancellable?
    private var aftermathTimer: AnyCancellable?
    private var laughTimer: AnyCancellable?
    private var snoozeTimer: AnyCancellable?
    private var launchTimers: [AnyCancellable] = []
    /// A screenshot is being taken for a punishment that is about to start.
    private var isPreparingStage = false
    /// The threshold fired while the user was busy with the whip; honour it once they are done.
    private var pendingThreshold = false
    private var lastSlowRefresh = Date.distantPast
    private var lastTaunt: String?
    /// The Screen Recording flow has started (tests drive a coordinator that never starts): from now on a grant is
    /// news, and warms up the text recognizer.
    private var screenCaptureStarted = false
    private var escapeMonitor: Any?

    init(options: LaunchOptions, environment: Environment = Environment()) {
        self.options = options
        settings = environment.settings
        scheduler = environment.scheduler
        now = environment.now
        calendar = environment.calendar
        sound = environment.sound
        tally = WhipTally(defaults: environment.defaults, calendar: environment.calendar, now: environment.now)
        defaults = environment.defaults
        tracker = WorkSessionTracker(settings: environment.settings)
        tracker.thresholdOverride = options.thresholdOverride
        notch = NotchController(model: model, settings: environment.settings)
        overlay = environment.presenter ?? OverlayController(settings: environment.settings)
        screenCapture = ScreenCaptureAccess(system: environment.screenCapture, scheduler: environment.scheduler,
                                            now: environment.now, defaults: environment.defaults)
        prewarmText = environment.prewarmText
        wireModelActions()
        bindState()
        refreshSlowState(force: true)
        assign(\.phase, restingPhase)
    }

    // MARK: - Lifecycle

    /// Puts Lash on screen and starts watching. Call once, from applicationDidFinishLaunching.
    func start() {
        sound.prepare()
        startScreenCapture()
        installEscapeFallback()
        statusMenu = StatusMenuController(coordinator: self)
        notch.show()
        tracker.start()
        if let until = settings.snoozedUntil {
            if until > now() { scheduleSnoozeEnd(at: until) } else { settings.snoozedUntil = nil }
        }
        setPhase(restingPhase)
        if options.whipNow { scheduleLaunchAction { [weak self] in self?.punish() } }
        if options.grabNow { scheduleLaunchAction { [weak self] in self?.grabWhip() } }
    }

    func stop() {
        screenCapture.stop()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        launchTimers.removeAll()
        cancelNudge()
        cancelCountdown()
        aftermathTimer = nil
        snoozeTimer = nil
        overlay.dismiss()
        tracker.stop()
        notch.hide()
        statusMenu = nil
    }

    // MARK: - State for the menu

    /// A countdown or a punishment (being prepared or on screen) is under way.
    var isBusy: Bool { isPunishing || countdownSecondsLeft != nil }
    var isPunishing: Bool { isPreparingStage || overlay.isActive }
    var isSnoozed: Bool { settings.snoozedUntil.map { $0 > now() } ?? false }

    /// What the island shows when nothing is happening.
    var restingPhase: IslandPhase {
        if let until = settings.snoozedUntil, until > now() { return .snoozed(until: until) }
        return settings.enabled ? .idle : .disabled
    }

    // MARK: - Work-session events

    /// Enough work without a break: Lash nudges first ("stretch break?"); ignoring the nudge brings the whip.
    func handleThresholdReached() {
        // Snoozed or switched off: nothing now; resuming re-arms the reminder (see `resume`, `toggleAutoWhip`).
        guard settings.enabled, !isSnoozed else { return }
        guard nudgeSecondsLeft == nil, countdownSecondsLeft == nil else { return }
        guard !isPunishing else {
            pendingThreshold = true
            return
        }
        startNudge()
    }

    /// A real break (no input for `breakSeconds`, or asleep / locked that long): a fresh start.
    func handleBreakTaken() {
        assign(\.escalationLevel, 0)
        pendingThreshold = false
    }

    /// The user stepped away from the keyboard: during the nudge or the countdown that's them taking the hint.
    func awayDidChange(_ away: Bool) {
        guard away, nudgeSecondsLeft != nil || countdownSecondsLeft != nil else { return }
        cancelNudge()
        cancelCountdown()
        setPhase(restingPhase)
        model.quip = WhiplashLines.heeded
        // A few seconds away isn't a break yet: unless it becomes one, remind again after a while.
        tracker.remind(after: settings.repeatSeconds)
    }

    /// The frontmost terminal changed; nil means no terminal is in front (the work clock doesn't care).
    func terminalDidChange(_ terminal: TerminalApp?) {
        assign(\.terminalName, terminal?.name)
        refreshSlowState(force: true)
        statusMenu?.refreshIfOpen()
    }

    func workDidChange(_ seconds: TimeInterval) {
        assign(\.streakSeconds, seconds)
        if Int(seconds) > Int(settings.longestStreakSeconds) {
            settings.longestStreakSeconds = seconds.rounded(.down)
        }
        refreshSlowState(force: false)
        statusMenu?.refreshIfOpen()
    }

    // MARK: - Actions

    /// Punish right now, skipping the countdown (also where the countdown ends up).
    func punish() {
        stage(manual: false)
    }

    /// Manual mode: hand the whip to the user.
    func grabWhip() {
        guard !isBusy else {
            model.quip = WhiplashLines.busy
            return
        }
        stage(manual: true)
    }

    func snooze(for duration: TimeInterval) {
        guard duration > 0 else { return }
        let until = now().addingTimeInterval(duration)
        settings.snoozedUntil = until
        cancelNudge()
        cancelCountdown()
        pendingThreshold = false
        scheduleSnoozeEnd(at: until)
        if !isPunishing { setPhase(.snoozed(until: until)) }
        model.quip = WhiplashLines.snoozed
    }

    /// "Spare me this once": the work timer starts over and any nudge or countdown is called off, no whip. The next
    /// reminder comes after a full threshold of work.
    func spareOnce() {
        cancelNudge()
        cancelCountdown()
        pendingThreshold = false
        tracker.resetWork()
        if !isPunishing, model.phase != .aftermath { setPhase(restingPhase) }
        model.quip = WhiplashLines.spared
    }

    /// Snooze until midnight.
    func snoozeRestOfDay() {
        let today = calendar.startOfDay(for: now())
        let midnight = calendar.date(byAdding: .day, value: 1, to: today) ?? now().addingTimeInterval(86_400)
        snooze(for: midnight.timeIntervalSince(now()))
    }

    func resume() {
        snoozeTimer = nil
        settings.snoozedUntil = nil
        // Back on duty: if a reminder is overdue, the nudge comes right away.
        tracker.rearm()
        if !isPunishing, model.phase != .aftermath { setPhase(restingPhase) }
        model.quip = WhiplashLines.resumed
    }

    func toggleSound() {
        // `--mute` wins for this session; don't quietly flip the saved setting behind the (unchanging) button.
        guard !options.mute else {
            say(WhiplashLines.muted)
            return
        }
        settings.soundEnabled.toggle()
    }

    func toggleAutoWhip() {
        settings.enabled.toggle()
        if settings.enabled {
            tracker.rearm()
        } else {
            pendingThreshold = false
            cancelNudge()
            cancelCountdown()
        }
        if !isPunishing, model.phase != .aftermath { setPhase(restingPhase) }
        model.quip = settings.enabled ? WhiplashLines.armed : WhiplashLines.holstered
    }

    /// Sets the terminal time limit, replacing any `--threshold` override for this session.
    func setThreshold(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        tracker.thresholdOverride = nil
        settings.thresholdSeconds = seconds
        assign(\.thresholdSeconds, tracker.effectiveThreshold)
        statusMenu?.refreshIfOpen()
    }

    func setIntensity(_ value: Double) {
        settings.intensity = min(2, max(0.5, value))
    }

    /// "Enable real shattering": turns the setting on and does whatever it takes to get Screen Recording (see
    /// `ScreenCaptureAccess.enable`).
    func requestScreenCapture() {
        settings.useScreenCapture = true
        if screenCapture.isGranted { prewarmTextRecognition() } else { screenCapture.enable() }
        statusMenu?.refreshIfOpen()
    }

    /// The menu's "Real Screen Shattering": ask for permission, or toggle using it once granted.
    func toggleRealShattering() {
        if screenCapture.isGranted {
            settings.useScreenCapture.toggle()
            prewarmTextRecognition()
        } else {
            requestScreenCapture()
        }
    }

    /// "Relaunch": a fresh process picks up a Screen Recording grant this one can't see. Never mid-punishment.
    func relaunchForScreenCapture() {
        guard !isBusy else {
            say(WhiplashLines.busy)
            return
        }
        screenCapture.relaunch()
    }

    /// Re-reads everything that may have changed behind our back; the menu calls it as it opens.
    func refreshForDisplay() {
        screenCapture.recheck()
        refreshSlowState(force: true)
    }

    /// Esc while the overlay is up but some other window of ours has the keyboard (say Whiplash was made the active
    /// app and the island is key): leave anyway. The overlay handles its own Esc. Returns whether the key was used.
    func handleEscape(inOverlay: Bool) -> Bool {
        guard overlay.isActive, !inOverlay else { return false }
        overlay.dismiss()
        return true
    }

    /// Puts a line in Lash's speech bubble.
    func say(_ line: String) {
        model.quip = line
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Nudge

    private func startNudge() {
        let seconds = max(1, Int(settings.nudgeSeconds.rounded()))
        nudgeSecondsLeft = seconds
        setPhase(.nudge(secondsLeft: seconds))
        say(from: WhiplashLines.nudges)
        sound.play(.boop, intensity: 0.8, pan: 0)
        scheduleNudgeTick()
    }

    private func scheduleNudgeTick() {
        nudgeTimer = scheduler.schedule(after: 1) { [weak self] in self?.nudgeTick() }
    }

    private func nudgeTick() {
        guard let left = nudgeSecondsLeft else { return }
        guard left > 1 else {
            cancelNudge()
            startCountdown()
            return
        }
        nudgeSecondsLeft = left - 1
        setPhase(.nudge(secondsLeft: left - 1))
        scheduleNudgeTick()
    }

    private func cancelNudge() {
        nudgeTimer = nil
        nudgeSecondsLeft = nil
    }

    // MARK: - Countdown

    private func startCountdown() {
        countdownSecondsLeft = Self.countdownSeconds
        setPhase(.warning(secondsLeft: Self.countdownSeconds))
        say(from: WhiplashLines.warnings)
        sound.play(.alarm, intensity: 1, pan: 0)
        scheduleCountdownTick()
    }

    private func scheduleCountdownTick() {
        countdownTimer = scheduler.schedule(after: 1) { [weak self] in self?.countdownTick() }
    }

    private func countdownTick() {
        guard let left = countdownSecondsLeft else { return }
        guard left > 1 else {
            cancelCountdown()
            punish()
            return
        }
        countdownSecondsLeft = left - 1
        setPhase(.warning(secondsLeft: left - 1))
        // Ticks get louder as the whip gets closer.
        sound.play(.tick, intensity: 0.6 + 0.1 * Float(Self.countdownSeconds - left + 1), pan: 0)
        scheduleCountdownTick()
    }

    private func cancelCountdown() {
        countdownTimer = nil
        countdownSecondsLeft = nil
    }

    // MARK: - Launch

    /// Real shattering is on and not disabled for this session.
    private var wantsScreenCapture: Bool { settings.useScreenCapture && !options.noCapture }

    /// Screen capture is on, allowed and permitted: punishments shatter a real screenshot and OCR its text.
    private var capturesScreen: Bool { wantsScreenCapture && screenCapture.isGranted }

    /// Part of `start()`: checks Screen Recording and, if it's missing and macOS was never asked about this build,
    /// asks right away so real shattering enables itself. Once granted, now or later, the text recognizer warms up.
    func startScreenCapture() {
        screenCaptureStarted = true
        screenCapture.onChange = { [weak self] in self?.screenCaptureDidChange() }
        screenCapture.canRelaunch = { [weak self] in self.map { !$0.isBusy } ?? false }
        screenCapture.launch(wantsCapture: wantsScreenCapture)
        if screenCapture.isAwaitingGrant { say(WhiplashLines.screenAsked) }
    }

    private func screenCaptureDidChange() {
        let wasGranted = model.screenCaptureGranted
        assign(\.screenCaptureGranted, screenCapture.isGranted)
        assign(\.screenCaptureRelaunchOffered, screenCapture.offersRelaunch)
        if screenCapture.isGranted, !wasGranted {
            prewarmTextRecognition()
            // At launch the grant is old news; later it means the user just switched us on.
            if screenCapture.hasLaunched { say(WhiplashLines.screenGranted) }
        }
        statusMenu?.refreshIfOpen()
    }

    /// Warms up Vision's text recognizer as soon as a punishment could use it, so the first one's letters fall.
    private func prewarmTextRecognition() {
        guard screenCaptureStarted, capturesScreen else { return }
        prewarmText()
    }

    /// Runs a `--whip-now` / `--grab` action after the launch delay — and, if the text recognizer is still warming
    /// up by then, once it is warm (at most `launchWarmUpLimit` later).
    private func scheduleLaunchAction(_ action: @escaping () -> Void) {
        launchTimers.append(scheduler.schedule(after: Self.launchActionDelay) { [weak self] in
            guard let self else { return }
            guard self.capturesScreen, !TextHarvester.isWarm else { return action() }
            self.say(WhiplashLines.warmingUp)
            var done = false
            let go = {
                guard !done else { return }
                done = true
                action()
            }
            TextHarvester.prewarm(then: go)
            self.launchTimers.append(self.scheduler.schedule(after: Self.launchWarmUpLimit, go))
        })
    }

    // MARK: - Staging

    private func stage(manual: Bool) {
        guard !isPunishing else { return }
        cancelNudge()
        cancelCountdown()
        aftermathTimer = nil
        let terminalFrame = frontWindowFrame()
        let terminalScreen = Self.screen(showingMostOf: terminalFrame)
        // The manual whip goes where the hand is: the screen with the cursor (it takes that screen's mouse).
        let mouseScreen = manual ? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } : nil
        guard let screen = mouseScreen ?? terminalScreen ?? notch.screen ?? NSScreen.main else {
            tracker.remind(after: settings.repeatSeconds)
            setPhase(restingPhase)
            return
        }
        isPreparingStage = true
        setPhase(manual ? .manual : .whipping)
        if manual { say(from: WhiplashLines.grabbed) }
        let anchor = notch.whipAnchor(on: screen, manual: manual)
        let target = terminalFrame.flatMap { screen.frame.intersects($0) ? $0 : nil }
        let present: (ScreenSnapshot?) -> Void = { [weak self] backdrop in
            self?.present(manual: manual, on: screen, anchor: anchor, target: target, backdrop: backdrop)
        }
        // Only with the grant on record: a capture without it could bring up a system prompt mid-punishment.
        if capturesScreen {
            Task {
                let snapshot = await ScreenGrabber.capture(screen: screen)
                DispatchQueue.main.async { present(snapshot) }
            }
        } else {
            present(nil)
        }
    }

    private func present(manual: Bool, on screen: NSScreen, anchor: CGPoint, target: CGRect?, backdrop: ScreenSnapshot?) {
        isPreparingStage = false
        let taunt = WhiplashLines.pick(from: WhiplashLines.taunts, avoiding: lastTaunt, using: &rng)
        lastTaunt = taunt
        if !manual { assign(\.breakTaunt, taunt) }
        let plan = PunishmentPlanner.plan(escalationLevel: model.escalationLevel, settings: settings, targetRect: target,
                                          backdrop: backdrop, message: taunt, isManual: manual)
        overlay.run(plan: plan, on: screen, anchor: anchor, onBeat: { [weak self] beat in
            self?.punishmentBeat(beat, manual: manual)
        }, completion: { [weak self] in
            if manual { self?.manualDidFinish() } else { self?.punishmentDidFinish() }
        })
    }

    /// The island plays along with the show: Lash laughs its hardest as the glass shatters, and turns smug as the
    /// screen rewinds (the whip is already back in the pill by then).
    func punishmentBeat(_ beat: PunishmentBeat, manual: Bool) {
        switch beat {
        case .shatter:
            assign(\.laughingHard, true)
            laughTimer = scheduler.schedule(after: Self.bigLaughSeconds) { [weak self] in
                self?.assign(\.laughingHard, false)
            }
        case .breakLeft(let seconds):
            assign(\.breakSecondsLeft, seconds)
        case .reassemble:
            laughTimer = nil
            assign(\.laughingHard, false)
            endBreak()
            guard !manual, model.phase == .whipping else { return }
            setPhase(.aftermath)
            say(from: WhiplashLines.aftermath)
        }
    }

    /// The screen is coming back: the island stops counting down.
    private func endBreak() {
        assign(\.breakSecondsLeft, nil)
        assign(\.breakTaunt, nil)
    }

    private func punishmentDidFinish() {
        endBreak()
        settings.totalWhips += 1
        assign(\.whipsToday, tally.increment())
        assign(\.escalationLevel, model.escalationLevel + 1)
        // Still no real break: remind again after a while (and harsher), unless a break comes first.
        tracker.remind(after: settings.repeatSeconds)
        pendingThreshold = false
        laughTimer = nil
        assign(\.laughingHard, false)
        if model.phase != .aftermath {
            setPhase(.aftermath)
            say(from: WhiplashLines.aftermath)
        }
        aftermathTimer = scheduler.schedule(after: Self.aftermathSeconds) { [weak self] in
            guard let self, self.model.phase == .aftermath else { return }
            self.setPhase(self.restingPhase)
        }
    }

    private func manualDidFinish() {
        endBreak()
        laughTimer = nil
        assign(\.laughingHard, false)
        setPhase(restingPhase)
        say(from: WhiplashLines.returned)
        if pendingThreshold {
            pendingThreshold = false
            handleThresholdReached()
        }
    }

    /// The window in front (any app: the reminder is about your work, wherever it is).
    private func frontWindowFrame() -> CGRect? {
        guard let pid = tracker.frontmostPID, pid != getpid() else { return nil }
        return TerminalWindowLocator.frontWindowFrame(pid: pid)
    }

    /// The screen showing the largest part of `rect` (Cocoa global).
    static func screen(showingMostOf rect: CGRect?) -> NSScreen? {
        guard let rect else { return nil }
        let overlaps = NSScreen.screens.map { ($0, $0.frame.intersection(rect)) }.filter { !$0.1.isNull }
        return overlaps.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    // MARK: - Snooze

    private func scheduleSnoozeEnd(at until: Date) {
        snoozeTimer = scheduler.schedule(after: until.timeIntervalSince(now())) { [weak self] in self?.resume() }
    }

    // MARK: - Model plumbing

    private func wireModelActions() {
        model.onWhipNow = { [weak self] in self?.punish() }
        model.onGrabWhip = { [weak self] in self?.grabWhip() }
        model.onSnooze = { [weak self] in self?.snooze(for: $0) }
        model.onResume = { [weak self] in self?.resume() }
        model.onSpareOnce = { [weak self] in self?.spareOnce() }
        model.onToggleSound = { [weak self] in self?.toggleSound() }
        model.onToggleAutoWhip = { [weak self] in self?.toggleAutoWhip() }
        model.onRequestScreenCapture = { [weak self] in self?.requestScreenCapture() }
        model.onRelaunch = { [weak self] in self?.relaunchForScreenCapture() }
        model.onSetThreshold = { [weak self] in self?.setThreshold($0) }
        model.onQuit = { [weak self] in self?.quit() }
    }

    private func bindState() {
        tracker.onThresholdReached = { [weak self] in self?.handleThresholdReached() }
        tracker.onBreakTaken = { [weak self] in self?.handleBreakTaken() }
        // @Published emits the new value on willSet: always use the value handed in, never re-read the property.
        tracker.$frontmostTerminal.sink { [weak self] in self?.terminalDidChange($0) }.store(in: &subscriptions)
        tracker.$workSeconds.sink { [weak self] in self?.workDidChange($0) }.store(in: &subscriptions)
        tracker.$isAccruing.sink { [weak self] in self?.assign(\.streakAdvancing, $0) }.store(in: &subscriptions)
        tracker.$isAway.sink { [weak self] in self?.awayDidChange($0) }.store(in: &subscriptions)
        settings.$thresholdSeconds.sink { [weak self] seconds in
            guard let self else { return }
            self.assign(\.thresholdSeconds, self.tracker.thresholdOverride ?? seconds)
        }.store(in: &subscriptions)
        settings.$soundEnabled.sink { [weak self] enabled in
            guard let self else { return }
            let audible = enabled && !self.options.mute
            self.sound.enabled = audible
            self.assign(\.soundEnabled, audible)
        }.store(in: &subscriptions)
        settings.$enabled.sink { [weak self] in self?.assign(\.autoWhipEnabled, $0) }.store(in: &subscriptions)
        settings.$totalWhips.sink { [weak self] in self?.assign(\.totalWhips, $0) }.store(in: &subscriptions)
        settings.$longestStreakSeconds.sink { [weak self] in self?.assign(\.longestStreakSeconds, $0) }.store(in: &subscriptions)
    }

    private func setPhase(_ phase: IslandPhase) {
        assign(\.phase, phase)
        refreshSlowState(force: true)
        statusMenu?.refreshIfOpen()
    }

    /// Re-reads the day's tally (it rolls over at midnight). The Screen Recording permission is ScreenCaptureAccess's
    /// business: it reports changes through `screenCaptureDidChange`.
    private func refreshSlowState(force: Bool) {
        let time = now()
        guard force || time.timeIntervalSince(lastSlowRefresh) >= Self.slowRefreshInterval else { return }
        lastSlowRefresh = time
        assign(\.whipsToday, tally.today)
    }

    /// See `handleEscape(inOverlay:)`. Local monitors only see keys sent to Whiplash, never the terminal's.
    private func installEscapeFallback() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode, let self,
                  self.handleEscape(inOverlay: event.window is OverlayPanel) else { return event }
            return nil
        }
    }

    private static let escapeKeyCode: UInt16 = 53

    private func say(from lines: [String]) {
        model.quip = WhiplashLines.pick(from: lines, avoiding: model.quip, using: &rng)
    }

    /// Writes to the model only on change, so an idle island is never asked to re-render.
    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<IslandModel, Value>, _ value: Value) {
        if model[keyPath: keyPath] != value { model[keyPath: keyPath] = value }
    }
}
