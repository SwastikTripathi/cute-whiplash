import AppKit
import Combine
import Security

/// Screen Recording ("real shattering") from start to finish. At launch it asks macOS once for each code identity.
/// After that it notices a grant made while Whiplash runs, clears a decision macOS won't let go of, and offers a
/// relaunch as a last resort. Every method runs on the main thread.
///
/// Why this takes more than `CGPreflightScreenCaptureAccess()`:
/// - **Preflight goes stale.** After the user switches Whiplash on in System Settings, preflight keeps answering
///   false for the rest of the process's life, although ScreenCaptureKit already works (Apple DTS on the forums;
///   measured on macOS 26.6). So once we have asked, we poll ScreenCaptureKit itself (`System.probe`).
/// - **Grants belong to a code identity.** macOS ties the grant to the app's designated requirement. An ad-hoc
///   signature changes it on every rebuild, and the old grant stays switched on in System Settings without matching
///   anything. A "Deny" can stick the same way. Only resetting our own record (`tccutil reset`) gets out of that, so
///   asking for a new identity, or asking again when the user clicks, starts with a reset.
/// - **Asking isn't free.** macOS may show its prompt again on each request, so we ask by ourselves only once per
///   identity. After that we ask only when the user clicks "Enable real shattering".
final class ScreenCaptureAccess {
    /// Everything that touches macOS privacy, the process or the workspace, so tests can replace it. Completions run
    /// on the main queue.
    struct System {
        /// `CGPreflightScreenCaptureAccess` (plus any grant a probe already proved). Costs ~10 ms.
        var preflight: () -> Bool
        /// `CGRequestScreenCaptureAccess`: shows macOS's prompt if macOS still wants to.
        var request: () -> Void
        /// Whether ScreenCaptureKit works right now. Prompts if macOS has no decision on record, so it's only called
        /// once we have asked for this identity.
        var probe: (@escaping (Bool) -> Void) -> Void
        /// Forgets macOS's decision about this app (`tccutil reset ScreenCapture <bundle id>`), so the next request
        /// prompts afresh; reports success.
        var resetDecision: (@escaping (Bool) -> Void) -> Void
        /// Opens System Settings › Privacy & Security › Screen & System Audio Recording.
        var openSettings: () -> Void
        /// Quits and starts a fresh copy of the app.
        var relaunch: () -> Void
        /// The running code's designated requirement, which macOS ties the grant to.
        var identity: () -> String?
        /// Running as Whiplash.app. A bare binary (`swift run`) borrows its terminal's permission, which isn't ours
        /// to ask for or reset.
        var isAppBundle: Bool
        /// Calls the handler whenever the user leaves or quits System Settings, until the token is released.
        var observeSettingsClosed: (@escaping () -> Void) -> AnyCancellable
    }

    /// While waiting for a grant, ScreenCaptureKit is probed this often…
    static let pollInterval: TimeInterval = 2
    /// …for at most this long after each request (or each return from System Settings).
    static let pollWindow: TimeInterval = 180
    /// System Settings is left right after flipping the switch; give the privacy daemon a moment to record it.
    static let settingsSettleDelay: TimeInterval = 1
    /// A probe that hasn't answered after this long (e.g. macOS is showing an alert) no longer blocks a new one.
    static let probeStaleAfter: TimeInterval = 30
    /// The code identity we last asked macOS about.
    static let requestedIdentityKey = "whiplash.screenCaptureRequestedIdentity"
    /// Before code identities were tracked, only whether we had ever asked was saved.
    static let legacyRequestedKey = "whiplash.didRequestScreenCapture"

    /// Screen Recording works: punishments shatter a real screenshot.
    private(set) var isGranted = false
    /// We asked in this session and are waiting for the user to switch Whiplash on.
    private(set) var isAwaitingGrant = false
    /// The user came back from System Settings and the grant still isn't visible. macOS may only apply it to a
    /// fresh process (it says so: "may not be able to record … until it is quit"), so a relaunch is offered.
    private(set) var offersRelaunch = false
    /// `launch` has run: a grant noticed from now on was made while Whiplash runs.
    private(set) var hasLaunched = false
    /// Any of the three above changed.
    var onChange: () -> Void = {}
    /// Whether quitting is fine right now (not in the middle of a punishment).
    var canRelaunch: () -> Bool = { true }

    private let system: System
    private let scheduler: TimerScheduling
    private let now: () -> Date
    private let defaults: UserDefaults
    private lazy var identity: String = system.identity() ?? "unsigned"
    private var askedThisSession = false
    private var pollTimer: AnyCancellable?
    private var pollsLeft = 0
    private var settleTimer: AnyCancellable?
    private var settingsObserver: AnyCancellable?
    private var probeStartedAt: Date?

    init(system: System, scheduler: TimerScheduling, now: @escaping () -> Date, defaults: UserDefaults) {
        self.system = system
        self.scheduler = scheduler
        self.now = now
        self.defaults = defaults
    }

    // MARK: - Entry points

    /// At launch. `wantsCapture`: real shattering is switched on and not disabled for this session. Then, if
    /// Screen Recording is missing and macOS has never been asked about this build's identity, asks now, so it
    /// enables itself without a click. Never asks twice for the same identity.
    func launch(wantsCapture: Bool) {
        isGranted = system.preflight()
        if isGranted {
            // If macOS 15+ wants the monthly "keep bypassing the private window picker?" confirmation, let it
            // ask now rather than when the first punishment takes its screenshot.
            probe { _ in }
        } else if wantsCapture, system.isAppBundle, !askedForThisIdentity {
            askAfresh()
        } else {
            watchSettings()
        }
        onChange()
        hasLaunched = true
    }

    /// "Enable real shattering": whatever it takes. Checks first, since a grant may already work unseen. Otherwise
    /// asks macOS again, or sends the user to System Settings if we already asked in this session.
    func enable() {
        guard !isGranted else { return }
        check { [weak self] works in
            guard let self, !works else { return }
            if self.askedThisSession {
                self.system.openSettings()
                self.watch()
            } else {
                self.askAfresh()
            }
            self.onChange()
        }
    }

    /// "Relaunch": a fresh process picks up a grant this one can't see. Checks first, in case it's visible after all.
    func relaunch() {
        guard !isGranted else { return }
        check { [weak self] works in
            guard let self, !works, self.canRelaunch() else { return }
            self.system.relaunch()
        }
    }

    /// Looks again (e.g. as the menu opens) if a grant could have arrived unseen.
    func recheck() {
        guard !isGranted, canProbe else { return }
        check { _ in }
    }

    func stop() {
        pollTimer = nil
        settleTimer = nil
        settingsObserver = nil
    }

    // MARK: - Asking

    /// macOS has a decision on record for this very build: probing can't prompt.
    private var askedForThisIdentity: Bool { defaults.string(forKey: Self.requestedIdentityKey) == identity }
    private var canProbe: Bool { askedThisSession || askedForThisIdentity }

    /// Asks macOS so that its prompt appears. A decision it already holds (an old build's grant, a "Deny") would
    /// keep the prompt away and the switch in System Settings stuck, so that is cleared first.
    private func askAfresh() {
        let askedBefore = defaults.string(forKey: Self.requestedIdentityKey) != nil || defaults.bool(forKey: Self.legacyRequestedKey)
        defaults.set(identity, forKey: Self.requestedIdentityKey)
        defaults.removeObject(forKey: Self.legacyRequestedKey)
        askedThisSession = true
        isAwaitingGrant = true
        offersRelaunch = false
        guard askedBefore, system.isAppBundle else {
            system.request()
            watch()
            return
        }
        system.resetDecision { [weak self] cleared in
            guard let self, !self.isGranted else { return }
            if cleared {
                self.system.request()
            } else {
                // The old decision stays, and so would the prompt: go where the switch is instead.
                captureLog.error("Could not reset the Screen Recording decision; opening System Settings")
                self.system.openSettings()
            }
            self.watch()
        }
    }

    // MARK: - Noticing the grant

    /// Polls for the grant for a while (cheap, and only until it arrives), and keeps an eye on System Settings.
    private func watch() {
        pollsLeft = Int((Self.pollWindow / Self.pollInterval).rounded())
        schedulePoll()
        watchSettings()
    }

    private func schedulePoll() {
        pollTimer = scheduler.schedule(after: Self.pollInterval) { [weak self] in
            guard let self, !self.isGranted else { return }
            self.pollsLeft -= 1
            self.check { _ in }
            if self.pollsLeft > 0, !self.isGranted { self.schedulePoll() } else { self.pollTimer = nil }
        }
    }

    /// Leaving System Settings is when a grant is most likely to have just happened. Watched for as long as the
    /// grant is missing and probing is safe. It's one notification per app switch, so it costs nothing while idle.
    private func watchSettings() {
        guard !isGranted, canProbe, settingsObserver == nil else { return }
        settingsObserver = system.observeSettingsClosed { [weak self] in self?.settingsClosed() }
    }

    private func settingsClosed() {
        settleTimer = scheduler.schedule(after: Self.settingsSettleDelay) { [weak self] in
            guard let self, !self.isGranted else { return }
            self.check { [weak self] works in
                guard let self, !works, self.askedThisSession else { return }
                self.offersRelaunch = true
                self.watch() // maybe they only flip the switch on the next visit
                self.onChange()
            }
        }
    }

    /// Preflight first (cheap, and fine whenever it does say yes), then ScreenCaptureKit if that's safe.
    private func check(_ completion: @escaping (Bool) -> Void) {
        if system.preflight() {
            granted()
            return completion(true)
        }
        guard canProbe else { return completion(false) }
        probe { [weak self] works in
            if works { self?.granted() }
            completion(works)
        }
    }

    /// One probe at a time: a slow one (macOS showing an alert) must not pile up more.
    private func probe(_ completion: @escaping (Bool) -> Void) {
        if let started = probeStartedAt, now().timeIntervalSince(started) < Self.probeStaleAfter {
            return completion(false)
        }
        let started = now()
        probeStartedAt = started
        system.probe { [weak self] works in
            if self?.probeStartedAt == started { self?.probeStartedAt = nil }
            completion(works)
        }
    }

    private func granted() {
        guard !isGranted else { return }
        isGranted = true
        isAwaitingGrant = false
        offersRelaunch = false
        stop()
        onChange()
    }
}

// MARK: - The real system

extension ScreenCaptureAccess.System {
    static let live = ScreenCaptureAccess.System(
        preflight: { ScreenGrabber.hasPermission },
        request: { ScreenGrabber.requestPermission() },
        probe: { ScreenGrabber.probeAccess(completion: $0) },
        resetDecision: resetOwnDecision,
        openSettings: {
            if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(pane)
            }
        },
        relaunch: { Relauncher.relaunch() },
        identity: designatedRequirement,
        isAppBundle: Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil,
        observeSettingsClosed: { handler in
            let center = NSWorkspace.shared.notificationCenter
            let tokens = [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
                center.addObserver(forName: $0, object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    if app?.bundleIdentifier == "com.apple.systempreferences" { handler() }
                }
            }
            return AnyCancellable { tokens.forEach(center.removeObserver) }
        }
    )

    /// `tccutil reset ScreenCapture <our bundle id>`: only our own record, and no admin rights needed.
    private static func resetOwnDecision(_ completion: @escaping (Bool) -> Void) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return completion(false) }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "ScreenCapture", bundleID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var cleared = false
            do {
                try process.run()
                process.waitUntilExit()
                cleared = process.terminationStatus == 0
            } catch {
                captureLog.error("tccutil failed: \(error.localizedDescription, privacy: .public)")
            }
            DispatchQueue.main.async { completion(cleared) }
        }
    }

    /// e.g. `identifier "com.lightstick.whiplash" and certificate leaf = H"…"` (scripts/signing.sh), or
    /// `cdhash H"…"` for an ad-hoc build, which changes with every build.
    private static func designatedRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return nil }
        return text as String?
    }
}

/// Starts a fresh copy of Whiplash.app once this one has quit.
enum Relauncher {
    /// Flags that only make sense once (or aren't for the app at all) are dropped.
    static func arguments(keeping arguments: [String]) -> [String] {
        var kept: [String] = []
        var it = arguments.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--whip-now", "--grab", "--selftest": continue
            case "--demo", "--out": _ = it.next()
            default: kept.append(arg)
            }
        }
        return kept
    }

    /// Waits (up to 10 s) in a detached shell for this process to exit, then opens the bundle in the background
    /// with this session's flags, so there are never two copies and the terminal keeps the keyboard.
    static func relaunch() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            captureLog.error("Relaunch needs Whiplash.app; this is a bare binary")
            return
        }
        let script = """
            i=0; while kill -0 \(getpid()) 2>/dev/null; do i=$((i+1)); [ $i -gt 100 ] && exit 1; sleep 0.1; done
            exec /usr/bin/open -n -g "$0" --args "$@"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, bundle.path] + arguments(keeping: Array(CommandLine.arguments.dropFirst()))
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            captureLog.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}
