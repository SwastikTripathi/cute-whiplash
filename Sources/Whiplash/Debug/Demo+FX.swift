import SpriteKit
import SwiftUI

extension DemoRegistry {
    static var fxDemos: [Demo] {
        [
            FXDemo.demo("fx.crack", "One crack growing out of an impact (fast, then creeping), with chips and a glint",
                        duration: 1.05, captures: [0, 0.03, 0.06, 0.1, 0.2, 0.4, 1.0], scale: 2) { layer, t, fired in
                FXDemo.once(&fired, "hit", t >= 0) { layer.crack(at: FXDemo.impacts[0], intensity: 1) }
            },
            FXDemo.demo("fx.webs", "Three hits accumulating: new cracks stop at old ones, refraction cells, glints",
                        duration: 3.05, captures: [0.05, 0.3, 0.95, 1.3, 1.85, 2.2, 3.0], scale: 2) { layer, t, fired in
                FXDemo.strikes(layer, t, &fired, times: [0, 0.9, 1.8])
            },
            FXDemo.demo("fx.shatter", "3 cracks → shatter: the glass and the letters fall out, the display behind it dies (ink, dead lines)",
                        duration: 4.45, captures: stride(from: 1.0, through: 4.4, by: 0.2).map { $0 }, scale: 2) { layer, t, fired in
                FXDemo.strikes(layer, t, &fired, times: [0, 0.35, 0.7])
                FXDemo.once(&fired, "shatter", t >= 1.25) { layer.shatter() }
            },
            FXDemo.demo("fx.moment", "The instant of the shatter, frame by frame: light bursts, loosening wave, first shards and letters",
                        duration: 1.75, captures: [1.24, 1.27, 1.3, 1.34, 1.38, 1.44, 1.5, 1.6, 1.7], scale: 2) { layer, t, fired in
                FXDemo.strikes(layer, t, &fired, times: [0, 0.35, 0.7])
                FXDemo.once(&fired, "shatter", t >= 1.25) { layer.shatter() }
            },
            FXDemo.demo("fx.glass", "Glass mode (no screenshot): translucent slivers, synthetic letters over the live screen",
                        duration: 3.65, captures: [1.0, 1.3, 1.5, 1.7, 2.0, 2.4, 3.0, 3.6], backdrop: false,
                        syntheticText: true) { layer, t, fired in
                FXDemo.strikes(layer, t, &fired, times: [0, 0.35, 0.7])
                FXDemo.once(&fired, "shatter", t >= 1.25) { layer.shatter() }
            },
            FXDemo.demo("fx.reassemble", "Shatter, then everything rewinds into place; the last frame equals the first",
                        duration: 4.25, captures: [0, 0.9, 1.4, 2.2, 3.0, 3.15, 3.3, 3.45, 3.6, 3.75, 3.9, 4.2]) { layer, t, fired in
                FXDemo.strikes(layer, t, &fired, times: [0.1, 0.4, 0.7])
                FXDemo.once(&fired, "shatter", t >= 1.1) { layer.shatter() }
                FXDemo.once(&fired, "rewind", t >= 3.0) { layer.reassemble() }
            },
        ]
    }
}

/// Scripting helpers for the FX demos.
enum FXDemo {
    /// Impact points inside FakeBackdrop.terminalRect for the demo screen.
    static var impacts: [CGPoint] {
        let term = FakeBackdrop.terminalRect(for: DemoDefaults.screenSize)
        return [CGPoint(x: term.minX + term.width * 0.46, y: term.minY + term.height * 0.55),
                CGPoint(x: term.minX + term.width * 0.26, y: term.minY + term.height * 0.36),
                CGPoint(x: term.minX + term.width * 0.7, y: term.minY + term.height * 0.4)]
    }

    /// A scene hosting one DestructionLayer. The demo steps it from `onFrame` rather than `update(_:)`: the
    /// harness starts SKRenderer at time 0, which SpriteKit treats as "now", so `update(_:)` stops being called
    /// after the second frame.
    final class Scene: SKScene {
        let layer: DestructionLayer
        var fired: Set<String> = []
        var lastFrame: TimeInterval?

        init(size: CGSize, backdrop: Bool, syntheticText: Bool) {
            let texture = backdrop ? SKTexture(cgImage: FakeBackdrop.render(size: size, scale: 2).image) : nil
            var glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
            if syntheticText { glyphs = glyphs.map { var g = $0; g.image = nil; return g } }
            layer = DestructionLayer(size: size, backdrop: texture, glyphs: glyphs, seed: 42)
            super.init(size: size)
            backgroundColor = .clear
            addChild(layer)
        }

        required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }

    /// Cracks the glass at `impacts[i]` at `times[i]`.
    static func strikes(_ layer: DestructionLayer, _ t: TimeInterval, _ fired: inout Set<String>, times: [TimeInterval]) {
        for (i, time) in times.enumerated() {
            once(&fired, "strike\(i)", t >= time) { layer.crack(at: impacts[i % impacts.count], intensity: 1) }
        }
    }

    /// Runs `body` the first frame `condition` holds.
    static func once(_ fired: inout Set<String>, _ key: String, _ condition: Bool, _ body: () -> Void) {
        guard condition, fired.insert(key).inserted else { return }
        body()
    }

    static func demo(_ name: String, _ summary: String, duration: TimeInterval, captures: [TimeInterval], scale: CGFloat = 1,
                     backdrop: Bool = true, syntheticText: Bool = false,
                     script: @escaping (DestructionLayer, TimeInterval, inout Set<String>) -> Void) -> Demo {
        Demo(name: name, summary: summary, payload: .scene(SceneDemo(
            duration: duration, captureTimes: captures, compositeOverBackdrop: !backdrop, scale: scale,
            make: { size in Scene(size: size, backdrop: backdrop, syntheticText: syntheticText) },
            onFrame: { scene, t in
                guard let scene = scene as? Scene else { return }
                script(scene.layer, t, &scene.fired)
                scene.layer.step(dt: t - (scene.lastFrame ?? t))
                scene.lastFrame = t
            })))
    }
}
