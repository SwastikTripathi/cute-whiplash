import AppKit
import SpriteKit

/// The borderless panel that covers one whole screen during a punishment. Click-through unless told otherwise,
/// invisible to screen capture, present on every Space (full-screen ones too) and never activates the app.
final class OverlayPanel: NSPanel {
    /// Whether the panel may become key — needed for Esc. Key status of a non-activating panel does not
    /// activate the app, so the terminal stays the active app throughout.
    var allowsKey = false

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = WindowLevels.overlay
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        sharingType = .none
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Borderless windows may cover the menu bar; never let AppKit nudge the frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The overlay's SKView. Its bounds equal the screen, so view coordinates are scene coordinates.
/// It turns raw events into two intents and never forwards them to the scene (which reads the pointer itself).
final class OverlayView: SKView {
    /// Left click, scene coordinates.
    var onClick: ((CGPoint) -> Void)?
    /// Esc or right-click.
    var onCancel: (() -> Void)?
    /// Shown instead of the arrow while the user holds the whip; nil keeps the system cursor.
    var gripCursor: NSCursor? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        if let gripCursor { addCursorRect(bounds, cursor: gripCursor) }
    }

    override func cursorUpdate(with event: NSEvent) {
        if let gripCursor { gripCursor.set() } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }

    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func rightMouseUp(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode { onCancel?() }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    private static let escapeKeyCode: UInt16 = 53

    private func pointer(_ event: NSEvent) {
        // Background apps can reset the cursor under us; re-assert it while the whip is in hand.
        if let gripCursor, NSCursor.current != gripCursor { gripCursor.set() }
    }

    /// A small warm dot in a dark ring: where your fist is on the whip handle.
    static let whipGripCursor: NSCursor = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            NSColor(srgbRed: 1, green: 0.82, blue: 0.5, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
    }()
}
