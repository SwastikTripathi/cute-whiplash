import AppKit
import CoreGraphics

// MARK: - Coordinate conventions (read this before passing points between modules)
//
// * "Cocoa global": AppKit screen coordinates, y-up, origin at the bottom-left of the primary display.
//   NSScreen.frame, NSEvent.mouseLocation and NSWindow.frame use this.
// * "Quartz global": y-down, origin at the top-left of the primary display. CGWindowListCopyWindowInfo,
//   CGEvent and ScreenCaptureKit use this. Convert with `CoordinateSpace`.
// * "Scene": points relative to ONE screen's bottom-left corner, y-up. The overlay window covers exactly
//   that screen, and its SpriteKit scene has size == screen.frame.size, so scene coords are also SpriteKit
//   coords. Vision's normalized boxes (origin bottom-left) map to scene coords by multiplying by the size.
//
// Every CGRect/CGPoint that crosses a module boundary states which of these it is.

/// One piece of text peeled off the screen, ready to fall.
struct GlyphSample {
    /// The character (or short word, when per-character boxes were not available).
    var text: String
    /// Where it sits right now, in scene coordinates.
    var rect: CGRect
    /// Crop of the screenshot covering `rect`, at backing resolution. nil for synthetic text: render `text` with a font.
    var image: CGImage?
    /// Best guess of the glyph's ink colour.
    var color: NSColor
    /// Colour sampled around the glyph; used to paint over the spot it leaves behind.
    var background: NSColor
    /// Approximate font size in points (≈ rect height for single characters).
    var fontSize: CGFloat
}

/// A capture of one whole screen.
struct ScreenSnapshot {
    /// Full screen at backing resolution (pixels). Row 0 is the TOP of the screen, like any CGImage.
    let image: CGImage
    /// The screen's frame in Cocoa global coordinates (points).
    let screenFrame: CGRect
    /// Pixels per point: image.width / screenFrame.width.
    let scale: CGFloat
}

/// What the notch island is showing.
enum IslandPhase: Equatable {
    case idle
    /// Enough work without a break: Lash suggests one, counting down to the warning. Stepping away calls it off.
    case nudge(secondsLeft: Int)
    /// The whip is coming. Counts down to 0.
    case warning(secondsLeft: Int)
    case whipping
    /// Manual whip mode: the user is holding the whip.
    case manual
    /// Just punished; the critter is smug for a few seconds.
    case aftermath
    case snoozed(until: Date)
    case disabled
}

enum CritterMood: String, CaseIterable {
    case sleepy, happy, curious, suspicious, annoyed, furious, maniacal, smug

    /// Mood for a streak that is `progress` (0...1) of the way to the threshold.
    static func forProgress(_ progress: Double) -> CritterMood {
        switch progress {
        case ..<0.01: return .happy
        case ..<0.35: return .curious
        case ..<0.65: return .suspicious
        case ..<0.9: return .annoyed
        default: return .furious
        }
    }
}

/// Everything the overlay needs for one punishment round. Built by AppCoordinator.
struct PunishmentPlan {
    /// Number of whip cracks (1...6). Escalates with repeat offences.
    var strikes: Int = 3
    /// After the cracks, break the glass and drop the text inside the screen.
    var shatter: Bool = true
    /// What to aim at, Cocoa global coordinates (usually the frontmost terminal window). nil = middle of screen.
    var targetRect: CGRect?
    /// Screenshot of the punished screen taken just before the overlay appeared. nil = "glass" mode:
    /// the overlay is transparent over the live screen and text is synthetic.
    var backdrop: ScreenSnapshot?
    /// Text to peel off and drop, in scene coordinates of the punished screen. Leave empty to let the overlay
    /// harvest it itself while the whip strikes (OCR of `backdrop`, or synthetic text inside `targetRect`).
    var glyphs: [GlyphSample] = []
    /// The break: how long the screen stays broken (once the shards have fallen) before everything reassembles.
    var holdSeconds: TimeInterval = 10
    /// Lash's taunt for the break (the island shows it).
    var message: String = "GO TOUCH GRASS"
    /// Manual mode: the user drives the whip with the mouse instead of the scripted strikes.
    var isManual: Bool = false
    /// Chaos multiplier from Settings.intensity (0.5...2).
    var intensity: CGFloat = 1
}

/// Where Lash's island sits.
enum IslandPlacement: String, CaseIterable {
    /// Around the notch, on top of any other app's island there (Sapphire, NotchNook, …).
    case aroundNotch
    /// Always beside the notch, in the menu bar to its left.
    case beside
}

/// Window levels, so the island stays above the punishment overlay (the whip comes out of the notch).
enum WindowLevels {
    static let island = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    static let overlay = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
}
