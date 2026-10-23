import AppKit
import SpriteKit
import XCTest
@testable import Whiplash

/// Every hit knocks the text around it loose right away — anywhere on the screen, not just the first lines.
final class FXHitTests: XCTestCase {
    static let rendered = DenseBackdrop.render()
    static let backdrop = SKTexture(cgImage: DenseBackdrop.snapshot(rendered).image)
    static let glyphs = DenseBackdrop.groundTruthGlyphs(rendered)
    let size = DenseBackdrop.screenSize
    let dt = 1.0 / 60

    private func layer(glyphs: [GlyphSample] = FXHitTests.glyphs) -> DestructionLayer {
        DestructionLayer(size: size, backdrop: Self.backdrop, glyphs: glyphs, seed: 11)
    }

    private func run(_ layer: DestructionLayer, _ seconds: Double) {
        for _ in 0..<Int(seconds / dt) { layer.step(dt: dt) }
    }

    /// A busy spot in the lower third of the dense terminal.
    private var lowImpact: CGPoint {
        let low = Self.glyphs.filter { $0.rect.midY < size.height / 3 }.sorted { $0.rect.midX < $1.rect.midX }
        let middle = low[low.count / 2].rect
        return CGPoint(x: middle.midX, y: middle.midY)
    }

    func testAHitKnocksTheLettersAroundItLooseRightAway() {
        let destruction = layer()
        let impact = lowImpact
        destruction.crack(at: impact, intensity: 1)
        run(destruction, 0.25)
        let loose = destruction.looseLetterHomes
        XCTAssertGreaterThanOrEqual(loose.count, 40, "a hit in the text knocks a patch loose within a quarter second")
        for home in loose {
            XCTAssertLessThan(abs(home.x - impact.x), 720, "only letters around the impact")
            XCTAssertLessThan(abs(home.y - impact.y), 460, "only letters around the impact")
        }
        XCTAssertFalse(loose.contains { $0.y > size.height * 0.66 }, "the top of the screen is untouched")
    }

    func testRewindBeforeAnyShatterBringsTheLettersBack() {
        let destruction = layer()
        destruction.crack(at: lowImpact, intensity: 1)
        run(destruction, 0.5)
        XCTAssertFalse(destruction.looseLetterHomes.isEmpty)
        var done = false
        destruction.reassemble { done = true }
        var elapsed = 0.0
        while !done, elapsed < 3 { destruction.step(dt: dt); elapsed += dt }
        XCTAssertTrue(done)
        XCTAssertGreaterThan(elapsed, 0.4, "the letters fly home instead of snapping back")
        XCTAssertLessThan(elapsed, 1.5)
        XCTAssertTrue(destruction.looseLetterHomes.isEmpty)
    }

    func testTheGlassCreakingDropsNothing() {
        let destruction = layer()
        destruction.crack(at: lowImpact, intensity: 1, bursts: false)
        run(destruction, 0.3)
        XCTAssertTrue(destruction.looseLetterHomes.isEmpty)
    }

    func testTextArrivingAfterAHitStillDropsThatHitsPatch() {
        let destruction = layer(glyphs: [])
        let impact = lowImpact
        destruction.crack(at: impact, intensity: 1)
        run(destruction, 0.2)
        destruction.setGlyphs(Self.glyphs)
        let deadline = Date().addingTimeInterval(30)
        while destruction.isPreparingLetters, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertGreaterThan(destruction.letterCount, 0)
        run(destruction, 0.25)
        let loose = destruction.looseLetterHomes
        XCTAssertGreaterThanOrEqual(loose.count, 40, "the late letters catch up with the earlier hit")
        XCTAssertFalse(loose.contains { hypot($0.x - impact.x, $0.y - impact.y) > 800 })
    }

    func testTheShatterLeavesTextFarFromTheHitsAlone() {
        let destruction = layer()
        destruction.crack(at: lowImpact, intensity: 1.2)
        destruction.crack(at: CGPoint(x: lowImpact.x + 140, y: lowImpact.y + 60), intensity: 1.2)
        run(destruction, 0.6)
        var done = false
        destruction.shatter { done = true }
        for _ in 0..<Int(3 / dt) where !done { destruction.step(dt: dt) }
        XCTAssertTrue(done)
        XCTAssertFalse(destruction.looseLetterHomes.contains { $0.y > size.height * 0.75 },
                       "text at the top of the screen stays where it is")
        XCTAssertGreaterThan(destruction.looseLetterHomes.count, 100)
    }

    func testPatchesWidenAtTheEdgeOfTheText() {
        // A hit just past the end of the text still gets a handful of letters.
        let lastLetter = Self.glyphs.filter { $0.rect.midY < size.height / 3 }.max { $0.rect.maxX < $1.rect.maxX }!.rect
        let destruction = layer()
        destruction.crack(at: CGPoint(x: lastLetter.maxX + 300, y: lastLetter.midY), intensity: 1)
        run(destruction, 0.3)
        XCTAssertFalse(destruction.looseLetterHomes.isEmpty)
    }

    func testLetterPatchScalingKeepsItsShapeAndLottery() {
        let patch = LetterPatch(center: FXVec(500, 300), intensity: 1, seed: 99)
        let big = patch.scaled(by: 1.5)
        XCTAssertEqual(big.center, patch.center)
        XCTAssertEqual(big.radii.x, patch.radii.x * 1.5, accuracy: 1e-9)
        let p = FXVec(560, 320)
        XCTAssertEqual(patch.takes(7, at: p), patch.takes(7, at: p))
        XCTAssertLessThan(big.reach(of: p), patch.reach(of: p))
    }
}

/// Strikes aim at the text when there is a screenshot to look at.
final class OverlayInkTargetingTests: XCTestCase {
    func testStrikesLandWhereTheTextIs() throws {
        let size = CGSize(width: 1600, height: 1000)
        // Dark screen with text only in the lower-left quarter.
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(white: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Menlo", size: 14)!, .foregroundColor: NSColor.white]
        for row in 0..<18 {
            ("ERROR ledger invariant violated: sum(debits) != sum(credits) \(row)" as NSString)
                .draw(at: CGPoint(x: 30, y: 60 + row * 22), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        let ink = try XCTUnwrap(InkMap(image: try XCTUnwrap(context.makeImage()), sceneSize: size))
        XCTAssertGreaterThan(ink.ink(in: CGRect(x: 0, y: 0, width: 800, height: 500)), 50 * ink.ink(in: CGRect(x: 800, y: 500, width: 800, height: 500)) + 1)

        var rng = SeededGenerator(seed: 3)
        let targets = StrikeTargeting.targets(count: 3, target: CGRect(origin: .zero, size: size), sceneSize: size, ink: ink, using: &rng)
        XCTAssertEqual(targets.count, 3)
        XCTAssertLessThan(targets[0].x, 800, "the volley centres on the text")
        XCTAssertLessThan(targets[0].y, 560)
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
