import XCTest
@testable import Whiplash

/// GlyphBoxes (character placement) and RegionPixels (pixel measurements) on hand-made inputs.
final class CaptureGeometryTests: XCTestCase {
    // MARK: - GlyphBoxes

    func testEvenSpansTileTheWord() {
        let spans = GlyphBoxes.evenSpans(of: CGRect(x: 10, y: 0, width: 40, height: 5), count: 4)
        XCTAssertEqual(spans, [10...20, 20...30, 30...40, 40...50])
        XCTAssertTrue(GlyphBoxes.evenSpans(of: .zero, count: 0).isEmpty)
    }

    func testDegenerateCharacterBoxesAreRejected() {
        let word = CGRect(x: 0, y: 0, width: 30, height: 10)
        XCTAssertNil(GlyphBoxes.characterSpans([word, word, word], in: word), "whole-word box for every character")
        XCTAssertNil(GlyphBoxes.characterSpans([CGRect(x: 1, y: 0, width: 5, height: 10), nil], in: word), "missing box")
        XCTAssertNil(GlyphBoxes.characterSpans([CGRect(x: 20, y: 0, width: 5, height: 10), CGRect(x: 2, y: 0, width: 5, height: 10)],
                                               in: word), "right to left")
        XCTAssertNil(GlyphBoxes.characterSpans([word], in: word), "a single character learns nothing new")
    }

    func testGenuineCharacterBoxesAreTiledBetweenTheirInk() {
        let word = CGRect(x: 0, y: 0, width: 15, height: 10)
        let boxes = [CGRect(x: 1, y: 0, width: 3, height: 10), CGRect(x: 5, y: 0, width: 4, height: 10),
                     CGRect(x: 10, y: 0, width: 4, height: 10)]
        XCTAssertEqual(GlyphBoxes.characterSpans(boxes, in: word), [1...4.5, 4.5...9.5, 9.5...14])
    }

    func testGridFindsTheGapsBetweenLetters() {
        // Five 10-wide cells from x = 3, ink in columns 2–7 of each cell.
        let profile = Self.profile(cellsFrom: 3, count: 5, pitch: 10, inkColumns: 2...7, width: 60)
        let spans = GlyphBoxes.gridSpans(profile, count: 5, pitch: 10) ?? []
        XCTAssertEqual(spans.count, 5)
        for (i, span) in spans.enumerated() {
            // Boundaries run down the middle of the 4-column gaps, to within the half-pixel search step.
            XCTAssertEqual(span.lowerBound, CGFloat(3 + 10 * i), accuracy: 0.25)
            XCTAssertEqual(span.upperBound - span.lowerBound, 10, accuracy: 0.001)
        }
        XCTAssertNil(GlyphBoxes.gridSpans(profile, count: 3, pitch: 10), "ink too wide for three cells")
        XCTAssertNil(GlyphBoxes.gridSpans(profile, count: 9, pitch: 10), "ink too narrow for nine cells")
    }

    func testMonospacedPitchIsRecoveredFromALine() {
        let pitch: CGFloat = 9.03
        let words = [31, 2, 4, 3, 5, 3] // "~/Documents/lightstick/Whiplash on main via swift 6.4"
        var column = 0
        var profiles: [(profile: GlyphBoxes.InkProfile, count: Int)] = []
        for count in words {
            profiles.append((Self.monospacedWord(startCell: column, count: count, pitch: pitch), count))
            column += count + 1
        }
        let found = GlyphBoxes.monospacedPitch(words: profiles)
        XCTAssertNotNil(found)
        XCTAssertEqual(found ?? 0, pitch, accuracy: pitch * 0.004)
    }

    func testProportionalTextHasNoPitch() {
        // Letters of very different widths (think "Wilma"), 1 pt apart: boundaries of any fixed grid cut ink.
        let widths: [CGFloat] = [12, 3, 3, 13, 7, 4, 11, 3, 8, 6]
        var profiles: [(profile: GlyphBoxes.InkProfile, count: Int)] = []
        for word in 0..<4 {
            var columns: [Int] = []
            for letter in 0..<5 {
                columns += Array(repeating: 6, count: Int(widths[(word * 3 + letter) % widths.count] * 2)) + [0, 0]
            }
            profiles.append((GlyphBoxes.InkProfile(originX: CGFloat(word) * 80, step: 0.5, columns: [0] + columns), 5))
        }
        XCTAssertNil(GlyphBoxes.monospacedPitch(words: profiles))
    }

    func testLayoutPlacesDegenerateVisionBoxesOnTheGrid() {
        // "Building for production": 10-wide cells from x = 2 with a space cell between words, ink in columns 1–8
        // of each cell. Vision's word boxes are loose, and every character box is the whole word's.
        let text = "Building for production"
        let line = CGRect(x: 0, y: 100, width: 250, height: 12)
        let wordCells = [0..<8, 9..<12, 13..<23]
        let looseWords = wordCells.map { CGRect(x: CGFloat(2 + $0.lowerBound * 10) - 3, y: 99, width: CGFloat($0.count * 10) + 6, height: 14) }
        let ink = Self.profile(cellsFrom: 2, count: 23, pitch: 10, inkColumns: 1...8, width: 260, skipping: [8, 12])
        let layout = GlyphBoxes.layout(text: text, lineBox: line, boxFor: { range in
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            return wordCells.firstIndex { $0.contains(offset) }.map { looseWords[$0] } // text offsets are cell indices
        }, inkProfile: { rect in
            let first = Int(rect.minX.rounded(.down)), last = Int(rect.maxX.rounded(.up))
            return GlyphBoxes.InkProfile(originX: CGFloat(first), step: 1,
                                         columns: (first..<last).map { ink.columns.indices.contains($0) ? ink.columns[$0] : 0 })
        })
        XCTAssertEqual(layout.pitch ?? 0, 10, accuracy: 0.1)
        XCTAssertEqual(layout.boxes.map(\.character), Array(text.filter { $0 != " " }))
        let cells = wordCells.flatMap { $0 }
        for (box, cell) in zip(layout.boxes, cells) {
            XCTAssertEqual(box.rect.minX, CGFloat(2 + cell * 10), accuracy: 0.5, "'\(box.character)'")
            XCTAssertEqual(box.rect.width, 10, accuracy: 0.1)
            XCTAssertEqual(box.rect.minY, line.minY)
            XCTAssertEqual(box.rect.height, line.height)
        }
    }

    func testLayoutWithoutAnyBoxesSplitsTheLine() {
        let layout = GlyphBoxes.layout(text: "ab  c", lineBox: CGRect(x: 0, y: 0, width: 50, height: 10), boxFor: { _ in nil })
        XCTAssertNil(layout.pitch)
        XCTAssertEqual(layout.boxes.map(\.character), ["a", "b", "c"])
        XCTAssertEqual(layout.boxes.map(\.rect.minX), [0, 10, 40])
        XCTAssertTrue(GlyphBoxes.layout(text: "   ", lineBox: CGRect(x: 0, y: 0, width: 50, height: 10), boxFor: { _ in nil }).boxes.isEmpty)
    }

    func testSeparateTrimsOverlapsAtTheirMidpoint() {
        let rects = [CGRect(x: 0, y: 0, width: 30, height: 5), CGRect(x: 20, y: 0, width: 30, height: 5),
                     CGRect(x: 60, y: 0, width: 10, height: 5)]
        let separated = GlyphBoxes.separate(rects)
        XCTAssertEqual(separated[0], CGRect(x: 0, y: 0, width: 25, height: 5))
        XCTAssertEqual(separated[1], CGRect(x: 25, y: 0, width: 25, height: 5))
        XCTAssertEqual(separated[2], rects[2])
    }

    func testReadingOrderGroupsFragmentsOfALine() {
        let lines = [
            CGRect(x: 300, y: 100, width: 50, height: 16), // second fragment of the top line, slightly lower
            CGRect(x: 10, y: 60, width: 200, height: 16),  // bottom line
            CGRect(x: 10, y: 102, width: 250, height: 16), // first fragment of the top line
        ]
        XCTAssertEqual(GlyphBoxes.readingOrder(of: lines), [2, 0, 1])
    }

    // MARK: - RegionPixels

    static let background = RegionPixels.RGB(r: 20, g: 20, b: 30)
    static let white = RegionPixels.RGB(r: 250, g: 250, b: 250)

    /// A 40 × 24 bitmap placed at (100, 50) in snapshot pixels: a "letter" at x 10–14, y 6–15 (bitmap coords),
    /// a neighbour letter touching its right side, an i-dot above x 20 and a faint smudge at the very top.
    func makePixels() throws -> RegionPixels {
        var pixels = [[RegionPixels.RGB]](repeating: .init(repeating: Self.background, count: 40), count: 24)
        for y in 6...15 { for x in 10...14 { pixels[y][x] = Self.white } }
        for y in 6...15 { for x in 17...18 { pixels[y][x] = Self.white } } // neighbour, 2 px right of the letter
        for y in 9...15 { pixels[y][25] = Self.white }                    // i stem
        pixels[6][25] = Self.white                                        // i dot, gap row 7–8
        pixels[0][12] = RegionPixels.RGB(r: 120, g: 120, b: 130)          // smudge touching the top edge
        let image = try XCTUnwrap(Self.image(pixels))
        return try XCTUnwrap(RegionPixels(image: image, origin: CGPoint(x: 100, y: 50)))
    }

    func testBackgroundIsTheRingMedianDespiteNeighbours() throws {
        let pixels = try makePixels()
        let letter = CGRect(x: 110, y: 56, width: 5, height: 10) // snapshot coords
        XCTAssertEqual(pixels.background(around: letter), Self.background)
        XCTAssertEqual(pixels.ink(in: letter, against: Self.background), Self.white)
    }

    func testInkBoundsTrimsStraysButKeepsIDots() throws {
        let pixels = try makePixels()
        // A loose "line box" over the letter reaching the top edge: the smudge row is cut off by empty rows.
        let letter = pixels.inkBounds(in: CGRect(x: 105, y: 50, width: 11, height: 20), against: Self.background, minimumDistance: 60)
        XCTAssertEqual(letter, CGRect(x: 110, y: 56, width: 5, height: 10))
        // The i-dot is separated from its stem too, but doesn't touch the box edge, so it stays.
        let i = pixels.inkBounds(in: CGRect(x: 123, y: 53, width: 5, height: 15), against: Self.background, minimumDistance: 60)
        XCTAssertEqual(i, CGRect(x: 125, y: 56, width: 1, height: 10))
        XCTAssertNil(pixels.inkBounds(in: CGRect(x: 130, y: 70, width: 5, height: 3), against: Self.background, minimumDistance: 60))
    }

    func testColumnInkCountsPerColumn() throws {
        let pixels = try makePixels()
        let columns = try XCTUnwrap(pixels.columnInk(in: CGRect(x: 108, y: 56, width: 12, height: 10),
                                                     against: Self.background, minimumDistance: 60))
        XCTAssertEqual(columns.firstColumn, 108)
        XCTAssertEqual(columns.counts, [0, 0, 10, 10, 10, 10, 10, 0, 0, 10, 10, 0])
    }

    func testColoursKeepTheImageColourSpace() throws {
        let pixels = try makePixels()
        let color = pixels.color(Self.white)
        XCTAssertEqual(color.colorSpace.cgColorSpace?.name as String?, CGColorSpace.sRGB as String)
        XCTAssertEqual(color.redComponent, 250 / 255, accuracy: 0.001)
        XCTAssertEqual(color.alphaComponent, 1)
    }

    // MARK: - Helpers

    /// A profile of `count` monospaced cells starting at x = `cellsFrom`, inked in `inkColumns` of each cell
    /// (step 1), with the cells listed in `skipping` left blank (spaces).
    static func profile(cellsFrom start: Int, count: Int, pitch: Int, inkColumns: ClosedRange<Int>, width: Int,
                        skipping spaces: Set<Int> = []) -> GlyphBoxes.InkProfile {
        let columns = (0..<width).map { x -> Int in
            let offset = x - start
            guard offset >= 0, offset / pitch < count, !spaces.contains(offset / pitch) else { return 0 }
            return inkColumns.contains(offset % pitch) ? 4 : 0
        }
        return GlyphBoxes.InkProfile(originX: 0, step: 1, columns: columns)
    }

    /// One word of Menlo-like letters at 2× (0.5 pt columns): each letter's side bearings vary between 0.4 and
    /// 2 pt, and the profile reaches 3 pt past the word on both sides, like a loose Vision box.
    static func monospacedWord(startCell: Int, count: Int, pitch: CGFloat) -> GlyphBoxes.InkProfile {
        let step: CGFloat = 0.5
        let originX = CGFloat(startCell) * pitch - 3
        let width = Int((CGFloat(count) * pitch + 6) / step)
        let columns = (0..<width).map { i -> Int in
            let x = originX + (CGFloat(i) + 0.5) * step
            let cell = Int((x / pitch).rounded(.down)) - startCell
            guard cell >= 0, cell < count else { return 0 }
            let inCell = x - CGFloat(cell + startCell) * pitch
            let left = 0.4 + CGFloat((cell * 7 + startCell) % 5) * 0.4
            let right = 0.4 + CGFloat((cell * 3 + startCell) % 5) * 0.4
            return inCell > left && inCell < pitch - right ? 8 : 0
        }
        return GlyphBoxes.InkProfile(originX: originX, step: step, columns: columns)
    }

    /// An sRGB image from rows of pixels, row 0 at the top.
    static func image(_ rows: [[RegionPixels.RGB]]) -> CGImage? {
        let height = rows.count, width = rows.first?.count ?? 0
        var bytes: [UInt8] = rows.flatMap { row in row.flatMap { pixel -> [UInt8] in [pixel.r, pixel.g, pixel.b, 255] } }
        return bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?
                .makeImage()
        }
    }
}
