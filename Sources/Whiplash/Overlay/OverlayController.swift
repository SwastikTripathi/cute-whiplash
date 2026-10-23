import AppKit

/// Shows the full-screen punishment overlay and runs a PunishmentPlan in it.
///
/// Input: over a screenshot (and in manual mode) the overlay takes the mouse and the keyboard from the first frame —
/// the live screen is hidden behind a frozen picture, so nothing may reach it blind — and a click or Esc leaves
/// (quick exit; during the break, a normal rewind). In glass mode the live screen stays visible and usable:
/// the overlay is click-through except during the break. Once the rewind starts it lets go of the mouse.
///
/// Every run builds a fresh panel, SKView and PunishmentScene and tears all of it down afterwards, so nothing
/// renders (or holds a screenshot in memory) between punishments. Safety nets, in order: the scene's own hard
/// timeout (auto 25 s, manual 120 s → quick exit), a wall-clock watchdog a little later in case the scene stops
/// updating, a backstop after `dismiss()`, and immediate teardown on sleep, session switch or display changes.
final class OverlayController {
    private(set) var isActive = false
    private var session: Session?

    /// Everything one run owns.
    private final class Session {
        let window: OverlayPanel
        let view: OverlayView
        let scene: PunishmentScene
        let isManual: Bool
        let completion: () -> Void
        var timers: [Timer] = []
        var observers: [(NotificationCenter, NSObjectProtocol)] = []

        init(window: OverlayPanel, view: OverlayView, scene: PunishmentScene, isManual: Bool, completion: @escaping () -> Void) {
            self.window = window
            self.view = view
            self.scene = scene
            self.isManual = isManual
            self.completion = completion
        }
    }

    /// Past the scene's own hard timeout, the watchdog closes the window without ceremony.
    private static let watchdogGrace: TimeInterval = 2
    /// After `dismiss()`, the window is gone within this long no matter what.
    private static let dismissBackstop: TimeInterval = 1

    /// Every run is fully described by its PunishmentPlan, so the overlay keeps no reference to `settings`.
    init(settings: Settings) {}

    /// `anchor`: where the whip is held (Cocoa global). `onBeat` reports the show's big moments (main queue);
    /// `completion` runs after the overlay is gone.
    /// A run requested while another is on screen is declined (its completion still runs, asynchronously).
    func run(plan: PunishmentPlan, on screen: NSScreen, anchor: CGPoint, onBeat: @escaping (PunishmentBeat) -> Void = { _ in },
             completion: @escaping () -> Void) {
        guard session == nil else {
            DispatchQueue.main.async(execute: completion)
            return
        }
        let frame = screen.frame
        let scene = PunishmentScene(plan: plan, screenFrame: frame, anchor: anchor)
        let window = OverlayPanel(frame: frame)
        let view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        view.allowsTransparency = true
        view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        window.contentView = view

        let session = Session(window: window, view: view, scene: scene, isManual: plan.isManual, completion: completion)
        self.session = session
        isActive = true

        scene.onFinished = { [weak self, weak session] in
            // Never tear the view down from inside its own render callback.
            DispatchQueue.main.async {
                guard let self, let session, self.session === session else { return }
                self.close()
            }
        }
        scene.onBeat = { [weak self, weak session] beat in
            // Out of the render callback: the island (SwiftUI) reacts to it.
            DispatchQueue.main.async {
                guard let self, let session, self.session === session else { return }
                onBeat(beat)
            }
        }
        wireInput(session)
        view.presentScene(scene)
        window.orderFrontRegardless()
        setAcceptsEvents(scene.capturesInput, session)
        if plan.isManual { grabWhip(session, on: screen) }

        let hardTimeout = scene.sequencer.hardTimeout + Self.watchdogGrace
        session.timers.append(schedule(after: hardTimeout) { [weak self] in self?.close() })
        observeInterruptions(session)
    }

    /// Skip to the end: reassemble quickly (≤ 0.4 s) and close.
    func dismiss() {
        guard let session else { return }
        session.scene.dismiss()
        scheduleBackstop(session)
    }

    /// Whatever the scene does, the window is gone within `dismissBackstop`.
    private func scheduleBackstop(_ session: Session) {
        session.timers.append(schedule(after: Self.dismissBackstop) { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.close()
        })
    }

    /// Auto mode's click / Esc: skips the rest of the break, otherwise leaves (with the backstop).
    private func interrupt(_ session: Session) {
        guard self.session === session else { return }
        if session.scene.interrupt() { scheduleBackstop(session) }
    }

    // MARK: - Input

    private func wireInput(_ session: Session) {
        let scene = session.scene
        if session.isManual {
            // (The scene reads the pointer itself every frame: see `grabWhip`.)
            session.view.onClick = { [weak scene] point in scene?.pointerMoved(to: point) }
            session.view.onCancel = { [weak scene] in scene?.skip() }
        } else {
            // A click doesn't end the break early (Esc or a right-click still do: never trap the user) — during the
            // break it smashes the broken screen some more.
            session.view.onClick = { [weak scene] point in scene?.smash(at: point) }
            session.view.onCancel = { [weak self, weak session] in
                if let self, let session { self.interrupt(session) }
            }
        }
        scene.onCapturesInputChanged = { [weak self, weak session] captures in
            DispatchQueue.main.async {
                guard let self, let session, self.session === session else { return }
                self.setAcceptsEvents(captures, session)
            }
        }
    }

    /// Manual mode: the whip jumps into your hand (the overlay already has the mouse and the keyboard, for Esc) and
    /// follows the pointer from then on. It reads the pointer every frame rather than waiting for mouse events: when
    /// you pulled it out of the island, the island's window keeps the mouse until you let go of the button.
    private func grabWhip(_ session: Session, on screen: NSScreen) {
        session.view.gripCursor = OverlayView.whipGripCursor
        let frame = screen.frame
        let pointer = { () -> CGPoint? in
            let mouse = NSEvent.mouseLocation
            return frame.contains(mouse) ? CoordinateSpace.scene(fromCocoa: mouse, screenFrame: frame) : nil
        }
        session.scene.pointerSource = pointer
        if let point = pointer() { session.scene.pointerMoved(to: point) }
    }

    /// Takes the mouse and the keyboard (Esc), or lets clicks fall through to the screen again.
    ///
    /// Letting go cannot hand key status back while the panel is on screen (AppKit gives a window no way to resign
    /// it), so keys typed during the last second of the rewind are still swallowed; once the panel is ordered out
    /// the terminal, which stayed the active app throughout, has the keyboard again.
    private func setAcceptsEvents(_ accepts: Bool, _ session: Session) {
        session.window.ignoresMouseEvents = !accepts
        session.window.allowsKey = accepts
        if accepts {
            session.window.makeKey()
            session.window.makeFirstResponder(session.view)
        } else if session.view.gripCursor != nil {
            session.view.gripCursor = nil
            NSCursor.arrow.set()
        }
    }

    // MARK: - Teardown

    private func observeInterruptions(_ session: Session) {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.close() }
            session.observers.append((workspace, token))
        }
        let screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in self?.dismiss() }
        session.observers.append((NotificationCenter.default, screens))
    }

    private func close() {
        guard let session else { return }
        self.session = nil
        session.timers.forEach { $0.invalidate() }
        session.observers.forEach { center, token in center.removeObserver(token) }
        session.scene.tearDown()
        session.view.presentScene(nil)
        session.view.isPaused = true
        session.view.gripCursor = nil
        session.window.orderOut(nil)
        session.window.contentView = nil
        session.window.close()
        if session.isManual { NSCursor.arrow.set() }
        isActive = false
        session.completion()
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
