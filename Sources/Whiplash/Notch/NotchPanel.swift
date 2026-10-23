import AppKit
import SwiftUI

/// The borderless, non-activating panel the island lives in. It floats above everything (even the punishment
/// overlay and full-screen apps), never becomes key or main, and never steals focus from the terminal.
final class NotchPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Before `level`: making a panel floating resets its level to .floating.
        isFloatingPanel = true
        level = WindowLevels.island
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        // Start click-through; the controller turns mouse events on only while the cursor is over the island.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The island sits in the menu bar, where AppKit would normally refuse to put a window.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI island. Accepts the first click, so buttons work without activating the app first.
///
/// The app is practically never active (the panel is non-activating), and AppKit only sends mouse-moved events to an
/// inactive app's window if it has an always-active tracking area. This view keeps one, so moves over the island
/// reach `NotchController`'s local monitor: Lash keeps watching the cursor and can be petted.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    private var cursorTracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installCursorTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installCursorTracking()
    }

    private func installCursorTracking() {
        if let cursorTracking, trackingAreas.contains(cursorTracking) { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTracking = area
    }
}
