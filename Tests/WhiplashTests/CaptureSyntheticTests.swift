import XCTest
@testable import Whiplash

/// TextHarvester.synthetic / SyntheticTerminal: glass-mode text that must look like a terminal and never
/// spill out of its window.
final class CaptureSyntheticTests: XCTestCase {
    let terminal = FakeBackdrop.terminalRect(for: DemoDefaults.screenSize)

    func testGlyphsStayInsideTheRegion() {
        let regions = [terminal, CGRect(x: -40, y: 900, width: 333, height: 181), CGRect(x: 5, y: 5, width: 120, height: 30)]
        for region in regions {
            for seed: UInt64 in [0, 1, 42] {
                let glyphs = SyntheticTerminal.glyphs(in: region, maxGlyphs: 10_000, seed: seed)
                XCTAssertFalse(glyphs.isEmpty, "\(region)")
                for glyph in glyphs {
                    XCTAssertTrue(region.contains(glyph.rect), "'\(glyph.text)' at \(glyph.rect) spills out of \(region)")
                }
            }
        }
    }

    func testCapAndCount() {
        XCTAssertEqual(TextHarvester.synthetic(in: terminal, maxGlyphs: 300).count, 300)
        XCTAssertTrue(TextHarvester.synthetic(in: terminal, maxGlyphs: 0).isEmpty)
        let full = SyntheticTerminal.glyphs(in: terminal, maxGlyphs: 10_000, seed: 3)
        XCTAssertGreaterThan(full.count, 800, "a busy terminal, not a sparse one")
        XCTAssertEqual(SyntheticTerminal.glyphs(in: terminal, maxGlyphs: 250, seed: 3).map(\.text),
                       full.prefix(250).map(\.text), "the cap keeps the top of the screen")
    }

    func testTooSmallRegionsGiveNothing() {
        XCTAssertTrue(TextHarvester.synthetic(in: .zero, maxGlyphs: 100).isEmpty)
        XCTAssertTrue(TextHarvester.synthetic(in: CGRect(x: 0, y: 0, width: 400, height: 12), maxGlyphs: 100).isEmpty)
        XCTAssertTrue(TextHarvester.synthetic(in: CGRect(x: 0, y: 0, width: 8, height: 400), maxGlyphs: 100).isEmpty)
    }

    func testMonospacedGrid() throws {
        let glyphs = SyntheticTerminal.glyphs(in: terminal, maxGlyphs: 10_000, seed: 9)
        let left = terminal.minX + SyntheticTerminal.insets.left
        let top = terminal.maxY - SyntheticTerminal.insets.top
        for glyph in glyphs {
            let column = (glyph.rect.minX - left) / SyntheticTerminal.advance
            let row = (top - glyph.rect.maxY) / SyntheticTerminal.lineHeight
            XCTAssertEqual(column, column.rounded(), accuracy: 1e-6)
            XCTAssertEqual(row, row.rounded(), accuracy: 1e-6)
            XCTAssertEqual(glyph.rect.width, SyntheticTerminal.advance, accuracy: 1e-9)
            XCTAssertEqual(glyph.rect.height, SyntheticTerminal.cellHeight, accuracy: 1e-9)
        }
        XCTAssertEqual(SyntheticTerminal.lineHeight / SyntheticTerminal.font.pointSize, 1.45, accuracy: 0.05)
        let first = try XCTUnwrap(glyphs.first)
        XCTAssertEqual(first.rect.maxY, top, accuracy: 1e-9, "text starts right under the title bar")
    }

    func testLooksLikeTerminalText() throws {
        let glyphs = SyntheticTerminal.glyphs(in: terminal, maxGlyphs: 10_000, seed: 5)
        for glyph in glyphs {
            XCTAssertNil(glyph.image)
            XCTAssertEqual(glyph.background.alphaComponent, 0, "glass mode: nothing to paint over")
            XCTAssertEqual(glyph.fontSize, 14)
            XCTAssertEqual(glyph.text.count, 1)
            XCTAssertFalse(glyph.text.first?.isWhitespace ?? true)
            XCTAssertTrue(SyntheticTerminal.Palette.all.contains(glyph.color), "unexpected colour for '\(glyph.text)'")
        }
        let colours = Set(glyphs.map(\.color))
        XCTAssertTrue(colours.isSuperset(of: [SyntheticTerminal.Palette.prompt, SyntheticTerminal.Palette.path,
                                              SyntheticTerminal.Palette.output, SyntheticTerminal.Palette.error]))
        // The last row is a fresh prompt with a cursor.
        let last = try XCTUnwrap(glyphs.last)
        XCTAssertEqual(last.text, "▌")
        let lastRow = glyphs.filter { $0.rect.minY == last.rect.minY }.map(\.text).joined()
        XCTAssertTrue(lastRow.hasSuffix("$▌"), lastRow)
    }

    func testSeedsTellDifferentStories() {
        let text = { (seed: UInt64) in SyntheticTerminal.glyphs(in: self.terminal, maxGlyphs: 10_000, seed: seed).map(\.text).joined() }
        XCTAssertEqual(text(11), text(11))
        XCTAssertNotEqual(text(11), text(12))
    }

    func testLongLinesWrapInsteadOfOverflowing() {
        // 20 columns: every command line wraps.
        let narrow = CGRect(x: 0, y: 0, width: SyntheticTerminal.advance * 20 + 28, height: 600)
        let screen = SyntheticTerminal.screen(rows: 25, columns: 20, seed: 1)
        XCTAssertEqual(screen.count, 25)
        XCTAssertTrue(screen.allSatisfy { $0.count <= 20 })
        XCTAssertTrue(SyntheticTerminal.glyphs(in: narrow, maxGlyphs: 10_000, seed: 1).allSatisfy { narrow.contains($0.rect) })
    }
}
