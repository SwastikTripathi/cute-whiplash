import AppKit
import Combine
import SwiftUI

/// Owns the island panel that hugs the notch and renders `IslandModel`.
///
/// The panel has a fixed frame big enough for every presentation; everything outside the island's current shape
/// is transparent and click-through. Global + local mouse monitors (no polling, no Accessibility permission)
/// drive hover, click-through, Lash's gaze and petting, and pulling the whip out of the island's right end.
final class NotchController {
    let model: IslandModel
    let settings: Settings
    /// Where the island is laid out right now, Cocoa global: round the notch, or beside another app's island.
    private(set) var geometry: NotchGeometry?

    /// Hover must last this long before the island expands (so crossing the menu bar doesn't pop it open)…
    static let expandDelay: TimeInterval = 0.12
    /// …and the cursor must stay away this long before it collapses (no flicker along the edge).
    static let collapseDelay: TimeInterval = 0.35
    /// While expanded, the hover zone reaches this far past the island's edge.
    static let hoverSlack: CGFloat = 10
    /// Quips clear themselves after this long.
    static let quipLifetime: TimeInterval = 3.5

    private let ui: IslandUIState
    private let lash: LashState
    private var panel: NotchPanel?
    private var presentation: IslandPresentation = .closed
    private var lastPhase: IslandPhase
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []
    private var hoverChange: (target: Bool, work: DispatchWorkItem)?
    private var quipExpiry: DispatchWorkItem?
    /// Another app's island over the notch (Sapphire, NotchNook, …), as last seen, and its smallest (collapsed) frame.
    private var neighbour: NotchNeighbors.Island?
    private var neighbourRestFrame: CGRect?
    private var neighbourTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastNeighbourCheck: TimeInterval = -.infinity
    /// Faded out and click-through while you have the neighbour's island open (see `NotchNeighbors.Yield`).
    private var yielding = false
    private var neighbourYield = NotchNeighbors.Yield()
    /// The neighbour, collapsed, shows its own content left of the notch (see `IslandLayout.sharesLeft`).
    private var neighbourSharesLeft = false
    /// Laid out beside the notch rather than round it.
    private var isBeside = false
    private var whipPull = WhipPull()
    /// The open (or closed) hand is showing over the whip's end of the island.
    private var showsHandCursor = false

    /// How often a neighbour island is checked on (it may open for music without any hover)…
    static let neighbourPollInterval: TimeInterval = 1
    /// …and how often one is looked for while there is none.
    static let neighbourSearchInterval: TimeInterval = 4

    init(model: IslandModel, settings: Settings = .shared) {
        self.model = model
        self.settings = settings
        let geometry = NotchGeometry.preferredScreen().map(NotchGeometry.forScreen)
        ui = IslandUIState(layout: IslandLayout(notchSize: geometry?.notchRect.size ?? NotchGeometry.virtualNotchSize))
        lash = LashState(model: model)
        lastPhase = model.phase
        observeModel()
    }

    deinit {
        removeMonitors()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        relayout()
        panel.orderFrontRegardless()
        installMonitors()
        watchNeighbours()
        lash.startBlinking()
        cursorMoved()
    }

    func hide() {
        removeMonitors()
        stopWatchingNeighbours()
        lash.stopBlinking()
        whipPull.release()
        hoverChange?.work.cancel()
        hoverChange = nil
        ui.isHovering = false
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    /// Where the overlay should hold the whip when it punishes `screen` — or, `manual`, where the whip you pull out
    /// lives — Cocoa global. See `whipAnchor(on:island:manual:)`.
    func whipAnchor(on screen: NSScreen, manual: Bool = false) -> CGPoint {
        Self.whipAnchor(on: screen.frame, island: geometry ?? self.screen.map(NotchGeometry.forScreen), manual: manual)
    }

    /// How far above the top edge of a screen without the island the whip is held.
    static let offscreenGripHeight: CGFloat = 10

    /// Where the whip is held on the screen whose Cocoa frame is `screenFrame`, given the island's geometry (Cocoa
    /// global). On the island's own screen: just inside the whipping pill's bottom edge, so the handle — drawn by the
    /// overlay, with Lash's paw round it — comes out from under Lash's island; `manual` (the whip you pull out
    /// yourself), at the pill's right end instead. On any other screen: a little above its top edge, so the handle
    /// reaches in from off-screen instead of floating under an empty spot.
    static func whipAnchor(on screenFrame: CGRect, island: NotchGeometry?, manual: Bool = false) -> CGPoint {
        if let island, island.screenFrame == screenFrame {
            return manual ? IslandLayout.whipPullGrip(for: island) : IslandLayout.whipGrip(for: island)
        }
        return CGPoint(x: screenFrame.midX, y: screenFrame.maxY + offscreenGripHeight)
    }

    /// The screen the island lives on.
    var screen: NSScreen? { NotchGeometry.preferredScreen() }

    // MARK: - Panel

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(frame: CGRect(origin: .zero, size: ui.layout.panelSize))
        let root = IslandView(model: model, ui: ui, lash: lash).ignoresSafeArea()
        let hosting = IslandHostingView(rootView: root)
        // The panel's frame is ours to decide; SwiftUI must not resize it, nor inset content for the notch.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        return panel
    }

    /// Re-reads the notch geometry (screen added/removed, resolution changed, a neighbour island came or went) and
    /// moves the panel.
    private func relayout() {
        guard let screen, let panel else { return }
        let base = NotchGeometry.forScreen(screen)
        let geometry = placement(base: base)
        self.geometry = geometry
        isBeside = geometry.notchRect != base.notchRect
        let layout = IslandLayout(geometry: geometry, sharesLeft: neighbourSharesLeft && !isBeside)
        if layout != ui.layout { withAnimation(IslandView.shapeSpring) { ui.layout = layout } }
        panel.setFrame(layout.panelFrame(in: geometry), display: true)
        updateYield()
        cursorMoved()
    }

    /// Round the notch, or beside the neighbour's island (see `IslandPlacement`).
    private func placement(base: NotchGeometry) -> NotchGeometry {
        let closedWings: (CGSize) -> (left: CGFloat, right: CGFloat) = { size in
            let layout = IslandLayout(notchSize: size)
            return (layout.closedLeftWing, layout.closedRightWing)
        }
        switch settings.islandPlacement {
        case .aroundNotch: return base
        case .beside: return NotchNeighbors.beside(base, neighbour: neighbourRestFrame, closedWings: closedWings)
        }
    }

    // MARK: - Neighbours

    private func watchNeighbours() {
        guard neighbourTimer == nil else { return }
        checkNeighbours()
        let timer = Timer(timeInterval: Self.neighbourPollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let since = ProcessInfo.processInfo.systemUptime - self.lastNeighbourCheck
            if self.neighbour != nil || since >= Self.neighbourSearchInterval { self.checkNeighbours() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        neighbourTimer = timer
        // An island app launching or quitting: look again once its window is up (or gone).
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            center.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in
                for delay in [0.8, 2.5] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self?.checkNeighbours() }
                }
            }
        }
    }

    private func stopWatchingNeighbours() {
        neighbourTimer?.invalidate()
        neighbourTimer = nil
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
    }

    /// Looks for another app's island over the notch; moves ours when one arrives, leaves or settles elsewhere.
    private func checkNeighbours() {
        lastNeighbourCheck = ProcessInfo.processInfo.systemUptime
        guard let screen else { return }
        let base = NotchGeometry.forScreen(screen)
        let found = NotchNeighbors.current(over: base.notchRect, screen: base.screenFrame).max { $0.frame.width < $1.frame.width }
        let previousRest = neighbourRestFrame
        if let found {
            // Remember the island at its smallest (collapsed), so ours doesn't jump away each time it expands.
            if found.pid != neighbour?.pid || previousRest == nil {
                neighbourRestFrame = found.frame
            } else if let rest = previousRest, found.frame.width * found.frame.height < rest.width * rest.height - 1 {
                neighbourRestFrame = found.frame
            }
        } else {
            neighbourRestFrame = nil
        }
        neighbour = found
        let sharedLeft = neighbourSharesLeft
        neighbourSharesLeft = NotchNeighbors.showsContentLeft(of: base.notchRect, frame: found?.frame,
                                                              screen: base.screenFrame, previously: sharedLeft)
        if neighbourRestFrame != previousRest || neighbourSharesLeft != sharedLeft { relayout() } else { updateYield() }
    }

    /// Fade out while you have the neighbour's island open — on top of it, ours would cover what it's showing; beside
    /// it, it has grown over ours — unless Lash has something to say (a nudge, the countdown, the whip). Not when it
    /// opens by itself: a volume or brightness HUD shouldn't make Lash vanish.
    private func updateYield() {
        let urgent: Bool = {
            switch model.phase {
            case .nudge, .warning, .whipping, .manual: return true
            case .idle, .aftermath, .snoozed, .disabled: return false
            }
        }()
        var covered = false
        if let panel {
            let cursor = NSEvent.mouseLocation
            let onLash = ui.layout.takesMouse(at: IslandLayout.panelPoint(fromCocoa: cursor, panelFrame: panel.frame),
                                              in: presentation, sharesNotch: neighbour != nil && !isBeside)
            covered = neighbourYield.update(neighbour: neighbour?.frame, cursor: onLash ? nil : cursor)
            if covered, isBeside, let neighbour {
                let island = ui.layout.islandRect(for: .closed)
                let islandCocoa = CGRect(origin: IslandLayout.cocoaPoint(fromPanel: CGPoint(x: island.minX, y: island.maxY), panelFrame: panel.frame),
                                         size: island.size)
                covered = neighbour.frame.intersects(islandCocoa.insetBy(dx: 2, dy: 2))
            }
        }
        let yield = covered && !urgent && !ui.isHovering
        guard yield != yielding else { return }
        yielding = yield
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel?.animator().alphaValue = yield ? 0 : 1
        }
        cursorMoved()
    }

    // MARK: - Model

    private func observeModel() {
        let hasQuip = model.$quip.map { $0 != nil }.removeDuplicates()
        // @Published emits before the property changes, so use the emitted values, never the model's.
        Publishers.CombineLatest3(model.$phase, hasQuip, ui.$isHovering)
            .map { IslandPresentation.resolve(phase: $0, hovering: $2, hasQuip: $1) }
            .removeDuplicates()
            .sink { [weak self] presentation in
                self?.presentation = presentation
                // Re-hit-test against the new shape once it's committed.
                DispatchQueue.main.async { self?.cursorMoved() }
            }
            .store(in: &subscriptions)

        model.$phase
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.phaseChanged(to: phase)
                // Lash's turn to talk (a nudge, the whip): back in front even beside an expanded neighbour.
                DispatchQueue.main.async { self?.updateYield() }
            }
            .store(in: &subscriptions)

        settings.$islandPlacement
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.relayout() } }
            .store(in: &subscriptions)

        model.$quip
            .sink { [weak self] quip in self?.scheduleQuipExpiry(quip) }
            .store(in: &subscriptions)
    }

    /// Lash comments on some transitions, unless the coordinator already gave it a line.
    private func phaseChanged(to phase: IslandPhase) {
        let previous = lastPhase
        lastPhase = phase
        guard previous != phase else { return }
        let topic: QuipTopic?
        switch (previous, phase) {
        case (_, .aftermath): topic = .mood(.smug)
        case (.warning, .idle): topic = .relief
        case (.snoozed, .snoozed): topic = nil
        case (_, .snoozed): topic = .snoozed
        default: topic = nil
        }
        guard let topic else { return }
        // Let the coordinator finish its own update first (it may set a quip right after the phase).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.quip == nil, self.model.phase == phase else { return }
            self.lash.say(topic)
        }
    }

    private func scheduleQuipExpiry(_ quip: String?) {
        quipExpiry?.cancel()
        quipExpiry = nil
        guard let quip else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.quip == quip else { return }
            self.model.quip = nil
        }
        quipExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quipLifetime, execute: work)
    }

    // MARK: - Mouse

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.cursorMoved() }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.cursorMoved()
            return event
        }) {
            monitors.append(local)
        }
        if let pull = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] event in
            self?.whipPullEvent(event) ?? event
        }) {
            monitors.append(pull)
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in self?.relayout() }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Everything that follows the cursor: click-through, Lash's eyes, petting, hover.
    private func cursorMoved() {
        guard let panel, panel.isVisible else { return }
        let layout = ui.layout
        let point = IslandLayout.panelPoint(fromCocoa: NSEvent.mouseLocation, panelFrame: panel.frame)
        // While the whip is out the overlay owns the mouse: the island (a window above it) must not swallow the moves
        // and clicks of a whip swung up toward the notch. Lash still watches it.
        let overlayOwnsMouse = model.phase == .whipping || model.phase == .manual
        let sharesNotch = neighbour != nil && !isBeside
        let takesMouse = !yielding && !overlayOwnsMouse && layout.takesMouse(at: point, in: presentation, sharesNotch: sharesNotch)
        if panel.ignoresMouseEvents == takesMouse { panel.ignoresMouseEvents = !takesMouse }
        // A neighbour island expands on hover: when the cursor is up near the notch, check on it more often.
        if neighbour != nil, point.y < 320, abs(point.x - panel.frame.width / 2) < 600,
           ProcessInfo.processInfo.systemUptime - lastNeighbourCheck > 0.3 {
            checkNeighbours()
        }
        updateHandCursor(at: point)
        lash.look(at: point, from: layout.eyeCenter(for: presentation))
        let lashRect = layout.lashRect(for: presentation)
        lash.cursorMoved(to: point, overLash: !overlayOwnsMouse && lashRect.contains(point),
                         overHead: !overlayOwnsMouse && LashAnatomy.headRect(in: lashRect).contains(point))
        setHovering(!overlayOwnsMouse
            && layout.hoverKeepsOpen(point, in: presentation, open: ui.isHovering, slack: Self.hoverSlack, sharesNotch: sharesNotch))
    }

    // MARK: - Pulling the whip

    /// Where the whip can be grabbed right now, panel space (nil while Lash has it, or the island has stepped aside).
    private var whipPullZone: CGRect? {
        guard !yielding else { return nil }
        return ui.layout.whipPullRect(for: presentation)
    }

    /// Press on the island's right end and drag: out comes the whip. The island keeps these presses to itself, so a
    /// dashboard control or the menu bar underneath never gets half a gesture.
    private func whipPullEvent(_ event: NSEvent) -> NSEvent? {
        guard let panel, event.window === panel else { return event }
        let point = IslandLayout.panelPoint(fromCocoa: NSEvent.mouseLocation, panelFrame: panel.frame)
        switch event.type {
        case .leftMouseDown:
            guard whipPull.press(at: point, in: whipPullZone) else { return event }
        case .leftMouseDragged:
            guard whipPull.isHolding else { return event }
            if whipPull.drag(to: point) { pullWhipOut() }
        case .leftMouseUp:
            guard whipPull.isHolding else { return event }
            whipPull.release()
        default:
            return event
        }
        updateHandCursor(at: point)
        return nil
    }

    private func pullWhipOut() {
        model.onGrabWhip()
        guard model.phase == .manual else { return } // Lash is busy with it: nothing to hold
        // Your hand is on the whip now. (The overlay only hears the mouse once the button is up: until then it
        // follows the cursor by itself.)
        showsHandCursor = false
        OverlayView.whipGripCursor.set()
    }

    /// An open hand over the whip's end of the island, a closed one while pulling.
    private func updateHandCursor(at point: CGPoint) {
        if whipPull.isHolding {
            NSCursor.closedHand.set()
            showsHandCursor = true
        } else if whipPullZone?.contains(point) == true {
            NSCursor.openHand.set()
            showsHandCursor = true
        } else if showsHandCursor {
            NSCursor.arrow.set()
            showsHandCursor = false
        }
    }

    /// Debounced hover: expand after a short dwell, collapse after a slightly longer absence.
    private func setHovering(_ hovering: Bool) {
        guard hovering != ui.isHovering else {
            hoverChange?.work.cancel()
            hoverChange = nil
            return
        }
        guard hoverChange?.target != hovering else { return } // already on its way
        hoverChange?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hoverChange = nil
            self?.ui.isHovering = hovering
        }
        hoverChange = (hovering, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + (hovering ? Self.expandDelay : Self.collapseDelay), execute: work)
    }
}
