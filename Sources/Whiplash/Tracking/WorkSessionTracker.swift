import AppKit
import Combine
import CoreGraphics

/// A terminal emulator that is currently frontmost.
struct TerminalApp: Equatable {
    let name: String
    let bundleID: String
    let pid: pid_t
}

/// Measures how long you have been working since your last real break, for terminal-heavy work.
///
/// Rules (see Settings):
/// * **Work** is time you are actively using the Mac — input within `idlePauseSeconds` — in any app, as long as a
///   terminal (`terminalBundleIDs`) was in active use within `terminalRecencySeconds`. Reading docs between commands
///   counts; an afternoon with no terminal doesn't. Short idle moments (watching a build) only pause it.
/// * **A real break** resets it to 0: no input for `breakSeconds`, or sleep / a locked screen / a switched-out session
///   lasting that long. Switching apps never resets it.
/// * **Reminders**: `onThresholdReached` fires once when work crosses the threshold. After that it only fires again
///   once re-armed with `remind(after:)` (the coordinator does so after a whip, or after a heeded nudge) — or after
///   a real break, when it re-arms at the threshold.
///
/// All callbacks and @Published changes happen on the main thread.
/// Cost: a 1 Hz timer, running only while a session is open (a terminal in front, work on the clock, or a terminal
/// used recently) — never while the Mac just sits there after a break.
final class WorkSessionTracker: ObservableObject {
    @Published private(set) var frontmostTerminal: TerminalApp?
    /// Work since the last real break. Updated at most once per tick (1 Hz), plus immediately on a break.
    @Published private(set) var workSeconds: TimeInterval = 0
    /// The longest session seen since launch.
    @Published private(set) var longestSession: TimeInterval = 0
    /// Work is on the clock right now.
    @Published private(set) var isAccruing = false
    /// The user has stepped away: no input for `stepAwaySeconds` (a break may be starting).
    @Published private(set) var isAway = false

    var onThresholdReached: (() -> Void)?
    /// A real break just ended the session (work went back to 0).
    var onBreakTaken: (() -> Void)?
    /// Session-only override of settings.thresholdSeconds (from --threshold).
    var thresholdOverride: TimeInterval?
    var effectiveThreshold: TimeInterval { thresholdOverride ?? settings.thresholdSeconds }
    /// Work time at which the next reminder is due.
    var nextReminderAt: TimeInterval { repeatAt ?? effectiveThreshold }
    /// The frontmost app's process (any app), e.g. to find the window to aim at.
    var frontmostPID: pid_t? { activeApp?.pid }

    /// Why accounting is suspended. The tracker runs only while this set is empty.
    enum PauseReason: Hashable {
        case stopped, systemSleep, displaySleep, sessionInactive, screenLocked

        static let system: Set<PauseReason> = [.systemSleep, .displaySleep, .sessionInactive, .screenLocked]
    }

    static let tickInterval: TimeInterval = 1
    /// Most wall time one tick may add, so a stalled timer or a missed sleep notification can't add a big jump.
    static let maxTickContribution: TimeInterval = 2
    /// Recent input within this many seconds, plus an app switch, proves the session is awake (see `handleActivation`).
    static let activityEvidenceSeconds: TimeInterval = 5
    private static let loginWindowBundleID = "com.apple.loginwindow"
    /// kCGAnyInputEventType: keyboard, mouse, trackpad, tablet.
    private static let anyInputEvent = CGEventType(rawValue: ~0)!

    private let settings: Settings
    private let now: () -> Date
    private let idleSeconds: () -> TimeInterval
    /// Production trackers hook into NSWorkspace and run a timer; test trackers are driven by hand.
    private let isLive: Bool

    private struct ActiveApp {
        let bundleID: String?
        let name: String?
        let pid: pid_t
    }

    private var activeApp: ActiveApp?
    private var terminalBundleIDs: Set<String> = []
    private var pauses: Set<PauseReason> = [.stopped]
    /// Precise work time; `workSeconds` is its published copy.
    private var work: TimeInterval = 0
    /// Last time accounted up to; nil before the first tick of a run.
    private var lastSample: Date?
    /// Last time a terminal was frontmost while the user was active.
    private var lastTerminalUse: Date?
    /// When the current system pause (sleep, lock…) began.
    private var pausedAt: Date?
    /// After `remind(after:)`: the work time of the next reminder (nil: the threshold).
    private var repeatAt: TimeInterval?
    private var reminderArmed = true

    private var timer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var bundleIDsSubscription: AnyCancellable?

    /// Uses the real clock, the real idle time and (after `start()`) NSWorkspace notifications and a timer.
    convenience init(settings: Settings) {
        self.init(settings: settings, now: { Date() }, idleSeconds: WorkSessionTracker.systemIdleSeconds, isLive: true)
    }

    /// A hand-driven tracker for tests and demos: no system hooks and no timer. Feed it with
    /// `handleActivation(bundleID:name:pid:)`, `pause(_:)`/`resume(_:)` and `tick()`.
    convenience init(settings: Settings, now: @escaping () -> Date, idleSeconds: @escaping () -> TimeInterval) {
        self.init(settings: settings, now: now, idleSeconds: idleSeconds, isLive: false)
    }

    private init(settings: Settings, now: @escaping () -> Date, idleSeconds: @escaping () -> TimeInterval, isLive: Bool) {
        self.settings = settings
        self.now = now
        self.idleSeconds = idleSeconds
        self.isLive = isLive
        // @Published emits before the property changes, so use the emitted list rather than re-reading settings.
        bundleIDsSubscription = settings.$terminalBundleIDs.sink { [weak self] ids in
            self?.terminalBundleIDsChanged(ids)
        }
    }

    deinit {
        timer?.invalidate()
        removeObservers()
    }

    /// Seconds since the last keyboard/mouse/trackpad input in this login session.
    static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }

    // MARK: - Public API

    func start() {
        guard pauses.contains(.stopped) else { return }
        if isLive {
            installObservers()
            refreshActiveApp()
        }
        resume([.stopped])
    }

    func stop() {
        guard !pauses.contains(.stopped) else { return }
        pause(.stopped)
        // Nothing observes the system while stopped, so forget its pauses; start() re-reads the world.
        pauses = [.stopped]
        pausedAt = nil
        removeObservers()
    }

    /// Re-arms the reminder: it fires again after `seconds` more work (unless a real break comes first).
    func remind(after seconds: TimeInterval) {
        repeatAt = work + max(1, seconds)
        reminderArmed = true
        checkThreshold()
    }

    /// "Spare me this once": the work clock goes back to 0 and the next reminder is a full threshold away. Unlike a
    /// real break, the session carries on (you're still at the terminal), so it counts up again from here.
    func resetWork() {
        work = 0
        repeatAt = nil
        reminderArmed = true
        publish()
    }

    /// Re-arms the reminder where it stands (e.g. after a snooze): if it is already due, it fires right away.
    func rearm() {
        reminderArmed = true
        checkThreshold()
    }

    // MARK: - Driving (NSWorkspace in production, tests by hand)

    /// Accounts the time since the previous tick. Called by the 1 Hz timer.
    func tick() {
        guard pauses.isEmpty else { return }
        advance(to: now())
    }

    /// The app with `bundleID` became frontmost.
    func handleActivation(bundleID: String?, name: String?, pid: pid_t) {
        activeApp = ActiveApp(bundleID: bundleID, name: name, pid: pid)
        // Someone switching apps with fresh input proves the session is awake, even if a wake/unlock
        // notification got lost — never stay paused forever.
        if !pauses.isDisjoint(with: PauseReason.system), bundleID != Self.loginWindowBundleID,
           idleSeconds() < Self.activityEvidenceSeconds {
            resume(PauseReason.system)
            return
        }
        guard pauses.isEmpty else { return }
        advance(to: now())
    }

    func pause(_ reason: PauseReason) {
        let wasRunning = pauses.isEmpty
        pauses.insert(reason)
        guard wasRunning else { return }
        let t = now()
        account(until: t)
        pausedAt = t
        if frontmostTerminal != nil { frontmostTerminal = nil }
        publish()
        updateTimer()
    }

    func resume(_ reasons: Set<PauseReason>) {
        guard !pauses.isDisjoint(with: reasons) else { return }
        pauses.subtract(reasons)
        guard pauses.isEmpty else { return }
        let t = now()
        // Asleep / locked long enough is a real break.
        if let since = pausedAt, t.timeIntervalSince(since) >= settings.breakSeconds { takeBreak() }
        pausedAt = nil
        lastSample = t
        advance(to: t)
    }

    /// Whether the 1 Hz timer is (or, for hand-driven trackers, would be) running.
    var needsTicks: Bool {
        pauses.isEmpty && (frontmostTerminal != nil || work > 0 || lastTerminalUse != nil)
    }

    // MARK: - Accounting

    private func advance(to t: Date) {
        frontmostTerminalChanged(currentTerminal())
        account(until: t)
        publish()
        checkThreshold()
        updateTimer()
    }

    /// Adds the work since the last sample, notices breaks and terminal use.
    private func account(until t: Date) {
        let idle = idleSeconds()
        let active = idle <= settings.idlePauseSeconds
        defer { lastSample = t }
        if frontmostTerminal != nil, active { lastTerminalUse = t }
        let away = idle >= settings.stepAwaySeconds
        if isAway != away { isAway = away }
        if idle >= settings.breakSeconds {
            takeBreak()
            return
        }
        guard active, let last = lastSample, let used = lastTerminalUse,
              t.timeIntervalSince(used) <= settings.terminalRecencySeconds else { return }
        work += min(max(0, t.timeIntervalSince(last)), Self.maxTickContribution)
    }

    /// A real break: the session ends; the next one starts with the next terminal use.
    private func takeBreak() {
        let hadSession = work > 0 || repeatAt != nil
        work = 0
        repeatAt = nil
        reminderArmed = true
        lastTerminalUse = nil
        publish()
        if hadSession { onBreakTaken?() }
    }

    private func checkThreshold() {
        // A 1 s floor keeps a zero/negative threshold from firing on every tick.
        guard reminderArmed, pauses.isEmpty, work >= max(1, nextReminderAt) else { return }
        reminderArmed = false
        onThresholdReached?()
    }

    private func publish() {
        if workSeconds != work { workSeconds = work }
        if work > longestSession { longestSession = work }
        let accruing = pauses.isEmpty && idleSeconds() <= settings.idlePauseSeconds
            && lastTerminalUse.map { now().timeIntervalSince($0) <= settings.terminalRecencySeconds } == true
        if isAccruing != accruing { isAccruing = accruing }
    }

    private func frontmostTerminalChanged(_ terminal: TerminalApp?) {
        if frontmostTerminal != terminal { frontmostTerminal = terminal }
    }

    private func currentTerminal() -> TerminalApp? {
        guard pauses.isEmpty, let app = activeApp, let id = app.bundleID, terminalBundleIDs.contains(id) else { return nil }
        return TerminalApp(name: app.name ?? id, bundleID: id, pid: app.pid)
    }

    private func terminalBundleIDsChanged(_ ids: [String]) {
        terminalBundleIDs = Set(ids)
        guard pauses.isEmpty else { return }
        advance(to: now())
    }

    // MARK: - System hooks (live trackers only)

    private func updateTimer() {
        guard isLive else { return }
        if needsTicks {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in self?.tick() }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refreshActiveApp() {
        activeApp = NSWorkspace.shared.frontmostApplication.map {
            ActiveApp(bundleID: $0.bundleIdentifier, name: $0.localizedName, pid: $0.processIdentifier)
        }
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleActivation(bundleID: app.bundleIdentifier, name: app.localizedName, pid: app.processIdentifier)
        }
        let pairs: [(down: Notification.Name, up: Notification.Name, reason: PauseReason)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive),
        ]
        for pair in pairs {
            observe(workspace, pair.down) { [weak self] _ in self?.pause(pair.reason) }
            observe(workspace, pair.up) { [weak self] _ in self?.systemResumed(pair.reason) }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] _ in self?.pause(.screenLocked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in self?.systemResumed(.screenLocked) }
    }

    /// Activations were not tracked while paused, so re-read the frontmost app before resuming.
    private func systemResumed(_ reason: PauseReason) {
        guard pauses.contains(reason) else { return }
        refreshActiveApp()
        resume([reason])
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main, using: handler)
        observers.append((center, token))
    }

    private func removeObservers() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}
