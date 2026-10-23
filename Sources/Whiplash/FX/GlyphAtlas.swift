import AppKit
import SpriteKit

/// Every falling letter packed into one texture, so SpriteKit draws all of them in a single batch.
///
/// Screenshot crops are "un-composited" against the glyph's background colour: each pixel becomes the ink colour
/// with alpha = how much ink covers it. Drawn over its own background the sprite reproduces the screenshot
/// pixels exactly (so peeling a letter off is invisible until it moves), while over the dead panel or the wallpaper it
/// is just the letter — no dark box around it.
///
/// Pure value work (Core Graphics only): safe to build on a background queue.
struct GlyphAtlas {
    struct Entry {
        /// Where the sprite sits at rest, scene coordinates. For crops this is the crop's pixel-aligned rect, so
        /// texels land exactly on screen pixels.
        var rect: CGRect
        /// Sub-rect of the atlas in unit coordinates (SpriteKit's y-up texture space).
        var textureRect: CGRect
        /// Background to paint where the letter was.
        var background: NSColor
    }

    /// Premultiplied RGBA, rows top-down.
    let pixels: Data
    let width: Int
    let height: Int
    let entries: [Entry]

    /// Made straight from the bytes (`SKTexture(cgImage:)` converts pixel formats and costs far more).
    func texture() -> SKTexture {
        let texture = SKTexture(data: pixels, size: CGSize(width: width, height: height), flipped: true)
        texture.filteringMode = .linear
        return texture
    }

    /// Pixels between packed cells, so linear filtering never bleeds a neighbour in.
    private static let padding = 2
    /// Resolution of synthetic (font-rendered) glyphs.
    private static let syntheticScale: CGFloat = 2
    private static let maxWidth = 2048

    /// `backdropScale`: pixels per point of the screenshot the crops came from (to pixel-align their rects).
    /// Boxes that are not text at all (non-finite, empty, or larger than any letter or word) are skipped: they would
    /// break the packing or paint a huge eraser over the screen.
    static func build(glyphs: [GlyphSample], sceneHeight: CGFloat, backdropScale: CGFloat?) -> GlyphAtlas? {
        let glyphs = glyphs.filter { glyph in
            let r = glyph.rect
            return [r.minX, r.minY, r.width, r.height, glyph.fontSize].allSatisfy(\.isFinite)
                && r.width >= 0.5 && r.height >= 0.5 && r.width <= 800 && r.height <= 200 && glyph.fontSize <= 200
        }
        guard !glyphs.isEmpty else { return nil }
        // 1. Measure cells.
        struct Cell { var width: Int; var height: Int; var rect: CGRect; var x = 0; var y = 0 }
        var cells: [Cell] = glyphs.map { glyph in
            if let image = glyph.image {
                return Cell(width: image.width, height: image.height,
                            rect: alignedRect(for: glyph, image: image, sceneHeight: sceneHeight, backdropScale: backdropScale))
            }
            let rect = glyph.rect.insetBy(dx: -2, dy: -2)
            return Cell(width: Int(ceil(rect.width * syntheticScale)), height: Int(ceil(rect.height * syntheticScale)), rect: rect)
        }
        // 2. Shelf-pack, tallest first.
        let order = cells.indices.sorted { cells[$0].height > cells[$1].height }
        var x = padding, y = padding, shelf = 0, width = 0
        for i in order {
            if x + cells[i].width + padding > maxWidth { x = padding; y += shelf + padding; shelf = 0 }
            cells[i].x = x
            cells[i].y = y
            x += cells[i].width + padding
            shelf = max(shelf, cells[i].height)
            width = max(width, x)
        }
        let height = y + shelf + padding
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none

        // 3. Draw. Cell (x, y) is measured from the TOP of the atlas (CGImage row order); CG draws y-up.
        for (i, glyph) in glyphs.enumerated() {
            let cell = cells[i]
            let frame = CGRect(x: cell.x, y: height - cell.y - cell.height, width: cell.width, height: cell.height)
            if let image = glyph.image {
                ctx.draw(image, in: frame)
            } else {
                drawSynthetic(glyph, in: frame, cellRect: cell.rect, ctx: ctx)
            }
        }
        // 4. Un-composite the screenshot crops.
        if let data = ctx.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
            for (i, glyph) in glyphs.enumerated() where glyph.image != nil {
                unmix(pixels: pixels, bytesPerRow: width * 4, cell: (cells[i].x, cells[i].y, cells[i].width, cells[i].height),
                      background: rgb(glyph.background))
            }
        }
        guard let data = ctx.data else { return nil }
        let entries = glyphs.indices.map { i -> Entry in
            let c = cells[i]
            // SpriteKit texture space is y-up from the bottom of the image.
            let unit = CGRect(x: CGFloat(c.x) / CGFloat(width), y: CGFloat(height - c.y - c.height) / CGFloat(height),
                              width: CGFloat(c.width) / CGFloat(width), height: CGFloat(c.height) / CGFloat(height))
            return Entry(rect: c.rect, textureRect: unit, background: glyphs[i].background)
        }
        return GlyphAtlas(pixels: Data(bytes: data, count: width * height * 4), width: width, height: height, entries: entries)
    }

    /// The crop's own pixel grid in scene points, when it matches the documented cropping
    /// (`CoordinateSpace.imagePixels`); otherwise the glyph's rect.
    private static func alignedRect(for glyph: GlyphSample, image: CGImage, sceneHeight: CGFloat, backdropScale: CGFloat?) -> CGRect {
        let guess = (CGFloat(image.width) / max(glyph.rect.width, 0.01)).rounded()
        for scale in [backdropScale, guess].compactMap({ $0 }) where scale > 0 {
            let px = CoordinateSpace.imagePixels(fromScene: glyph.rect, sceneHeight: sceneHeight, scale: scale)
            if Int(px.width) == image.width, Int(px.height) == image.height {
                return CGRect(x: px.minX / scale, y: sceneHeight - px.maxY / scale, width: px.width / scale, height: px.height / scale)
            }
        }
        return glyph.rect
    }

    private static func drawSynthetic(_ glyph: GlyphSample, in frame: CGRect, cellRect: CGRect, ctx: CGContext) {
        let fontSize = max(glyph.fontSize, 6)
        let font = NSFont(name: "Menlo", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let text = NSAttributedString(string: glyph.text, attributes: [.font: font, .foregroundColor: glyph.color])
        let size = text.size()
        ctx.saveGState()
        ctx.translateBy(x: frame.minX, y: frame.minY)
        ctx.scaleBy(x: syntheticScale, y: syntheticScale)
        let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx
        // Centre horizontally in the glyph box; sit on the box's bottom like terminal text.
        let origin = CGPoint(x: (glyph.rect.minX - cellRect.minX) + (glyph.rect.width - size.width) / 2,
                             y: (glyph.rect.minY - cellRect.minY) + max(0, (glyph.rect.height - size.height) / 2))
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private static func rgb(_ color: NSColor) -> (Double, Double, Double) {
        let c = color.usingColorSpace(.sRGB) ?? NSColor(white: 0, alpha: 1)
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func unmix(pixels: UnsafeMutablePointer<UInt8>, bytesPerRow: Int, cell: (x: Int, y: Int, w: Int, h: Int),
                              background: (Double, Double, Double)) {
        let bg = [background.0 * 255, background.1 * 255, background.2 * 255]
        // The strongest ink in the crop is taken as fully opaque.
        var peak = 0.0
        for row in cell.y..<(cell.y + cell.h) {
            for col in cell.x..<(cell.x + cell.w) {
                let p = pixels + row * bytesPerRow + col * 4
                peak = max(peak, abs(Double(p[0]) - bg[0]), abs(Double(p[1]) - bg[1]), abs(Double(p[2]) - bg[2]))
            }
        }
        for row in cell.y..<(cell.y + cell.h) {
            for col in cell.x..<(cell.x + cell.w) {
                let p = pixels + row * bytesPerRow + col * 4
                let out = unmixed(pixel: (Double(p[0]), Double(p[1]), Double(p[2])), background: (bg[0], bg[1], bg[2]), peak: peak)
                p[0] = UInt8(out.0.rounded()); p[1] = UInt8(out.1.rounded()); p[2] = UInt8(out.2.rounded()); p[3] = UInt8(out.3.rounded())
            }
        }
    }

    /// Solves pixel = α·ink + (1−α)·background for one opaque pixel (0...255 channels), with α proportional to the
    /// pixel's contrast against the background (`peak` contrast ↦ α = 1). Returns premultiplied (r, g, b, a).
    static func unmixed(pixel: (Double, Double, Double), background: (Double, Double, Double), peak: Double) -> (Double, Double, Double, Double) {
        let d = (pixel.0 - background.0, pixel.1 - background.1, pixel.2 - background.2)
        let contrast = max(abs(d.0), abs(d.1), abs(d.2))
        // Below ~1 level it is compression noise, not ink.
        guard contrast > 1.5 else { return (0, 0, 0, 0) }
        // Never less opaque than it takes to keep the ink colour in gamut (else the round trip would clip).
        func needed(_ b: Double, _ delta: Double) -> Double { delta > 0 ? delta / max(255 - b, 1e-9) : -delta / max(b, 1e-9) }
        let gamut = max(needed(background.0, d.0), needed(background.1, d.1), needed(background.2, d.2))
        let alpha = min(1, max(contrast / max(peak, 40), gamut))
        func ink(_ b: Double, _ delta: Double) -> Double { min(255, max(0, b + delta / alpha)) }
        let a = alpha * 255
        return (ink(background.0, d.0) * alpha, ink(background.1, d.1) * alpha, ink(background.2, d.2) * alpha, a)
    }
}
