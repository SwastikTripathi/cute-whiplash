import SpriteKit
import XCTest
@testable import Whiplash

/// Records what the scene would have played.
final class RecordingSound: SoundPlaying {
    var enabled = true
    private(set) var played: [SFX] = []

    func prepare() {}
    func play(_ sfx: SFX, intensity: Float, pan: Float) {
        XCTAssertGreaterThanOrEqual(pan, -1)
        XCTAssertLessThanOrEqual(pan, 1)
        played.append(sfx)
    }

    func count(_ sfx: SFX) -> Int { played.filter { $0 == sfx }.count }
}

/// Steps a PunishmentScene by calling `update(_:)` directly at 60 fps — no view, no renderer.
private final class SceneClock {
    let scene: PunishmentScene
    private(set) var time: TimeInterval = 0

    init(_ scene: PunishmentScene) {
        self.scene = scene
    }

    /// Runs until `seconds` more have passed or the scene finishes; returns whether it finished.
    @discardableResult
    func run(for seconds: TimeInterval, each: ((TimeInterval) -> Void)? = nil) -> Bool {
        let end = time + seconds
        while time < end, !scene.isFinished {
            each?(time)
            scene.update(time)
            time += 1.0 / 60
        }
        return scene.isFinished
    }
}

final class OverlaySceneTests: XCTestCase {
    private let size = CGSize(width: 900, height: 600)

    private func makeScene(screenshot: Bool, glyphs: Bool, manual: Bool = false,
                           screenFrame: CGRect? = nil) -> (PunishmentScene, RecordingSound) {
        let frame = screenFrame ?? CGRect(origin: .zero, size: size)
        var plan = PunishmentPlan()
        plan.strikes = 3
        plan.targetRect = FakeBackdrop.terminalRect(for: size).offsetBy(dx: frame.minX, dy: frame.minY)
        plan.backdrop = screenshot ? FakeBackdrop.snapshot(size: size, scale: 1) : nil
        plan.glyphs = glyphs ? FakeBackdrop.groundTruthGlyphs(size: size, scale: 1) : []
        plan.isManual = manual
        let anchor = CoordinateSpace.cocoa(fromScene: IslandLayout.whipGrip(for: NotchGeometry.demo(size: size)), screenFrame: frame)
        let scene = PunishmentScene(plan: plan, screenFrame: frame, anchor: anchor, seed: 5)
        let sound = RecordingSound()
        scene.sound = sound
        return (scene, sound)
    }

    func testAutoPunishmentPlaysThroughAndReportsFinishedOnce() {
        let (scene, sound) = makeScene(screenshot: true, glyphs: true)
        var finished = 0
        scene.onFinished = { finished += 1 }
        let clock = SceneClock(scene)

        XCTAssertTrue(clock.run(for: 20))
        clock.run(for: 1)
        XCTAssertEqual(finished, 1)
        XCTAssertGreaterThanOrEqual(scene.sequencer.crackCount, 3)
        XCTAssertTrue(scene.sequencer.didShatter)
        XCTAssertGreaterThanOrEqual(sound.count(.crack), 3)
        XCTAssertGreaterThanOrEqual(sound.count(.glassCrack), 3)
        XCTAssertEqual(sound.count(.shatter), 1)
        XCTAssertEqual(sound.count(.buzz), 1)
        XCTAssertEqual(sound.count(.reassemble), 1)
    }

    func testSceneMatchesTheScreenAndUsesACamera() {
        let (scene, _) = makeScene(screenshot: true, glyphs: true)
        XCTAssertEqual(scene.size, size)
        XCTAssertNotNil(scene.camera)
        XCTAssertEqual(scene.camera?.position, CGPoint(x: size.width / 2, y: size.height / 2))
        XCTAssertEqual(scene.backgroundColor.alphaComponent, 0, "the window stays transparent; the bezel lives on the camera")
    }

    func testGlassModeHarvestsSyntheticTextAndFinishes() {
        let (scene, _) = makeScene(screenshot: false, glyphs: false)
        let clock = SceneClock(scene)
        clock.run(for: 0.1)
        XCTAssertTrue(scene.waitForGlyphs(timeout: 10))
        XCTAssertTrue(clock.run(for: 20))
        XCTAssertTrue(scene.sequencer.glyphsReady)
    }

    func testDismissMidStrikeClosesWithinPointFourSeconds() {
        let (scene, _) = makeScene(screenshot: true, glyphs: true)
        let clock = SceneClock(scene)
        clock.run(for: 1)
        scene.dismiss()
        let dismissedAt = clock.time
        XCTAssertTrue(clock.run(for: 2))
        XCTAssertLessThanOrEqual(clock.time - dismissedAt, 0.4 + 2.0 / 60)
    }

    /// Glass mode: the live screen stays visible and usable, so the overlay only wants clicks during the break.
    func testGlassModeOnlyWantsClicksDuringTheBreak() {
        let (scene, _) = makeScene(screenshot: false, glyphs: true)
        XCTAssertFalse(scene.capturesInput)
        var changes: [Bool] = []
        scene.onCapturesInputChanged = { changes.append($0) }
        let clock = SceneClock(scene)
        clock.run(for: 20) { _ in
            if scene.sequencer.phase == .holding { scene.interrupt() }
        }
        XCTAssertTrue(scene.isFinished)
        XCTAssertEqual(changes, [true, false])
    }

    /// Over a screenshot the live screen is hidden: clicks and keys must not reach it blind, from the first frame
    /// until the rewind — and a click before the shatter is the quick way out.
    func testScreenshotModeTakesInputFromTheStartAndAnEarlyClickLeaves() {
        let (scene, sound) = makeScene(screenshot: true, glyphs: true)
        XCTAssertTrue(scene.capturesInput, "from the very first frame")
        var changes: [Bool] = []
        scene.onCapturesInputChanged = { changes.append($0) }
        let clock = SceneClock(scene)
        clock.run(for: 1)
        XCTAssertTrue(scene.capturesInput)
        scene.interrupt()
        let clickedAt = clock.time
        XCTAssertTrue(clock.run(for: 2))
        XCTAssertLessThanOrEqual(clock.time - clickedAt, 0.4 + 2.0 / 60, "quick exit")
        XCTAssertEqual(changes, [false], "lets go once it winds down")
        XCTAssertEqual(sound.count(.shatter), 0)
    }

    func testAClickDuringTheBreakRewindsNormally() {
        let (scene, sound) = makeScene(screenshot: true, glyphs: true)
        var beats: [PunishmentBeat] = []
        scene.onBeat = { beats.append($0) }
        let clock = SceneClock(scene)
        clock.run(for: 20) { _ in
            if scene.sequencer.phase == .holding { scene.interrupt() }
        }
        XCTAssertTrue(scene.isFinished)
        XCTAssertTrue(scene.sequencer.didShatter)
        XCTAssertEqual(sound.count(.reassemble), 1, "a normal rewind, with its sound")
        XCTAssertEqual(beats, [.shatter, .breakLeft(seconds: Int(PunishmentPlan().holdSeconds)), .reassemble],
                       "the break counted down from its first second, then cut short")
        XCTAssertEqual(sound.count(.giggle), 1, "Lash cackles as the glass goes")
    }

    /// The whip hangs from the island, which never shakes: it rides on the camera, and its cracks land on the glass
    /// under its tip even while the glass is shaking.
    func testTheWhipStaysFixedToTheScreenWhileTheGlassShakes() {
        let (scene, _) = makeScene(screenshot: true, glyphs: true)
        let clock = SceneClock(scene)
        var worstDrift: CGFloat = 0, worstShake: CGFloat = 0
        clock.run(for: 4) { _ in
            if let camera = scene.camera {
                worstShake = max(worstShake, hypot(camera.position.x - scene.size.width / 2, camera.position.y - scene.size.height / 2))
            }
            guard let whip = scene.camera?.children.lazy.flatMap(\.children).first(where: { $0 is WhipNode }) else { return }
            // Where the whip's origin shows up on screen (the view shows the scene through the camera).
            let origin = scene.convert(.zero, from: whip)
            guard let camera = scene.camera else { return }
            let local = camera.convert(origin, from: scene)
            let onScreen = CGPoint(x: local.x + scene.size.width / 2, y: local.y + scene.size.height / 2)
            worstDrift = max(worstDrift, hypot(onScreen.x, onScreen.y))
        }
        XCTAssertLessThan(worstDrift, 0.01, "the whip's origin is the screen's corner whatever the camera does")
        XCTAssertGreaterThan(worstShake, 2, "the camera did shake")
    }

    func testManualModeFollowsThePointerAndEscapeEndsIt() {
        let (scene, sound) = makeScene(screenshot: true, glyphs: true, manual: true)
        let clock = SceneClock(scene)
        clock.run(for: 1) { t in
            // Gentle hand movement: holding the whip, not flicking it.
            scene.pointerMoved(to: CGPoint(x: 300 + 40 * sin(t * 2), y: 300 + 30 * cos(t * 2)))
        }
        XCTAssertFalse(scene.isFinished)
        XCTAssertEqual(scene.sequencer.phase, .manual)
        scene.skip()
        XCTAssertTrue(clock.run(for: 3.5))
        XCTAssertEqual(sound.count(.reassemble), 1)
        XCTAssertEqual(sound.count(.shatter), 0)
    }

    func testManualModeReadsThePointerEveryFrame() {
        // Pulled out of the island: the island's window has the mouse (no events reach the overlay) until the button
        // is up, yet the whip follows the hand — a fast flick cracks it.
        let (scene, _) = makeScene(screenshot: true, glyphs: true, manual: true)
        var t = 0.0
        scene.pointerSource = { CGPoint(x: 700 + 500 * sin(t * 18), y: 500) }
        SceneClock(scene).run(for: 1.5) { t = $0 }
        XCTAssertGreaterThan(scene.stats.whipCracks, 0)

        let (still, _) = makeScene(screenshot: true, glyphs: true, manual: true)
        SceneClock(still).run(for: 1.5)
        XCTAssertEqual(still.stats.whipCracks, 0, "nothing to follow: it just hangs")
    }

    func testClicksDuringTheBreakSmashTheScreenWithoutEndingIt() {
        let (scene, sound) = makeScene(screenshot: true, glyphs: true)
        let clock = SceneClock(scene)
        scene.smash(at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(scene.stats.smashes, 0, "not before the break")
        while scene.sequencer.phase != .holding, clock.time < 20 { clock.run(for: 1.0 / 60) }
        XCTAssertEqual(scene.sequencer.phase, .holding)
        let cracks = sound.count(.crack)
        scene.smash(at: CGPoint(x: 200, y: 200))
        scene.smash(at: CGPoint(x: 260, y: 220))
        XCTAssertEqual(scene.stats.smashes, 1, "two blows at once count as one")
        clock.run(for: 0.3)
        scene.smash(at: CGPoint(x: size.width - 200, y: size.height - 200))
        XCTAssertEqual(scene.stats.smashes, 2)
        XCTAssertEqual(sound.count(.crack), cracks + 2, "every blow lands with a crack")
        XCTAssertEqual(scene.sequencer.phase, .holding, "smashing doesn't end the break")
        XCTAssertTrue(clock.run(for: 15), "and the break still ends on its own")
        XCTAssertEqual(sound.count(.reassemble), 1)
    }

    func testCocoaInputsBecomeSceneCoordinatesOnASecondaryScreen() {
        let frame = CGRect(x: 1728, y: -200, width: size.width, height: size.height)
        let (scene, _) = makeScene(screenshot: false, glyphs: true, screenFrame: frame)
        XCTAssertEqual(scene.target, FakeBackdrop.terminalRect(for: size))
        XCTAssertEqual(scene.whipAnchor, IslandLayout.whipGrip(for: NotchGeometry.demo(size: size)))
        let aim = StrikeTargeting.aimRegion(target: scene.target, sceneSize: size)
        for point in scene.sequencer.targets {
            XCTAssertTrue(aim.insetBy(dx: -0.5, dy: -0.5).contains(point))
        }
    }

    func testTearDownReleasesTheScene() {
        weak var weakScene: PunishmentScene?
        autoreleasepool {
            let (scene, _) = makeScene(screenshot: true, glyphs: true)
            SceneClock(scene).run(for: 0.5)
            scene.tearDown()
            XCTAssertTrue(scene.children.isEmpty)
            weakScene = scene
        }
        XCTAssertNil(weakScene, "callbacks must not keep the scene alive")
    }
}
