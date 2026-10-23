import Metal
import SpriteKit
import XCTest
@testable import Whiplash

final class FXDestructionLayerTests: XCTestCase {
    let size = DemoDefaults.screenSize
    let dt = 1.0 / 60
    lazy var impacts = FXDemo.impacts

    private func makeLayer(backdrop: SKTexture?, glyphs: [GlyphSample] = [], seed: UInt64 = 7) -> DestructionLayer {
        DestructionLayer(size: size, backdrop: backdrop, glyphs: glyphs, seed: seed)
    }

    private func run(_ layer: DestructionLayer, seconds: Double, until: () -> Bool = { false }) -> Double {
        var elapsed = 0.0
        while elapsed < seconds, !until() {
            layer.step(dt: dt)
            elapsed += dt
        }
        return elapsed
    }

    func testEventsAndCompletionsFireOnceInOrder() {
        let backdrop = SKTexture(cgImage: FakeBackdrop.snapshot(size: size).image)
        let layer = makeLayer(backdrop: backdrop, glyphs: FakeBackdrop.groundTruthGlyphs(size: size))
        var events: [(String, Double)] = []
        var clock = 0.0
        layer.onEvent = { event in
            switch event {
            case .cracked: events.append(("cracked", clock))
            case .shatterBegan: events.append(("shatterBegan", clock))
            case .glyphLanded: events.append(("landed", clock))
            case .reassembleBegan: events.append(("reassembleBegan", clock))
            case .reassembled: events.append(("reassembled", clock))
            }
        }
        func advance(_ seconds: Double, until: () -> Bool = { false }) {
            var t = 0.0
            while t < seconds, !until() { layer.step(dt: dt); t += dt; clock += dt }
        }
        for point in impacts {
            layer.crack(at: point, intensity: 1)
            advance(0.35)
        }
        var shattered = 0
        let shatterAt = clock
        layer.shatter { shattered += 1 }
        advance(3, until: { shattered > 0 })
        XCTAssertEqual(shattered, 1)
        let settle = clock - shatterAt
        XCTAssertGreaterThan(settle, 1.2)
        XCTAssertLessThanOrEqual(settle, DestructionLayer.Tuning.shatterSettleLimit + dt)
        advance(1)
        XCTAssertEqual(shattered, 1, "completion must not fire twice")

        var reassembled = 0
        let rewindAt = clock
        layer.reassemble { reassembled += 1 }
        advance(3, until: { reassembled > 0 })
        XCTAssertEqual(reassembled, 1)
        XCTAssertEqual(clock - rewindAt, 2.15, accuracy: 0.3, "the rewind glides home in about 2 s (pieces 1.45 s, then the cracks retract)")

        let names = events.map(\.0).filter { $0 != "landed" }
        XCTAssertEqual(names, ["cracked", "cracked", "cracked", "shatterBegan", "reassembleBegan", "reassembled"])
        let landings = events.filter { $0.0 == "landed" }.map(\.1)
        XCTAssertFalse(landings.isEmpty, "some letters land on the bottom edge")
        for (a, b) in zip(landings, landings.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, DestructionLayer.Tuning.landedEventInterval - 1e-9, "throttled")
        }

        // The layer is reusable afterwards.
        layer.crack(at: impacts[0], intensity: 0.8)
        XCTAssertEqual(events.last?.0, "cracked")
    }

    /// Glass mode: the live screen keeps showing the real text around the hole, so only the letters on the broken
    /// glass fall out (the dead panel covers the real ones under it); the ring around the hits, which drops over a
    /// screenshot, sits the shatter out rather than showing doubled copies of text that is still there.
    func testGlassModeOnlyDropsTheLettersOnTheBrokenGlass() {
        func shatter(_ layer: DestructionLayer) -> (loose: Int, landed: Int) {
            var landed = 0
            layer.onEvent = { if case .glyphLanded = $0 { landed += 1 } }
            for point in impacts {
                layer.crack(at: point, intensity: 1)
                _ = run(layer, seconds: 0.35)
            }
            var shattered = false
            layer.shatter { shattered = true }
            _ = run(layer, seconds: 3, until: { shattered })
            XCTAssertTrue(shattered)
            return (layer.looseLetterHomes.count, landed)
        }
        let glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
        let glass = makeLayer(backdrop: nil, glyphs: glyphs)
        let inGlass = shatter(glass)
        let screenshot = shatter(makeLayer(backdrop: SKTexture(cgImage: FakeBackdrop.snapshot(size: size).image), glyphs: glyphs))
        XCTAssertGreaterThan(inGlass.landed, 0, "the letters on the broken glass fall out, down to the floor")
        XCTAssertLessThan(inGlass.loose, screenshot.loose, "no ring of doubled letters around the hole")
        var reassembled = false
        glass.reassemble { reassembled = true }
        _ = run(glass, seconds: 3, until: { reassembled })
        XCTAssertTrue(reassembled)
    }

    /// During the break you can smash the broken screen some more: a new crack where there's glass left, knocking
    /// letters off; nothing to crack where the glass is gone. It all rewinds with the rest.
    func testSmashingTheBrokenScreenDuringTheBreak() {
        let glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
        let layer = makeLayer(backdrop: SKTexture(cgImage: FakeBackdrop.snapshot(size: size).image), glyphs: glyphs)
        layer.smash(at: impacts[0], intensity: 1)
        XCTAssertEqual(layer.crackCount, 0, "nothing to smash before the glass has broken (that's a crack)")
        for point in impacts {
            layer.crack(at: point, intensity: 1)
            _ = run(layer, seconds: 0.35)
        }
        var shattered = false
        layer.shatter { shattered = true }
        _ = run(layer, seconds: 3, until: { shattered })
        XCTAssertTrue(shattered)
        let cracks = layer.crackCount, loose = layer.looseLetterHomes.count

        // The letter furthest from every impact is on glass that's still there.
        func distance(_ p: CGPoint) -> CGFloat { impacts.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? 0 }
        let far = glyphs.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }.max { distance($0) < distance($1) }!
        layer.smash(at: far, intensity: 1)
        _ = run(layer, seconds: 0.6)
        XCTAssertEqual(layer.crackCount, cracks + 1, "a fresh crack in the glass that's left")
        XCTAssertGreaterThan(layer.looseLetterHomes.count, loose, "the letters round it are knocked off")

        layer.smash(at: impacts[0], intensity: 1)
        XCTAssertEqual(layer.crackCount, cracks + 1, "where the glass is gone there's nothing to crack")

        var reassembled = false
        layer.reassemble { reassembled = true }
        _ = run(layer, seconds: 5, until: { reassembled })
        XCTAssertTrue(reassembled)
        XCTAssertEqual(layer.crackCount, 0)
        XCTAssertTrue(layer.looseLetterHomes.isEmpty, "every letter back home")
        layer.smash(at: far, intensity: 1)
        XCTAssertEqual(layer.crackCount, 0, "whole again: nothing to smash")
    }

    func testReassembleDuringShatterRunsThePendingShatterCompletionFirst() {
        let layer = makeLayer(backdrop: nil)
        layer.crack(at: impacts[0], intensity: 1)
        _ = run(layer, seconds: 0.4)
        var order: [String] = []
        layer.shatter { order.append("shatter") }
        _ = run(layer, seconds: 0.3)
        layer.reassemble { order.append("reassemble") }
        layer.reassemble { order.append("reassemble 2") }
        XCTAssertEqual(order, ["shatter"])
        _ = run(layer, seconds: 3, until: { order.count == 3 })
        XCTAssertEqual(order, ["shatter", "reassemble", "reassemble 2"])
        // Nothing to undo: completes at once.
        var done = false
        layer.reassemble { done = true }
        XCTAssertTrue(done)
        // Shatter without any crack breaks the middle of the screen.
        var broke = false
        layer.shatter { broke = true }
        _ = run(layer, seconds: 3, until: { broke })
        XCTAssertTrue(broke)
    }

    func testLateGlyphsAreBakedInTheBackgroundOrFinishedAtTheShatter() {
        let glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
        let texture = SKTexture(cgImage: FakeBackdrop.render(size: size, scale: 2).image)

        // Delivered by the run loop while the glass is still whole.
        let calm = makeLayer(backdrop: texture)
        calm.setGlyphs(glyphs)
        XCTAssertEqual(calm.letterCount, 0, "baked off the main thread")
        let deadline = Date(timeIntervalSinceNow: 5)
        while calm.letterCount == 0, Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertEqual(calm.letterCount, glyphs.count)

        // The shatter comes first: finished with the shatter's background work, so they are erased from the shards
        // and fall. The glass gives way a moment after the call.
        let rushed = makeLayer(backdrop: texture)
        rushed.crack(at: impacts[0], intensity: 1)
        _ = run(rushed, seconds: 0.4)
        rushed.setGlyphs(glyphs)
        var done = false
        rushed.shatter { done = true }
        XCTAssertEqual(rushed.shardCount, 0, "breaks a moment later")
        _ = run(rushed, seconds: DestructionLayer.Tuning.breakDelay + dt)
        XCTAssertGreaterThan(rushed.shardCount, 0)
        XCTAssertEqual(rushed.letterCount, glyphs.count)
        _ = run(rushed, seconds: 3, until: { done })
        XCTAssertTrue(done)

        // After the shatter: taken if none are in play, minus the ones on the broken glass.
        let late = makeLayer(backdrop: texture)
        late.crack(at: impacts[0], intensity: 1)
        _ = run(late, seconds: 0.4)
        var settled = false
        late.shatter { settled = true }
        late.setGlyphs(glyphs)
        _ = run(late, seconds: DestructionLayer.Tuning.breakDelay + dt)
        XCTAssertEqual(late.letterCount, glyphs.count)
        _ = run(late, seconds: 3, until: { settled })
        XCTAssertTrue(settled)
        late.setGlyphs(Array(glyphs.prefix(3)))
        XCTAssertEqual(late.letterCount, glyphs.count, "letters already in play are kept")

        // A rewind before the glass gave way keeps the letters for the next round.
        let cancelled = makeLayer(backdrop: texture)
        cancelled.crack(at: impacts[0], intensity: 1)
        _ = run(cancelled, seconds: 0.4)
        cancelled.setGlyphs(glyphs)
        var order: [String] = []
        cancelled.shatter { order.append("shatter") }
        cancelled.reassemble { order.append("reassemble") }
        XCTAssertEqual(order, ["shatter"])
        _ = run(cancelled, seconds: 2, until: { order.count == 2 })
        XCTAssertEqual(order, ["shatter", "reassemble"])
        XCTAssertEqual(cancelled.shardCount, 0)
        let resume = Date(timeIntervalSinceNow: 5)
        while cancelled.letterCount == 0, Date() < resume { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        XCTAssertEqual(cancelled.letterCount, glyphs.count)
    }

    /// With the kit prepared in the background (the app's run loop delivers it), the glass breaks on the call itself.
    func testPreparedKitBreaksImmediately() {
        let layer = makeLayer(backdrop: nil, glyphs: FakeBackdrop.groundTruthGlyphs(size: size))
        layer.crack(at: impacts[0], intensity: 1)
        _ = run(layer, seconds: 0.4)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
        layer.shatter()
        XCTAssertGreaterThan(layer.shardCount, 0, "no deferral when the kit is ready")
    }

    /// Whenever the rewind starts, it ends on exactly the pristine screenshot (so the overlay can hand back to the
    /// live screen without a visible seam).
    func testReassembleFromAnyMomentEndsPixelIdentical() throws {
        let image = FakeBackdrop.render(size: size, scale: 2).image
        let texture = SKTexture(cgImage: image)
        let glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
        let moments: [(String, (DestructionLayer) -> Void)] = [
            ("mid-crack", { layer in layer.crack(at: self.impacts[0], intensity: 1); _ = self.run(layer, seconds: 0.08) }),
            ("cracked", { layer in
                for p in self.impacts { layer.crack(at: p, intensity: 1); _ = self.run(layer, seconds: 0.4) }
            }),
            ("mid-shatter", { layer in
                for p in self.impacts { layer.crack(at: p, intensity: 1); _ = self.run(layer, seconds: 0.3) }
                layer.shatter()
                _ = self.run(layer, seconds: 0.45)
            }),
            ("shattered", { layer in
                for p in self.impacts { layer.crack(at: p, intensity: 1); _ = self.run(layer, seconds: 0.3) }
                layer.shatter()
                _ = self.run(layer, seconds: 3)
            }),
        ]
        for (name, scenario) in moments {
            let scene = SKScene(size: size)
            scene.backgroundColor = .clear
            let layer = makeLayer(backdrop: texture, glyphs: glyphs)
            scene.addChild(layer)
            let renderer = try XCTUnwrap(OffscreenRenderer(scene: scene, pointSize: size, scale: 1))
            renderer.update(atTime: 1)
            let before = try XCTUnwrap(renderer.snapshot())
            scenario(layer)
            renderer.update(atTime: 2)
            let broken = try XCTUnwrap(renderer.snapshot())
            XCTAssertGreaterThan(FXRender.difference(before, broken).mean, 0.05, "\(name): something visibly broke")
            var done = false
            layer.reassemble { done = true }
            _ = run(layer, seconds: 3, until: { done })
            XCTAssertTrue(done, name)
            renderer.update(atTime: 3)
            let after = try XCTUnwrap(renderer.snapshot())
            let diff = FXRender.difference(before, after)
            XCTAssertEqual(diff.max, 0, "\(name): \(diff)")
        }
    }

    /// Frame cost with ~150 shards and ~900 letters in flight, at the real screen's 2x resolution: `step(dt:)` +
    /// SpriteKit update + encode + GPU (waiting for completion), without the PNG read-back that
    /// `OffscreenRenderer.snapshot()` adds. Also reports the cost of the same frame with only the screenshot, and of
    /// the `shatter()` call itself. Run with `swift test -c release` for shipping numbers.
    func testFrameCostWhileEverythingFalls() throws {
        let image = FakeBackdrop.render(size: size, scale: 2).image
        var glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
        // Top up to ~900 letters with rows of synthetic text in the browser window.
        var slot = 0
        while glyphs.count < 900 {
            let rect = CGRect(x: 1100 + Double(slot % 56) * 9, y: 820 - Double(slot / 56) * 24, width: 9, height: 18)
            glyphs.append(GlyphSample(text: "x", rect: rect, image: nil, color: .darkGray, background: .white, fontSize: 15))
            slot += 1
        }
        let scene = SKScene(size: size)
        scene.backgroundColor = .clear
        let texture = SKTexture(cgImage: image)
        let layer = DestructionLayer(size: size, backdrop: texture, glyphs: glyphs, seed: 11)
        scene.addChild(layer)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(size.width * 2),
                                                                  height: Int(size.height * 2), mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        var clock = 1.0
        var gpu: [Double] = []
        func frame() -> Double {
            let start = CACurrentMediaTime()
            layer.step(dt: dt)
            clock += dt
            renderer.update(atTime: clock)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let commands = try! XCTUnwrap(queue.makeCommandBuffer())
            renderer.render(withViewport: CGRect(x: 0, y: 0, width: target.width, height: target.height),
                            commandBuffer: commands, renderPassDescriptor: pass)
            commands.commit()
            commands.waitUntilCompleted()
            gpu.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
            return (CACurrentMediaTime() - start) * 1000
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

        let strikes = impacts + [CGPoint(x: impacts[0].x + 170, y: impacts[0].y - 180), CGPoint(x: impacts[2].x - 40, y: impacts[2].y + 200)]
        for p in strikes {
            layer.crack(at: p, intensity: 1.4)
            for _ in 0..<20 { _ = frame() }
        }
        let cracking = (0..<30).map { _ in frame() }
        // In the app the run loop delivers the shatter kit prepared in the background meanwhile.
        let deadline = Date(timeIntervalSinceNow: 5)
        while !layer.isShatterReady, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            _ = frame()
        }
        XCTAssertTrue(layer.isShatterReady)
        let shatterStart = CACurrentMediaTime()
        layer.shatter()
        let shatterCall = (CACurrentMediaTime() - shatterStart) * 1000
        XCTAssertGreaterThan(layer.shardCount, 0, "broke on the spot")
        let firstFrame = frame()
        gpu = []
        let falling = (0..<66).map { _ in frame() }
        let fallingGPU = median(gpu)

        // The deferred path (kit not ready, e.g. the text arrived with the shatter): the call itself is cheap and the
        // glass gives way a few frames later; report the worst of those frames.
        let rushed = DestructionLayer(size: size, backdrop: texture, glyphs: [], seed: 12)
        for p in strikes.prefix(3) {
            rushed.crack(at: p, intensity: 1.4)
            for _ in 0..<20 { rushed.step(dt: dt) }
        }
        rushed.setGlyphs(glyphs)
        let rushedStart = CACurrentMediaTime()
        rushed.shatter()
        let rushedCall = (CACurrentMediaTime() - rushedStart) * 1000
        var rushedBreak = 0.0
        for _ in 0..<Int((DestructionLayer.Tuning.breakDelay / dt).rounded(.up)) + 1 {
            // Wall-clock pacing like a live 60 Hz display, so the background work gets its real head start.
            Thread.sleep(forTimeInterval: dt)
            let start = CACurrentMediaTime()
            rushed.step(dt: dt)
            rushedBreak = max(rushedBreak, (CACurrentMediaTime() - start) * 1000)
        }
        XCTAssertGreaterThan(rushed.shardCount, 0)

        // The same frame with nothing but the screenshot, for reference.
        layer.isHidden = true
        let plain = SKSpriteNode(texture: texture, size: size)
        plain.anchorPoint = .zero
        scene.addChild(plain)
        let baseline = (0..<40).map { _ in frame() }

        print(String(format: "FX perf: %d shards, %d letters, 2x — falling frame median %.2f ms (p90 %.2f, max %.2f, GPU %.2f), "
                     + "cracking frame %.2f ms, screenshot-only frame %.2f ms, shatter() call %.1f ms + its first frame %.1f ms; "
                     + "deferred: call %.2f ms, worst step until the break %.1f ms",
                     layer.shardCount, glyphs.count, median(falling), falling.sorted()[falling.count * 9 / 10],
                     falling.max() ?? 0, fallingGPU, median(cracking), median(baseline), shatterCall, firstFrame, rushedCall,
                     rushedBreak))
        XCTAssertGreaterThanOrEqual(layer.shardCount, 120)
        // Budget for the effects themselves (on top of drawing the screenshot, which the overlay pays anyway).
        #if DEBUG
        XCTAssertLessThan(median(falling) - median(baseline), 16, "debug build: generous bound; see the printed numbers")
        #else
        XCTAssertLessThan(median(falling) - median(baseline), 4, "release build must hold the 4 ms budget")
        #endif
    }
}
