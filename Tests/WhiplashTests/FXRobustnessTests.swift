import SpriteKit
import XCTest
@testable import Whiplash

/// Hostile input the overlay can produce: whip tips off screen or on the very edge, creak cracks pushed past the
/// border, extreme or non-finite intensities, many heavy hits, repeated rounds.
final class FXRobustnessTests: XCTestCase {
    let size = DemoDefaults.screenSize
    let dt = 1.0 / 60

    private func run(_ layer: DestructionLayer, seconds: Double) {
        var t = 0.0
        while t < seconds { layer.step(dt: dt); t += dt }
    }

    func testPatternsOffScreenAndOnTheEdge() {
        let bounds = CGRect(origin: .zero, size: size)
        let points = [CGPoint(x: -40, y: 500), CGPoint(x: size.width + 10, y: -10), CGPoint(x: 0, y: 0),
                      CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: 600), CGPoint(x: 900, y: size.height)]
        for (i, point) in points.enumerated() {
            let p = CrackPattern.generate(center: point, intensity: 1, bounds: bounds, seed: UInt64(i + 1))
            for line in p.lines { XCTAssertEqual(line.points.count, line.arrivals.count) }
        }
    }

    func testNonsenseGlyphBoxesAreSkipped() {
        var glyphs = Array(FakeBackdrop.groundTruthGlyphs(size: size).prefix(20))
        let good = glyphs.count
        let junk = [CGRect(x: CGFloat.nan, y: 3, width: 8, height: 16), CGRect(x: 10, y: 10, width: 0, height: 16),
                    CGRect(x: 0, y: 0, width: size.width, height: size.height), CGRect(x: 5, y: 5, width: CGFloat.infinity, height: 9)]
        for rect in junk {
            glyphs.append(GlyphSample(text: "x", rect: rect, image: nil, color: .white, background: .black, fontSize: 14))
        }
        glyphs.append(GlyphSample(text: "y", rect: CGRect(x: 50, y: 50, width: 8, height: 16), image: nil, color: .white,
                                  background: .black, fontSize: .nan))
        let atlas = GlyphAtlas.build(glyphs: glyphs, sceneHeight: size.height, backdropScale: nil)
        XCTAssertEqual(atlas?.entries.count, good)
        let layer = DestructionLayer(size: size, backdrop: nil, glyphs: glyphs, seed: 1)
        XCTAssertEqual(layer.letterCount, good)
    }

    func testHostileRounds() {
        let texture = SKTexture(cgImage: FakeBackdrop.render(size: size, scale: 1).image)
        let glyphs = FakeBackdrop.groundTruthGlyphs(size: size)
        let rounds: [[(CGPoint, CGFloat)]] = [
            [(CGPoint(x: -40, y: 500), 1), (CGPoint(x: size.width + 30, y: size.height + 30), 2)],
            [(CGPoint(x: 0, y: 0), 2), (CGPoint(x: size.width, y: 0), 2), (CGPoint(x: 0, y: size.height), 2)],
            (0..<6).map { (CGPoint(x: 300 + Double($0) * 220, y: 300 + Double($0 % 2) * 400), 2) },
            [(CGPoint(x: 800, y: 500), 0.15), (CGPoint(x: 830, y: 520), 0.2), (CGPoint(x: 790, y: 470), 0)],
            [(CGPoint(x: 800, y: 500), .nan), (CGPoint(x: CGFloat.nan, y: 3), 1), (CGPoint(x: 700, y: 400), .infinity),
             (CGPoint(x: 700, y: 400), -3), (CGPoint(x: 900, y: 600), 1)],
            [(CGPoint(x: 820, y: 520), 1), (CGPoint(x: 820, y: 520), 1), (CGPoint(x: 820, y: 520), 1)],
        ]
        for backdrop in [texture, nil] {
            let layer = DestructionLayer(size: size, backdrop: backdrop, glyphs: glyphs, seed: 3)
            for (index, round) in rounds.enumerated() {
                for (point, intensity) in round {
                    layer.crack(at: point, intensity: intensity)
                    run(layer, seconds: 0.2)
                }
                var shattered = false, back = false
                // Text turns up at every possible moment: right before, during the break, mid-fall.
                if index % 3 == 0 { layer.setGlyphs(glyphs) }
                layer.shatter { shattered = true }
                if index % 3 == 1 { layer.setGlyphs(glyphs) }
                run(layer, seconds: 0.5)
                if index % 3 == 2 { layer.setGlyphs(glyphs) }
                run(layer, seconds: 1.9)
                XCTAssertTrue(shattered, "round \(index)")
                XCTAssertLessThanOrEqual(layer.shardCount, ShatterPlan.shardCountRange.upperBound)
                layer.reassemble { back = true }
                layer.setGlyphs(glyphs)
                run(layer, seconds: 3)
                XCTAssertTrue(back, "round \(index)")
                XCTAssertEqual(layer.shardCount, 0)
            }
        }
    }
}
