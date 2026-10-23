import SpriteKit
import SwiftUI

extension DemoRegistry {
    static var overlayDemos: [Demo] {
        [
            Demo(name: "overlay.auto",
                 summary: "Full auto punishment over the fake desktop screenshot: 3 strikes → shatter → hold → reassemble (≈8.3 s)",
                 payload: .scene(SceneDemo(duration: 17, captureTimes: OverlayDemo.times(every: 0.5, through: 17),
                                           compositeOverBackdrop: false,
                                           make: { OverlayDemo.scene(size: $0, screenshot: true, manual: false) },
                                           onFrame: OverlayDemo.awaitHarvest))),
            Demo(name: "overlay.island",
                 summary: "overlay.auto around the notch (2x) with the real island composited where its panel sits: one handle, in Lash's paw, coming out of the pill",
                 payload: .scene(SceneDemo(duration: 16.5, captureTimes: OverlayDemo.islandTimes,
                                           compositeOverBackdrop: false, scale: 2,
                                           crop: OverlayDemo.islandCrop(in: DemoDefaults.screenSize),
                                           make: { OverlayDemo.islandScene(size: $0) },
                                           onFrame: OverlayDemo.islandFrame))),
            Demo(name: "overlay.glass",
                 summary: "Glass mode (no screenshot): transparent overlay over the live screen, synthetic text, subtle shake",
                 payload: .scene(SceneDemo(duration: 17, captureTimes: OverlayDemo.times(every: 0.5, through: 17),
                                           compositeOverBackdrop: true,
                                           make: { OverlayDemo.scene(size: $0, screenshot: false, manual: false) },
                                           onFrame: OverlayDemo.awaitHarvest))),
            Demo(name: "overlay.manual",
                 summary: "Manual mode: a scripted mouse holds the whip, flicks it hard twice, then presses Esc",
                 payload: .scene(SceneDemo(duration: 5.5, captureTimes: OverlayDemo.times(every: 0.25, through: 5.5),
                                           compositeOverBackdrop: false,
                                           make: { OverlayDemo.scene(size: $0, screenshot: true, manual: true) },
                                           onFrame: OverlayDemo.scriptedMouse))),
            Demo(name: "overlay.smash",
                 summary: "The break: clicks smash the broken screen some more — cracks, a THWACK and falling letters on the glass that's left, dead pixels in the hole — then it all rewinds",
                 payload: .scene(SceneDemo(duration: 17, captureTimes: OverlayDemo.times(every: 0.5, through: 17),
                                           compositeOverBackdrop: false,
                                           make: { OverlayDemo.scene(size: $0, screenshot: true, manual: false) },
                                           onFrame: OverlayDemo.smashing))),
            Demo(name: "overlay.pull",
                 summary: "Pulling the whip out of the island's right end (2x): the handle slides out from under it, follows the hand, flicks, and reels back in on Esc",
                 payload: .scene(SceneDemo(duration: 5.5,
                                           captureTimes: OverlayDemo.times(every: 0.1, through: 1.2) + [1.6, 2.0, 2.1, 2.2, 2.6, 3.0, 3.3, 3.6, 4.0, 4.5, 5.5],
                                           compositeOverBackdrop: false, scale: 2,
                                           crop: OverlayDemo.islandCrop(in: DemoDefaults.screenSize),
                                           make: { OverlayDemo.pullScene(size: $0) },
                                           onFrame: OverlayDemo.pullingHand))),
            Demo(name: "overlay.dense",
                 summary: "kitty full-screen with dense text (2056×1329 @2x), real OCR, full auto punishment",
                 size: DenseBackdrop.screenSize,
                 payload: .scene(SceneDemo(duration: 17, captureTimes: OverlayDemo.times(every: 0.5, through: 17),
                                           compositeOverBackdrop: false,
                                           make: { _ in OverlayDemo.denseScene(manual: false) },
                                           onFrame: OverlayDemo.awaitHarvest))),
            Demo(name: "overlay.menubar",
                 summary: "The status-bar whip glyph on light and dark menu bars, actual size and zoomed",
                 size: CGSize(width: 420, height: 150),
                 payload: .view(ViewDemo(make: { AnyView(StatusIconPreview()) }, background: nil))),
        ]
    }
}

private enum OverlayDemo {
    static func times(every step: TimeInterval, through end: TimeInterval) -> [TimeInterval] {
        Array(stride(from: 0, through: end, by: step))
    }

    /// A punishment of the fake desktop's terminal, exactly as AppCoordinator would stage it (seeded, silent).
    static func scene(size: CGSize, screenshot: Bool, manual: Bool, anchor: CGPoint? = nil) -> SKScene {
        var plan = PunishmentPlan()
        plan.strikes = 3
        plan.targetRect = FakeBackdrop.terminalRect(for: size)
        plan.backdrop = screenshot ? FakeBackdrop.snapshot(size: size) : nil
        plan.message = "GO TOUCH GRASS"
        plan.isManual = manual
        let scene = PunishmentScene(plan: plan, screenFrame: CGRect(origin: .zero, size: size),
                                    anchor: anchor ?? IslandLayout.whipGrip(for: NotchGeometry.demo(size: size)), seed: 42)
        scene.sound = SilentSound()
        return scene
    }

    /// A punishment of kitty running full-screen with dense text (the user's setup), with real OCR.
    static func denseScene(manual: Bool) -> SKScene {
        let size = DenseBackdrop.screenSize
        var plan = PunishmentPlan()
        plan.strikes = 3
        plan.targetRect = DenseBackdrop.terminalRect
        plan.backdrop = DenseBackdrop.snapshot()
        plan.message = "GO TOUCH GRASS"
        plan.isManual = manual
        let scene = PunishmentScene(plan: plan, screenFrame: CGRect(origin: .zero, size: size),
                                    anchor: IslandLayout.whipGrip(for: NotchGeometry.demo(size: size)), seed: 42)
        scene.sound = SilentSound()
        return scene
    }

    // MARK: Island composite

    static let islandTimes: [TimeInterval] = Array(stride(from: 0.0, through: 3.3, by: 0.15)) + [3.5, 3.8, 4.4, 5.5, 9.0, 13.5, 14.5, 15.5, 16.5]

    /// The top-centre of the screen: the island, the notch and the whip's first ~350 pt.
    static func islandCrop(in size: CGSize) -> CGRect {
        CGRect(x: size.width / 2 - 450, y: size.height - 400, width: 900, height: 400)
    }

    /// overlay.auto with the island on top — its own window in the app, so here a sprite on the camera (fixed to the
    /// screen while the glass shakes), at the panel's exact frame. It follows the show's beats as the app's does.
    static func islandScene(size: CGSize) -> SKScene {
        let scene = self.scene(size: size, screenshot: true, manual: false)
        guard let punishment = scene as? PunishmentScene, let camera = scene.camera else { return scene }
        let island = IslandComposite(geometry: NotchGeometry.demo(size: size), sceneSize: size)
        camera.addChild(island)
        punishment.onBeat = { [weak island] in island?.beat($0) }
        return scene
    }

    /// Manual mode with the whip living in the island's right end, and the island on top as in `islandScene`.
    static func pullScene(size: CGSize) -> SKScene {
        let geometry = NotchGeometry.demo(size: size)
        let scene = self.scene(size: size, screenshot: true, manual: true, anchor: IslandLayout.whipPullGrip(for: geometry))
        scene.camera?.addChild(IslandComposite(geometry: geometry, sceneSize: size, manual: true))
        return scene
    }

    /// The hand, relative to where it grabbed the island's right end: (time, dx, dy). It pulls down and out, holds
    /// the whip, flicks it, and lets go (Esc) at `pullEscapeTime`.
    private static let pull: [(t: TimeInterval, dx: CGFloat, dy: CGFloat)] = [
        (0.0, 0, 0), (0.15, 2, -10), (0.7, 40, -230), (1.4, -60, -300), (1.8, -40, -290),
        (2.0, 60, -210), (2.08, -220, -430), (2.2, -160, -390), (2.8, -150, -380),
    ]
    private static let pullEscapeTime: TimeInterval = 3.0

    static func pullingHand(_ scene: SKScene, _ time: TimeInterval) {
        guard let scene = scene as? PunishmentScene else { return }
        if (pullEscapeTime ..< pullEscapeTime + 1.0 / 60).contains(time) { scene.skip() }
        let layout = IslandLayout(geometry: NotchGeometry.demo(size: scene.size))
        let zone = layout.whipPullRect(for: .closed) ?? .zero
        // Panel space → scene (the demo screen's origin is the scene's).
        let panel = layout.panelFrame(in: NotchGeometry.demo(size: scene.size))
        let grab = IslandLayout.cocoaPoint(fromPanel: CGPoint(x: zone.midX, y: zone.midY), panelFrame: panel)
        let next = pull.firstIndex { $0.t > time } ?? pull.count - 1
        let a = pull[max(0, next - 1)], b = pull[next]
        let span = b.t - a.t
        let u = span > 0 ? CGFloat(min(1, max(0, (time - a.t) / span))) : 1
        let eased = u * u * (3 - 2 * u)
        scene.pointerMoved(to: CGPoint(x: grab.x + a.dx + (b.dx - a.dx) * eased, y: grab.y + a.dy + (b.dy - a.dy) * eased))
    }

    /// Where the scripted clicks land during the break (fractions of the screen) and when, seconds into it.
    private static let smashes: [(t: TimeInterval, x: CGFloat, y: CGFloat)] = [
        (0.6, 0.12, 0.3), (1.0, 0.86, 0.62), (1.3, 0.5, 0.5), (1.7, 0.3, 0.75), (2.0, 0.7, 0.2), (2.3, 0.45, 0.45),
    ]
    private static var breakStart: TimeInterval?

    static func smashing(_ scene: SKScene, _ time: TimeInterval) {
        awaitHarvest(scene, time)
        guard let scene = scene as? PunishmentScene else { return }
        if time == 0 { breakStart = nil }
        guard scene.sequencer.phase == .holding else { return }
        let start = breakStart ?? time
        breakStart = start
        for smash in smashes where (start + smash.t ..< start + smash.t + 1.0 / 60).contains(time) {
            scene.smash(at: CGPoint(x: scene.size.width * smash.x, y: scene.size.height * smash.y))
        }
    }

    static func islandFrame(_ scene: SKScene, _ time: TimeInterval) {
        awaitHarvest(scene, time)
        (scene.camera?.children.first { $0 is IslandComposite } as? IslandComposite)?.time = time
    }

    /// The island panel as a sprite: ImageRenderer snapshots of the real IslandView (whipping, laughing hard at the
    /// shatter, smug once the screen rewinds), swapped on the scene's beats like AppCoordinator switches the model.
    private final class IslandComposite: SKSpriteNode {
        var time: TimeInterval = 0 {
            didSet { if let until = laughUntil, time >= until { laughUntil = nil; show(breakLeft.map(breakTexture) ?? whipping) } }
        }
        private let layout: IslandLayout
        private let whipping: SKTexture?
        private let laughing: SKTexture?
        private let smug: SKTexture?
        private var laughUntil: TimeInterval?
        /// The break's countdown, as the island shows it.
        private var breakLeft: Int?

        init(geometry: NotchGeometry, sceneSize: CGSize, manual: Bool = false) {
            let layout = IslandLayout(geometry: geometry)
            self.layout = layout
            whipping = Self.render(layout) { $0.phase = manual ? .manual : .whipping }
            laughing = Self.render(layout) { $0.phase = .whipping; $0.laughingHard = true }
            smug = Self.render(layout) { model in
                model.phase = .aftermath
                model.whipsToday = 1
                model.quip = "that's what you get"
            }
            let frame = layout.panelFrame(in: geometry)
            super.init(texture: whipping, color: .clear, size: frame.size)
            // The camera sits at the screen's centre.
            position = CGPoint(x: frame.midX - sceneSize.width / 2, y: frame.midY - sceneSize.height / 2)
            zPosition = 5000
        }

        required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func beat(_ beat: PunishmentBeat) {
            switch beat {
            case .shatter:
                show(laughing)
                laughUntil = time + AppCoordinator.bigLaughSeconds
            case .breakLeft(let seconds):
                breakLeft = seconds
                show(breakTexture(seconds))
            case .reassemble:
                laughUntil = nil
                breakLeft = nil
                show(smug)
            }
        }

        private func breakTexture(_ seconds: Int) -> SKTexture? {
            let laughing = laughUntil != nil
            return Self.render(layout) { model in
                model.phase = .whipping
                model.laughingHard = laughing
                model.breakSecondsLeft = seconds
                model.breakTaunt = "GO TOUCH GRASS"
            }
        }

        private func show(_ texture: SKTexture?) {
            if let texture { self.texture = texture }
        }

        private static func render(_ layout: IslandLayout, configure: (IslandModel) -> Void) -> SKTexture? {
            MainActor.assumeIsolated {
                let model = IslandModel()
                model.terminalName = "kitty"
                configure(model)
                let view = IslandView(model: model, ui: IslandUIState(layout: layout), lash: LashState(model: model))
                    .frame(width: layout.panelSize.width, height: layout.panelSize.height)
                    .environment(\.islandFrozenTime, 1000.35)
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                return renderer.cgImage.map { SKTexture(cgImage: $0) }
            }
        }
    }

    /// Simulated time runs far ahead of the OCR; let it catch up once, as it would in real time.
    static func awaitHarvest(_ scene: SKScene, _ time: TimeInterval) {
        guard time > 0 else { return } // the harvest starts with the first frame
        guard let scene = scene as? PunishmentScene else { return }
        scene.waitForGlyphs(timeout: 15)
        scene.waitForLetters(timeout: 20)
    }

    /// Where the scripted hand is: (time, fraction of the screen). Each flick is a slow wind-up, a snap and a
    /// recoil — the sudden reversal is what makes a real whip tip break the sound barrier.
    private static let hand: [(t: TimeInterval, x: CGFloat, y: CGFloat)] = [
        (0.0, 0.50, 0.50), (0.6, 0.46, 0.52),
        (0.9, 0.36, 0.62), (0.98, 0.62, 0.42), (1.1, 0.56, 0.46),
        (2.0, 0.55, 0.50),
        (2.3, 0.62, 0.70), (2.38, 0.45, 0.32), (2.5, 0.50, 0.38),
        (3.5, 0.50, 0.45),
    ]
    private static let escapeTime: TimeInterval = 3.6

    static func scriptedMouse(_ scene: SKScene, _ time: TimeInterval) {
        guard let scene = scene as? PunishmentScene else { return }
        if (escapeTime ..< escapeTime + 1.0 / 60).contains(time) { scene.skip() }
        let next = hand.firstIndex { $0.t > time } ?? hand.count - 1
        let a = hand[max(0, next - 1)], b = hand[next]
        let span = b.t - a.t
        let u = span > 0 ? CGFloat(min(1, max(0, (time - a.t) / span))) : 1
        let eased = u * u * (3 - 2 * u)
        scene.pointerMoved(to: CGPoint(x: scene.size.width * (a.x + (b.x - a.x) * eased),
                                       y: scene.size.height * (a.y + (b.y - a.y) * eased)))
    }

    /// Demos render headlessly and must stay quiet.
    private final class SilentSound: SoundPlaying {
        var enabled = false
        func prepare() {}
        func play(_ sfx: SFX, intensity: Float, pan: Float) {}
    }
}

/// The status-bar glyph as it sits in light and dark menu bars, next to the live menu header.
private struct StatusIconPreview: View {
    var body: some View {
        VStack(spacing: 0) {
            strip(background: Color(white: 0.92), ink: .black)
            strip(background: Color(white: 0.13), ink: .white)
        }
    }

    private func strip(background: Color, ink: Color) -> some View {
        HStack(spacing: 20) {
            Image(nsImage: StatusBarIcon.image)
                .renderingMode(.template)
                .foregroundStyle(ink)
            Image(nsImage: StatusBarIcon.makeImage(pointSize: 54))
                .renderingMode(.template)
                .foregroundStyle(ink)
            Text(StatusMenuController.workLine(work: 2052, threshold: 3000))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(ink)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
    }
}
