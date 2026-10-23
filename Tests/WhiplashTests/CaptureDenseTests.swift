import Vision
import XCTest
@testable import Whiplash

/// TextHarvester on the user's setup: kitty full-screen with dense text (DenseBackdrop, 4112×2658 px).
final class CaptureDenseTests: XCTestCase {
    static let rendered = DenseBackdrop.render()
    static let snapshot = DenseBackdrop.snapshot(rendered)
    static let truth = DenseBackdrop.groundTruthGlyphs(rendered)

    func testReproCap() {
        let focus = DenseBackdrop.terminalRect
        _ = CaptureHarvestTests.runHarvest(focus: focus, maxGlyphs: 10, recognition: .standard, snapshot: Self.snapshot)
        let capped = CaptureHarvestTests.runHarvest(focus: focus, maxGlyphs: 900, recognition: .standard, snapshot: Self.snapshot)
        let all = CaptureHarvestTests.runHarvest(focus: focus, maxGlyphs: 100_000, recognition: .standard, snapshot: Self.snapshot)
        let fast = CaptureHarvestTests.runHarvest(focus: focus, maxGlyphs: 100_000,
                                                  recognition: .init(level: .fast, minimumTextHeight: 7), snapshot: Self.snapshot)
        let rows = Set(Self.truth.map { Int($0.rect.minY) }).sorted(by: >)
        func rowsCovered(_ glyphs: [GlyphSample]) -> Int {
            Set(glyphs.compactMap { g in Self.truth.first { $0.rect.contains(CGPoint(x: g.rect.midX, y: g.rect.midY)) }.map { Int($0.rect.minY) } }).count
        }
        print("DENSE truth \(Self.truth.count) glyphs in \(rows.count) rows")
        print(String(format: "DENSE cap 900: %d glyphs, %.0f ms, rows covered %d/%d, y %.0f...%.0f",
                     capped.glyphs.count, capped.seconds * 1000, rowsCovered(capped.glyphs), rows.count,
                     capped.glyphs.map(\.rect.minY).min() ?? 0, capped.glyphs.map(\.rect.maxY).max() ?? 0))
        print(String(format: "DENSE all accurate: %d glyphs, %.0f ms, rows %d; score %@", all.glyphs.count, all.seconds * 1000,
                     rowsCovered(all.glyphs), CaptureHarvestTests.Score(all.glyphs, truth: Self.truth).description))
        print(String(format: "DENSE all fast: %d glyphs, %.0f ms, rows %d; score %@", fast.glyphs.count, fast.seconds * 1000,
                     rowsCovered(fast.glyphs), CaptureHarvestTests.Score(fast.glyphs, truth: Self.truth).description))
    }
}

extension CaptureDenseTests {
    func testVisionOnly() throws {
        let image = Self.snapshot.image
        for level in [VNRequestTextRecognitionLevel.accurate, .fast, .accurate, .fast] {
            let request = VNRecognizeTextRequest()
            TextHarvester.Recognition(level: level, minimumTextHeight: 7).configure(request, regionHeight: 1329)
            let start = Date()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            print(String(format: "DENSE vision %@ %.0f ms, %d lines", level == .fast ? "fast" : "accurate",
                         Date().timeIntervalSince(start) * 1000, request.results?.count ?? 0))
        }
        // Bands in parallel
        for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
            let start = Date()
            let bands = 4
            DispatchQueue.concurrentPerform(iterations: bands) { i in
                let h = image.height / bands
                let rect = CGRect(x: 0, y: max(0, i * h - 40), width: image.width, height: min(image.height, h + 80))
                let crop = image.cropping(to: rect)!
                let request = VNRecognizeTextRequest()
                TextHarvester.Recognition(level: level, minimumTextHeight: 7).configure(request, regionHeight: CGFloat(crop.height) / 2)
                try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            }
            print(String(format: "DENSE vision 4 bands parallel %@ %.0f ms", level == .fast ? "fast" : "accurate", Date().timeIntervalSince(start) * 1000))
        }
    }
}
