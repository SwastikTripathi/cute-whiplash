import SpriteKit
import SwiftUI

/// A headless demo: renders frames to PNG so visuals can be checked without opening windows.
/// Run with `Whiplash --demo <name|prefix|all|list> --out <dir>` (or scripts/demo.sh).
struct Demo {
    /// Dotted name; the first component is the owning module, e.g. "whip.strike", "fx.shatter".
    let name: String
    let summary: String
    /// Scene / canvas size in points.
    var size: CGSize = DemoDefaults.screenSize
    let payload: Payload

    enum Payload {
        case scene(SceneDemo)
        case view(ViewDemo)
    }
}

/// A SpriteKit scene stepped at a fixed 60 fps; frames are written at `captureTimes`.
struct SceneDemo {
    var duration: TimeInterval
    var captureTimes: [TimeInterval]
    /// Draw FakeBackdrop underneath each frame (use for transparent overlay scenes). Turn off when the
    /// scene paints its own full-screen backdrop, or the fake desktop will show through holes.
    var compositeOverBackdrop = true
    /// Pixels per point of the output PNGs. 1 keeps files small; use 2 for close-ups.
    var scale: CGFloat = 1
    /// Only this part of the canvas (points, y-up) goes into the PNGs — for close-ups of a full-screen scene.
    var crop: CGRect?
    /// Builds the scene for a canvas of the given size (points).
    var make: (CGSize) -> SKScene
    /// Called every frame before the scene updates: (scene, time since start). Use it to script events.
    var onFrame: ((SKScene, TimeInterval) -> Void)?
}

/// A SwiftUI view rendered once with ImageRenderer at 2x.
struct ViewDemo {
    var make: () -> AnyView
    /// Paint this behind the view (e.g. a menu-bar strip) — nil = transparent.
    var background: NSColor? = NSColor(calibratedWhite: 0.85, alpha: 1)
}

enum DemoDefaults {
    /// 16" MacBook Pro default "looks like" resolution.
    static let screenSize = CGSize(width: 1728, height: 1117)
}

enum DemoRegistry {
    /// Every module contributes its own list from its own `Debug/Demo+<Module>.swift`.
    static var all: [Demo] {
        coreDemos + [groundTruthDemo] + trackingDemos + captureDemos + notchDemos + whipDemos + fxDemos + overlayDemos
    }

    static var coreDemos: [Demo] {
        [
            Demo(name: "core.backdrop", summary: "The fake desktop used behind demos, with a notch marker",
                 payload: .scene(SceneDemo(duration: 0.1, captureTimes: [0], compositeOverBackdrop: true, make: { size in
                     let scene = SKScene(size: size)
                     scene.backgroundColor = .clear
                     let notch = NotchGeometry.demo(size: size).notchRect
                     let marker = SKShapeNode(rect: notch.insetBy(dx: -4, dy: -4), cornerRadius: 8)
                     marker.strokeColor = .systemPink
                     marker.lineWidth = 3
                     scene.addChild(marker)
                     let label = SKLabelNode(text: "SKRenderer OK")
                     label.fontName = "Menlo-Bold"
                     label.fontSize = 28
                     label.fontColor = .systemPink
                     label.position = CGPoint(x: size.width / 2, y: size.height - 90)
                     scene.addChild(label)
                     return scene
                 }))),
        ]
    }
}

extension DemoRegistry {
    static var groundTruthDemo: Demo {
        Demo(name: "core.glyphs", summary: "FakeBackdrop ground-truth glyph boxes (cyan) — sanity check for layout",
             payload: .scene(SceneDemo(duration: 0.1, captureTimes: [0], compositeOverBackdrop: true, scale: 2, make: { size in
                 let scene = SKScene(size: size)
                 scene.backgroundColor = .clear
                 for glyph in FakeBackdrop.groundTruthGlyphs(size: size) {
                     let box = SKShapeNode(rect: glyph.rect)
                     box.strokeColor = NSColor.cyan.withAlphaComponent(0.7)
                     box.lineWidth = 0.5
                     scene.addChild(box)
                 }
                 return scene
             })))
    }
}
