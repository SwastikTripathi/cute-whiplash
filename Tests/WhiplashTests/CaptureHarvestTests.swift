import Vision
import XCTest
@testable import Whiplash

/// TextHarvester against FakeBackdrop's terminal, whose exact glyphs are known (`groundTruthGlyphs`).
final class CaptureHarvestTests: XCTestCase {
    static let size = DemoDefaults.screenSize
    static let snapshot = FakeBackdrop.snapshot(size: size, scale: 2)
    static let terminal = FakeBackdrop.terminalRect(for: size)
    static let truth = FakeBackdrop.groundTruthGlyphs(size: size, scale: 2)

    /// One warm `.accurate` harvest of the terminal, shared by the tests that only inspect its output.
    static let terminalGlyphs: [GlyphSample] = runHarvest(focus: terminal).glyphs

    // MARK: - Accuracy and speed

    func testAccuracyAgainstGroundTruth() {
        let score = Score(Self.terminalGlyphs, truth: Self.truth)
        print("capture accuracy (.accurate):", score)
        XCTAssertGreaterThanOrEqual(score.matchedFraction, 0.95, "ground-truth glyphs with an OCR glyph centred in them")
        XCTAssertGreaterThanOrEqual(score.sameLetterFraction, 0.95, "matched glyphs that also read the right letter")
        XCTAssertGreaterThanOrEqual(score.meanIoU, 0.70)
        XCTAssertLessThanOrEqual(score.meanCentreError, 1.0, "mean horizontal centre error, points")
    }

    func testHarvestFitsTimeBudget() {
        _ = Self.terminalGlyphs // warm: the first Vision call of a process loads the model
        let times = (0..<3).map { _ in Self.runHarvest(focus: Self.terminal).seconds }.sorted()
        let whole = Self.runHarvest(focus: nil).seconds
        print(String(format: "capture timing: terminal median %.0f ms (min %.0f, max %.0f), whole screen %.0f ms",
                     times[1] * 1000, times[0] * 1000, times[2] * 1000, whole * 1000))
        XCTAssertLessThan(times[1], 0.7, "OCR must be done well before the glyphs are needed (~2–3 s after the first strike)")
        XCTAssertLessThan(whole, 0.7)
    }

    /// Documents why `.standard` uses `.accurate`: it reads better and, with ink-measured boxes, places them better.
    func testAccurateBeatsFast() {
        let fast = Self.runHarvest(focus: Self.terminal, recognition: .init(level: .fast, minimumTextHeight: 7))
        let fastScore = Score(fast.glyphs, truth: Self.truth)
        let accurateScore = Score(Self.terminalGlyphs, truth: Self.truth)
        print(String(format: "capture .fast: %.0f ms,", fast.seconds * 1000), fastScore)
        XCTAssertGreaterThanOrEqual(accurateScore.matchedFraction, fastScore.matchedFraction)
        XCTAssertGreaterThanOrEqual(accurateScore.sameLetterFraction, fastScore.sameLetterFraction)
        XCTAssertLessThanOrEqual(accurateScore.meanCentreError, fastScore.meanCentreError)
    }

    /// `prewarm()` only helps if its image makes Vision run the recognizer, not just the text detector.
    func testPrewarmImageIsReadable() throws {
        let image = try XCTUnwrap(TextHarvester.prewarmImage())
        let request = VNRecognizeTextRequest()
        TextHarvester.Recognition.standard.configure(request, regionHeight: CGFloat(image.height))
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        XCTAssertEqual(request.results?.first?.topCandidates(1).first?.string, "$ whip --crack")
    }

    // MARK: - Glyph contents

    func testCropsCoverTheirRectsExactly() {
        for glyph in Self.terminalGlyphs {
            guard let image = glyph.image else { return XCTFail("OCR glyph '\(glyph.text)' has no crop") }
            XCTAssertEqual(CGFloat(image.width), glyph.rect.width * 2, accuracy: 0.01)
            XCTAssertEqual(CGFloat(image.height), glyph.rect.height * 2, accuracy: 0.01)
            XCTAssertTrue(Self.terminal.contains(glyph.rect), "glyph '\(glyph.text)' at \(glyph.rect) leaves the focus")
            XCTAssertEqual(glyph.text.count, 1)
            XCTAssertFalse(glyph.text.first?.isWhitespace ?? true)
        }
    }

    func testColoursMatchTheTerminal() {
        let background = FakeBackdrop.terminalBackground
        var backgroundHits = 0, inkHits = 0, compared = 0
        for glyph in Self.terminalGlyphs {
            if distance(glyph.background, background) < 0.02 { backgroundHits += 1 }
            guard let truth = Self.truth.first(where: { $0.rect.contains(CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)) })
            else { continue }
            compared += 1
            if distance(glyph.color, truth.color) < 0.06 { inkHits += 1 }
        }
        print("capture colours: background \(backgroundHits)/\(Self.terminalGlyphs.count), ink \(inkHits)/\(compared)")
        XCTAssertGreaterThanOrEqual(Double(backgroundHits), 0.95 * Double(Self.terminalGlyphs.count))
        XCTAssertGreaterThanOrEqual(Double(inkHits), 0.90 * Double(compared))
    }

    func testFontSizeEstimate() {
        let terminalText = Self.terminalGlyphs.filter { $0.rect.maxY < Self.terminal.maxY - 30 } // below the title bar
        let sizes = terminalText.map(\.fontSize).sorted()
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertEqual(sizes[sizes.count / 2], FakeBackdrop.terminalFont.pointSize, accuracy: 0.5)
        XCTAssertGreaterThan(sizes.first ?? 0, 12.5)
        XCTAssertLessThan(sizes.last ?? .infinity, 17.5)
    }

    func testReadingOrder() {
        let glyphs = Self.terminalGlyphs
        for (a, b) in zip(glyphs, glyphs.dropFirst()) {
            if abs(a.rect.midY - b.rect.midY) < a.rect.height / 2 {
                XCTAssertLessThan(a.rect.midX, b.rect.midX, "'\(a.text)' then '\(b.text)' on one line")
            } else {
                XCTAssertGreaterThan(a.rect.midY, b.rect.midY, "'\(a.text)' then '\(b.text)': lines go top to bottom")
            }
        }
    }

    // MARK: - Capping, focus and cancellation

    func testCapKeepsTheTopOfTheText() {
        let capped = Self.runHarvest(focus: Self.terminal, maxGlyphs: 50).glyphs
        XCTAssertEqual(capped.count, 50)
        XCTAssertEqual(capped.map(\.text), Self.terminalGlyphs.prefix(50).map(\.text))
        XCTAssertEqual(Self.runHarvest(focus: Self.terminal, maxGlyphs: 0).glyphs.count, 0)
    }

    func testWithoutFocusTheWholeScreenIsRead() {
        let everything = Self.runHarvest(focus: nil).glyphs
        let outside = everything.filter { !Self.terminal.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
        XCTAssertGreaterThan(everything.count, Self.terminalGlyphs.count)
        XCTAssertGreaterThan(outside.count, 100, "menu bar and browser text")
        XCTAssertTrue(outside.map(\.text).joined().contains("Signs"))
        let screen = CGRect(origin: .zero, size: Self.size)
        XCTAssertTrue(everything.allSatisfy { screen.contains($0.rect) })
    }

    func testOffScreenFocusFallsBackToWholeScreen() {
        let offScreen = CGRect(x: -500, y: -500, width: 200, height: 200)
        let glyphs = Self.runHarvest(focus: offScreen, maxGlyphs: 4000).glyphs
        XCTAssertGreaterThan(glyphs.count, Self.terminalGlyphs.count)
    }

    func testCancellationStopsEarly() {
        _ = Self.terminalGlyphs // make sure the model is loaded, so timing measures the cancel, not the warm-up
        final class Box: @unchecked Sendable { var glyphs: [GlyphSample]? }
        let box = Box()
        let done = expectation(description: "cancelled harvest returns")
        let started = Date()
        let task = Task.detached {
            await TextHarvester.harvest(from: Self.snapshot, focus: Self.terminal, maxGlyphs: 4000)
        }
        task.cancel()
        Task.detached {
            box.glyphs = await task.value
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(box.glyphs?.count, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    // MARK: - Helpers

    struct Score: CustomStringConvertible {
        var truthCount = 0, matched = 0, sameLetter = 0
        var ious: [CGFloat] = [], centreErrors: [CGFloat] = []

        /// A ground-truth glyph is matched when some OCR glyph's centre lies inside its box.
        init(_ glyphs: [GlyphSample], truth: [GlyphSample]) {
            truthCount = truth.count
            for expected in truth {
                guard let found = glyphs.first(where: { expected.rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) })
                else { continue }
                matched += 1
                if found.text == expected.text { sameLetter += 1 }
                let overlap = found.rect.intersection(expected.rect)
                let intersection = overlap.width * overlap.height
                ious.append(intersection / (found.rect.width * found.rect.height + expected.rect.width * expected.rect.height - intersection))
                centreErrors.append(abs(found.rect.midX - expected.rect.midX))
            }
        }

        var matchedFraction: Double { Double(matched) / Double(max(1, truthCount)) }
        var sameLetterFraction: Double { Double(sameLetter) / Double(max(1, matched)) }
        var meanIoU: CGFloat { ious.isEmpty ? 0 : ious.reduce(0, +) / CGFloat(ious.count) }
        var meanCentreError: CGFloat { centreErrors.isEmpty ? .infinity : centreErrors.reduce(0, +) / CGFloat(centreErrors.count) }

        var description: String {
            let sorted = ious.sorted()
            return String(format: "matched %d/%d (%.1f%%), same letter %.1f%%, IoU mean %.2f / median %.2f / p10 %.2f, centre error mean %.2f pt, max %.2f pt",
                          matched, truthCount, 100 * matchedFraction, 100 * sameLetterFraction, meanIoU,
                          sorted.isEmpty ? 0 : sorted[sorted.count / 2], sorted.isEmpty ? 0 : sorted[sorted.count / 10],
                          meanCentreError, centreErrors.max() ?? 0)
        }
    }

    /// Runs a harvest to completion from synchronous test code (it never needs the main thread).
    static func runHarvest(focus: CGRect?, maxGlyphs: Int = 4000, recognition: TextHarvester.Recognition = .standard,
                           snapshot: ScreenSnapshot = snapshot) -> (glyphs: [GlyphSample], seconds: TimeInterval) {
        final class Box: @unchecked Sendable { var glyphs: [GlyphSample] = [] }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let started = Date()
        Task.detached {
            box.glyphs = await TextHarvester.harvest(from: snapshot, focus: focus, maxGlyphs: maxGlyphs, recognition: recognition)
            done.signal()
        }
        done.wait()
        return (box.glyphs, Date().timeIntervalSince(started))
    }

    private func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent))
    }
}
