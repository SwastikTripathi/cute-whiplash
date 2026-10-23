import SpriteKit
import XCTest
@testable import Whiplash

final class FXGlyphTests: XCTestCase {
    func testUnmixReproducesThePixelOverItsBackground() {
        var rng = FXRandom(seed: 8)
        for _ in 0..<2000 {
            let bg = (rng.range(0...255), rng.range(0...255), rng.range(0...255))
            let ink = (rng.range(0...255), rng.range(0...255), rng.range(0...255))
            let coverage = rng.unit()
            let pixel = (coverage * ink.0 + (1 - coverage) * bg.0, coverage * ink.1 + (1 - coverage) * bg.1,
                         coverage * ink.2 + (1 - coverage) * bg.2)
            let peak = max(abs(ink.0 - bg.0), abs(ink.1 - bg.1), abs(ink.2 - bg.2))
            let out = GlyphAtlas.unmixed(pixel: pixel, background: bg, peak: peak)
            // Premultiplied "over" the background.
            let a = out.3 / 255
            let composite = (out.0 + (1 - a) * bg.0, out.1 + (1 - a) * bg.1, out.2 + (1 - a) * bg.2)
            XCTAssertEqual(composite.0, pixel.0, accuracy: 1.6)
            XCTAssertEqual(composite.1, pixel.1, accuracy: 1.6)
            XCTAssertEqual(composite.2, pixel.2, accuracy: 1.6)
            XCTAssertLessThanOrEqual(out.0, out.3 + 1e-9, "premultiplied")
        }
        // Background itself is fully transparent: no dark box around falling letters.
        XCTAssertEqual(GlyphAtlas.unmixed(pixel: (23, 23, 33), background: (23, 23, 33), peak: 200).3, 0)
    }

    func testAtlasAlignsCropsToTheirPixelGrid() {
        let size = DemoDefaults.screenSize
        let glyphs = FakeBackdrop.groundTruthGlyphs(size: size, scale: 2)
        guard let atlas = GlyphAtlas.build(glyphs: glyphs, sceneHeight: size.height, backdropScale: 2) else {
            return XCTFail("no atlas")
        }
        XCTAssertEqual(atlas.entries.count, glyphs.count)
        for (entry, glyph) in zip(atlas.entries, glyphs) {
            // Pixel-aligned (whole pixels at 2x) and covering the glyph box.
            XCTAssertEqual((entry.rect.minX * 2).rounded(), entry.rect.minX * 2, accuracy: 1e-6)
            XCTAssertEqual((entry.rect.minY * 2).rounded(), entry.rect.minY * 2, accuracy: 1e-6)
            XCTAssertTrue(entry.rect.insetBy(dx: -0.01, dy: -0.01).contains(glyph.rect))
        }
        let synthetic = glyphs.prefix(50).map { var g = $0; g.image = nil; return g }
        XCTAssertNotNil(GlyphAtlas.build(glyphs: synthetic, sceneHeight: size.height, backdropScale: nil))
    }

    /// Erasers + un-composited letter sprites at rest must look exactly like the screenshot: the letters can only
    /// be seen leaving once they move.
    func testLettersPeelOffInvisibly() throws {
        let size = DemoDefaults.screenSize
        let image = FakeBackdrop.render(size: size, scale: 2).image
        let texture = SKTexture(cgImage: image)
        let pristine = try FXRender.image(size: size, scale: 2) { scene in
            scene.addChild(FXRender.backdrop(texture, size: size))
        }
        let peeled = try FXRender.image(size: size, scale: 2) { scene in
            scene.addChild(FXRender.backdrop(texture, size: size))
            let field = GlyphField(sceneSize: size, backdropMode: true, seed: 1)
            field.install(FakeBackdrop.groundTruthGlyphs(size: size, scale: 2), backdropScale: 2)
            field.erasers.isHidden = false
            field.surface.isHidden = false
            scene.addChild(field.erasers)
            scene.addChild(field.surface)
        }
        let diff = FXRender.difference(pristine, peeled)
        XCTAssertLessThan(diff.mean, 0.05, "\(diff)")
        XCTAssertLessThan(diff.fractionAbove2, 0.001, "\(diff)")
    }
}

/// Offscreen rendering helpers for FX tests.
enum FXRender {
    struct Difference: CustomStringConvertible {
        var max: Int
        var mean: Double
        /// Fraction of channel values that differ by more than 2 levels.
        var fractionAbove2: Double
        var description: String { String(format: "max %d, mean %.4f, >2: %.5f", max, mean, fractionAbove2) }
    }

    static func backdrop(_ texture: SKTexture, size: CGSize) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: texture, size: size)
        sprite.anchorPoint = .zero
        return sprite
    }

    static func image(size: CGSize, scale: CGFloat, _ build: (SKScene) -> Void) throws -> CGImage {
        let scene = SKScene(size: size)
        scene.backgroundColor = .clear
        build(scene)
        let renderer = try XCTUnwrap(OffscreenRenderer(scene: scene, pointSize: size, scale: scale))
        renderer.update(atTime: 1)
        return try XCTUnwrap(renderer.snapshot())
    }

    static func pixels(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    static func difference(_ a: CGImage, _ b: CGImage) -> Difference {
        let pa = pixels(a), pb = pixels(b)
        var maxDiff = 0, sum = 0, above = 0
        for i in pa.indices {
            let d = abs(Int(pa[i]) - Int(pb[i]))
            maxDiff = max(maxDiff, d)
            sum += d
            if d > 2 { above += 1 }
        }
        return Difference(max: maxDiff, mean: Double(sum) / Double(pa.count), fractionAbove2: Double(above) / Double(pa.count))
    }
}
