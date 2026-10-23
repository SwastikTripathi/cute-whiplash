import SpriteKit
import SwiftUI

extension DemoRegistry {
    static var whipDemos: [Demo] {
        [
            Demo(name: "whip.hang", summary: "Whip unfurls out of the notch and settles",
                 payload: .scene(SceneDemo(duration: 2.05, captureTimes: [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.55, 0.75, 1.0, 1.4, 2.0],
                                           make: WhipDemoScene.Script.hang.make, onFrame: WhipDemoScene.drive))),
            Demo(name: "whip.strike", summary: "One strike at the terminal centre, from the notch (+ target, ● crack)",
                 payload: .scene(SceneDemo(duration: 1.6, captureTimes: WhipDemoScene.Script.strike.captureTimes,
                                           make: WhipDemoScene.Script.strike.make, onFrame: WhipDemoScene.drive))),
            Demo(name: "whip.combo", summary: "Three chained strikes, incl. the terminal's bottom-left corner",
                 payload: .scene(SceneDemo(duration: 3.4, captureTimes: WhipDemoScene.Script.combo.captureTimes,
                                           make: WhipDemoScene.Script.combo.make, onFrame: WhipDemoScene.drive))),
            Demo(name: "whip.manual", summary: "Mouse-driven whip: lazy drift (no crack), then a hard flick → crack",
                 payload: .scene(SceneDemo(duration: 3.0, captureTimes: WhipDemoScene.Script.manual.captureTimes,
                                           make: WhipDemoScene.Script.manual.make, onFrame: WhipDemoScene.drive))),
            Demo(name: "whip.retract", summary: "Hanging whip reels back into the notch",
                 payload: .scene(SceneDemo(duration: 1.6, captureTimes: [0.5, 0.8, 0.9, 1.0, 1.1, 1.15, 1.2, 1.25, 1.3, 1.4, 1.55],
                                           make: WhipDemoScene.Script.retract.make, onFrame: WhipDemoScene.drive))),
        ]
    }
}

/// Hosts a WhipNode for the headless demos and marks targets (+) and cracks (●).
///
/// Time is driven from `SceneDemo.onFrame` (the harness calls it every frame; SKRenderer stops calling
/// `update(_:)` after the first frames under the demo clock).
final class WhipDemoScene: SKScene {
    /// What each demo does. The whip is deterministic, so a demo can be rehearsed off-screen first to find
    /// out when it cracks and capture frames right around those moments.
    enum Script {
        case hang, strike, combo, manual, retract

        func make(_ size: CGSize) -> SKScene {
            let term = FakeBackdrop.terminalRect(for: size)
            switch self {
            case .hang:
                return WhipDemoScene(size: size, length: 420)
            case .strike:
                let scene = WhipDemoScene(size: size, length: 0)
                scene.queueStrikes([CGPoint(x: term.midX, y: term.midY)])
                return scene
            case .combo:
                let scene = WhipDemoScene(size: size, length: 0)
                scene.queueStrikes([CGPoint(x: term.minX + 40, y: term.minY + 36),
                                    CGPoint(x: term.maxX - 150, y: term.midY + 60),
                                    CGPoint(x: term.midX - 80, y: term.maxY - 120)])
                return scene
            case .manual:
                let scene = WhipDemoScene(size: size, length: 0)
                scene.drivesMouse = true
                return scene
            case .retract:
                let scene = WhipDemoScene(size: size, length: 420)
                scene.retractAt = 0.8
                return scene
            }
        }

        /// Frames bracketing every crack (plus a few for context), found by a headless rehearsal.
        var captureTimes: [TimeInterval] {
            if let cached = Self.cache[self] { return cached }
            guard let scene = make(DemoDefaults.screenSize) as? WhipDemoScene else { return [] }
            var t: TimeInterval = 0
            while t < 4, scene.crackTimes.count < scene.pending.count || (scene.drivesMouse && t < 2.6) {
                WhipDemoScene.drive(scene, t)
                t += 1.0 / 60
            }
            var times: Set<Double> = self == .manual ? [0.2, 0.6, 1.0, 1.4] : [0.1, 0.25, 0.4, 0.55]
            let offsets: [Double] = scene.crackTimes.count > 1
                ? [-0.1, -0.05, 0, 0.05, 0.2]
                : [-0.2, -0.13, -0.08, -0.05, -0.03, 0, 0.03, 0.07, 0.12, 0.2, 0.35, 0.55]
            for crack in scene.crackTimes {
                for offset in offsets { times.insert(((crack + offset) * 60).rounded() / 60) }
            }
            let result = times.filter { $0 >= 0 }.sorted()
            Self.cache[self] = result
            return result
        }

        private static var cache: [Script: [TimeInterval]] = [:]
    }

    let whip: WhipNode
    private var retractAt: TimeInterval?
    /// Plays the scripted mouse of `whip.manual`.
    private var drivesMouse = false
    private var lastTime: TimeInterval?
    private var elapsed: TimeInterval = 0
    private var pending: [CGPoint] = []
    private var strikeIndex = 0
    private var mouseDown = false
    private(set) var crackTimes: [TimeInterval] = []

    init(size: CGSize, length: CGFloat) {
        let anchor = IslandLayout.whipGrip(for: NotchGeometry.demo(size: size))
        whip = WhipNode(anchor: anchor, length: length)
        super.init(size: size)
        backgroundColor = .clear
        addChild(whip)
        whip.onCrack = { [weak self] point, _ in self?.markCrack(point) }
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Frame driver for every whip demo.
    static func drive(_ scene: SKScene, _ t: TimeInterval) {
        guard let scene = scene as? WhipDemoScene else { return }
        if scene.drivesMouse { scene.driveMouse(at: t) }
        scene.advance(to: t)
    }

    /// Strikes run back to back, each chained from the previous one's completion (like the overlay does).
    private func queueStrikes(_ targets: [CGPoint]) {
        pending = targets
        for (i, target) in targets.enumerated() { addChild(Self.crosshair(at: target, label: "\(i + 1)")) }
        strikeNext()
    }

    private func strikeNext() {
        guard strikeIndex < pending.count else { return }
        let target = pending[strikeIndex]
        strikeIndex += 1
        whip.strike(at: target) { [weak self] in self?.strikeNext() }
    }

    /// The scripted mouse of `whip.manual`: grab near the notch, lazy loops, then a hard flick and a dead stop.
    private func driveMouse(at t: TimeInterval) {
        let start = CGPoint(x: 760, y: 900)
        func lazy(_ t: TimeInterval) -> CGPoint {
            CGPoint(x: start.x + 90 * sin(t * 2.0), y: start.y - 60 * (1 - cos(t * 1.6)))
        }
        if !mouseDown {
            mouseDown = true
            whip.beginManualControl(at: start)
        }
        let flickStart = 1.6, flickDuration = 0.1
        let from = lazy(flickStart)
        let u = WhipMath.smoothstep((t - flickStart) / flickDuration)
        // ~2400 pt/s to the right for 100 ms.
        let point = t < flickStart ? lazy(t) : CGPoint(x: from.x + 240 * u, y: from.y + 30 * u)
        whip.moveHandle(to: point)
    }

    private func advance(to t: TimeInterval) {
        let dt = max(0, t - (lastTime ?? t))
        lastTime = t
        elapsed += dt
        if let at = retractAt, elapsed >= at {
            retractAt = nil
            whip.retract()
        }
        whip.step(dt: dt)
    }

    private func markCrack(_ point: CGPoint) {
        crackTimes.append(elapsed)
        let dot = SKShapeNode(circleOfRadius: 7)
        dot.position = point
        dot.fillColor = .systemRed
        dot.strokeColor = .white
        dot.lineWidth = 2
        dot.zPosition = 200
        let label = SKLabelNode(text: "\(crackTimes.count)")
        label.fontName = "Menlo-Bold"
        label.fontSize = 13
        label.fontColor = .white
        label.position = CGPoint(x: 12, y: -18)
        dot.addChild(label)
        addChild(dot)
    }

    private static func crosshair(at point: CGPoint, label text: String) -> SKNode {
        let node = SKShapeNode()
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: -16, y: -16, width: 32, height: 32))
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            path.move(to: CGPoint(x: 8 * dx, y: 8 * dy))
            path.addLine(to: CGPoint(x: 26 * dx, y: 26 * dy))
        }
        node.path = path
        node.strokeColor = .systemTeal
        node.lineWidth = 2.5
        node.position = point
        node.zPosition = 199
        let label = SKLabelNode(text: text)
        label.fontName = "Menlo-Bold"
        label.fontSize = 14
        label.fontColor = .systemTeal
        label.position = CGPoint(x: 22, y: 12)
        node.addChild(label)
        return node
    }
}
