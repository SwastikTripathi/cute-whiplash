import AppKit
import SpriteKit

/// How a letter is drawn once it comes off the screen. Every letter of a kind shares one texture and one shader, so
/// SpriteKit draws them all in one batch however many are falling, and a sprite costs nothing until its letter
/// actually comes loose. Per-letter state is plain node properties — position, rotation, scale, `alpha`, and
/// `colorBlendFactor` against a black `color` for how far it has sunk into the dark (the shaders apply both through
/// `v_color_mix`) — plus one attribute, `a_color`, set when the sprite is made.
///
/// * Screenshot letters are sub-rects of the screenshot texture itself: no crops, no atlas, no pixel copies. The
///   shader un-composites each texel against the letter's background: ink colour, with alpha = how much ink covers
///   it. Drawn over its own background (its eraser) that gives back the screenshot exactly, so a letter coming loose
///   is invisible until it moves; over anything else it is just the letter, no box around it.
/// * Synthetic letters (glass mode, no screenshot) come from a small atlas of white characters, tinted with their
///   ink colour.
/// * Erasers paint a letter's background over the spot it leaves.
///
/// Colours reach the GPU as raw components in the screenshot's own colour space. SpriteKit draws texture bytes as
/// they are but converts an NSColor to sRGB, so an NSColor patch would not match a Display P3 screenshot.
enum LetterSprites {
    /// `a_color`: the background's raw RGB, and the strongest contrast of the letter's ink against it (0...1).
    static let screenshotShader = make("""
        vec4 p = texture2D(u_texture, v_tex_coord);
        vec3 bg = a_color.rgb;
        vec3 d = p.rgb - bg;
        vec3 ad = abs(d);
        float contrast = max(max(ad.r, ad.g), ad.b);
        // Never less opaque than it takes to keep the ink in gamut, or the round trip over the background would clip.
        vec3 room = mix(bg, vec3(1.0) - bg, step(vec3(0.0), d));
        vec3 need = ad / max(room, vec3(0.0001));
        float a = clamp(max(contrast / a_color.a, max(max(need.r, need.g), need.b)), 0.0, 1.0);
        // Below ~1.5 levels it is noise, not ink.
        a *= step(0.006, contrast);
        vec3 ink = clamp(p.rgb - (1.0 - a) * bg, vec3(0.0), vec3(a));
        gl_FragColor = vec4(ink, a) * v_color_mix;
        """)

    /// `a_color`: the ink's RGB. The texture is white coverage.
    static let syntheticShader = make("""
        float a = texture2D(u_texture, v_tex_coord).a;
        gl_FragColor = vec4(a_color.rgb * a, a) * v_color_mix;
        """)

    /// `a_color`: the background's raw RGB.
    static let eraserShader = make("gl_FragColor = vec4(a_color.rgb, 1.0);")

    /// Contrast below this counts as fully inked (faint text must not come out half transparent).
    static let minimumPeak = 40.0 / 255

    private static func make(_ body: String) -> SKShader {
        let shader = SKShader(source: "void main() {\n\(body)\n}")
        shader.attributes = [SKAttribute(name: "a_color", type: .vectorFloat4)]
        return shader
    }

    static func setColor(_ color: SIMD4<Float>, on node: SKSpriteNode) {
        node.setValue(SKAttributeValue(vectorFloat4: color), forAttribute: "a_color")
    }

    /// The colour's components as stored, when it is an RGB colour (the harvester tags colours with the
    /// screenshot's colour space); anything else is converted to sRGB.
    static func rawComponents(_ color: NSColor) -> SIMD3<Float> {
        let rgb = (color.type == .componentBased && color.colorSpace.colorSpaceModel == .rgb ? color : nil)
            ?? color.usingColorSpace(.sRGB) ?? NSColor(white: 0, alpha: 1)
        return SIMD3(Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
    }

    /// `a_color` for a screenshot letter: its background and its ink's contrast against it.
    static func screenshotColor(ink: NSColor, background: NSColor) -> SIMD4<Float> {
        let bg = rawComponents(background), fg = rawComponents(ink)
        let d = abs(fg - bg)
        return SIMD4(bg, Float(max(Double(max(d.x, d.y, d.z)), minimumPeak)))
    }
}

/// Glass mode's letters: each distinct character (at each size) drawn once, white, in one small texture.
/// Pure value work (Core Graphics only): safe to build on a background queue.
struct SyntheticLetterAtlas {
    struct Key: Hashable {
        let text: String
        /// Cell size in points, rounded to a quarter point.
        let width: Int
        let height: Int
        let fontSize: Int

        init(_ glyph: GlyphSample) {
            text = glyph.text
            width = Int((glyph.rect.width * 4).rounded())
            height = Int((glyph.rect.height * 4).rounded())
            fontSize = Int((glyph.fontSize * 4).rounded())
        }
    }

    /// Premultiplied white coverage, rows bottom-up.
    let bitmap: FXBitmap
    /// Per key: its cell, unit coordinates, y-up (SpriteKit texture space), and the sprite's size in points (the
    /// glyph box plus `padding` all round).
    let cells: [Key: (rect: CGRect, size: CGSize)]

    static let scale: CGFloat = 2
    static let padding: CGFloat = 2

    init(glyphs: [GlyphSample]) {
        var samples: [Key: GlyphSample] = [:]
        for glyph in glyphs where samples[Key(glyph)] == nil { samples[Key(glyph)] = glyph }
        let keys = Array(samples.keys)
        let sizes = keys.map { key -> CGSize in
            let rect = samples[key]!.rect
            return CGSize(width: rect.width + 2 * Self.padding, height: rect.height + 2 * Self.padding)
        }
        // One row per 2048-pixel shelf, laid out in points on a virtual sheet.
        var origins: [CGPoint] = []
        var x = 0.0, y = 0.0, shelf = 0.0, width = 1.0
        for size in sizes {
            if (x + size.width) * Self.scale > 2048 { x = 0; y += shelf; shelf = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + 1
            shelf = max(shelf, size.height + 1)
            width = max(width, x)
        }
        let sheet = CGRect(x: 0, y: 0, width: width, height: max(1, y + shelf))
        bitmap = FXBitmap(covering: sheet, scale: Self.scale) { ctx in
            for (i, key) in keys.enumerated() {
                Self.draw(samples[key]!, in: CGRect(origin: origins[i], size: sizes[i]), ctx: ctx)
            }
        }
        var cells: [Key: (rect: CGRect, size: CGSize)] = [:]
        for (i, key) in keys.enumerated() {
            cells[key] = (CGRect(x: origins[i].x / sheet.width, y: origins[i].y / sheet.height,
                                 width: sizes[i].width / sheet.width, height: sizes[i].height / sheet.height), sizes[i])
        }
        self.cells = cells
    }

    /// Centred horizontally in its box and sitting on the box's bottom, like terminal text.
    private static func draw(_ glyph: GlyphSample, in cell: CGRect, ctx: CGContext) {
        let fontSize = max(glyph.fontSize, 6)
        let font = NSFont(name: "Menlo", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let text = NSAttributedString(string: glyph.text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: CGPoint(x: cell.minX + padding + (glyph.rect.width - size.width) / 2,
                              y: cell.minY + padding + max(0, (glyph.rect.height - size.height) / 2)))
        NSGraphicsContext.restoreGraphicsState()
    }
}
