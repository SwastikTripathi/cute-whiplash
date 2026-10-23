import AppKit
import SpriteKit

/// A premultiplied RGBA bitmap drawn with Core Graphics in scene coordinates. Safe to make on any queue; turn it
/// into a texture on the main thread. Rows are stored bottom-up — SpriteKit's order for data textures — so
/// `texture()` needs no flip copy.
struct FXBitmap {
    let bytes: Data
    let width: Int
    let height: Int

    /// Renders `draw` (scene coordinates) into a transparent bitmap covering `rect` at `scale` pixels per point.
    /// Draws straight into the bytes it keeps: no second full-size copy (these run to tens of MB at 2x).
    init(covering rect: CGRect, scale: CGFloat, _ draw: (CGContext) -> Void) {
        let width = max(1, Int((rect.width * scale).rounded())), height = max(1, Int((rect.height * scale).rounded()))
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Mirror vertically so memory row 0 is the bottom of `rect`.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            draw(ctx)
            return true
        }
        guard drawn else {
            self.init(bytes: Data(count: 4), width: 1, height: 1)
            return
        }
        self.init(bytes: bytes, width: width, height: height)
    }

    private init(bytes: Data, width: Int, height: Int) {
        self.bytes = bytes
        self.width = width
        self.height = height
    }

    /// Made straight from the bytes: `SKTexture(cgImage:)` converts pixel formats and costs ~20x more.
    func texture() -> SKTexture {
        let texture = SKTexture(data: bytes, size: CGSize(width: width, height: height), flipped: false)
        texture.filteringMode = .linear
        return texture
    }
}

/// Pieces of glass drawn as sprites. Each sprite shows its bounding box of a texture and is cut to its polygon by a
/// baked mask atlas; all pieces of a kind share ONE shader, so SpriteKit draws them in a single batch. (Shape nodes
/// can't do this: they ignore sub-texture rects, and batched shape nodes all get one node's attribute values.)
///
/// Per-piece state lives in attributes:
/// * `a_uvrect`   — the sprite's texture rect in its texture's UV space (to get piece-local coordinates).
/// * `a_maskrect` — the piece's cell in the mask atlas.
/// * `a_shade`    — (brightness multiplier, opacity, additive white sheen, edge-line opacity).
/// * `a_tint`     — glass-mode opacity of the pane itself.
/// * `a_glint`    — shards only: a specular band across the piece (direction xy, offset from the centre, strength),
///                  swept by the tumble so each falling piece flashes like glass catching the light.
enum GlassPieces {
    /// For each polygon: anti-aliased coverage (green) and a thin line just inside its edge (red), packed in one
    /// bitmap. Coverage is dilated by half a pixel so neighbouring pieces at rest show no seams.
    struct MaskAtlas {
        let bitmap: FXBitmap
        /// Per polygon: its bounding box in the scene.
        let boxes: [CGRect]
        /// Per polygon: its cell in the atlas, unit coordinates, y-up (SpriteKit texture space).
        let cells: [CGRect]

        static let scale: CGFloat = 2
        private static let padding: CGFloat = 2
        private static let maxWidth = 2048.0

        init(polygons: [[FXVec]], edgeWidth: CGFloat = 1.6) {
            let boxes = polygons.map { FXPolygon.bounds($0) }
            let scale = Self.scale, padding = Self.padding
            // Shelf-pack the boxes (in points, laid out on a virtual sheet).
            var origins: [CGPoint] = Array(repeating: .zero, count: boxes.count)
            var x = padding / scale, y = padding / scale, shelf = 0.0, width = 0.0
            let order = boxes.indices.sorted { boxes[$0].height > boxes[$1].height }
            for i in order {
                let box = boxes[i]
                if (x + box.width) * scale + padding > Self.maxWidth {
                    x = padding / scale
                    y += shelf + padding / scale
                    shelf = 0
                }
                origins[i] = CGPoint(x: x, y: y)
                x += box.width + padding / scale
                shelf = max(shelf, box.height)
                width = max(width, x)
            }
            let sheet = CGRect(x: 0, y: 0, width: width, height: y + shelf + padding / scale)
            bitmap = FXBitmap(covering: sheet, scale: scale) { ctx in
                ctx.setLineJoin(.round)
                for (i, polygon) in polygons.enumerated() {
                    let shift = CGPoint(x: origins[i].x - boxes[i].minX, y: origins[i].y - boxes[i].minY)
                    let path = FXPolygon.path(polygon.map { $0 + FXVec(shift.x, shift.y) })
                    ctx.saveGState()
                    ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
                    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
                    ctx.setLineWidth(1 / scale)
                    ctx.addPath(path)
                    ctx.drawPath(using: .fillStroke)
                    if edgeWidth > 0 {
                        // The edge line only inside the piece, added on top of the coverage.
                        ctx.addPath(path)
                        ctx.clip()
                        ctx.setBlendMode(.plusLighter)
                        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
                        ctx.setLineWidth(edgeWidth * 2)
                        ctx.addPath(path)
                        ctx.strokePath()
                    }
                    ctx.restoreGState()
                }
            }
            // The sheet is y-up like SpriteKit's texture space, so a cell's UV rect is just its sheet rect, scaled.
            let size = CGSize(width: bitmap.width, height: bitmap.height)
            cells = boxes.indices.map { i in
                CGRect(x: origins[i].x * scale / size.width, y: origins[i].y * scale / size.height,
                       width: boxes[i].width * scale / size.width, height: boxes[i].height * scale / size.height)
            }
            self.boxes = boxes
        }
    }

    enum Kind {
        /// Refraction cell of the screenshot.
        case backdropCell
        /// Falling shard of the screenshot, with the erase and crack overlays.
        case backdropShard
        /// Glass mode: faint reflective pane (the sprite's texture is the mask atlas itself).
        case glassCell
        /// Glass mode: translucent sliver (the sprite's texture is the crack overlay).
        case glassShard
    }

    /// Uniform values shared by every piece of one set.
    final class Uniforms {
        let crackAlpha = SKUniform(name: "u_crack_alpha", float: 1)
        let list: [SKUniform]

        /// `overlayRect` in screen UV (backdrop shards) or nil (the others).
        init(masks: SKTexture, erase: SKTexture? = nil, cracks: SKTexture? = nil, overlayRect: CGRect? = nil) {
            var list = [SKUniform(name: "u_masks", texture: masks), crackAlpha]
            if let erase { list.append(SKUniform(name: "u_erase", texture: erase)) }
            if let cracks { list.append(SKUniform(name: "u_cracks", texture: cracks)) }
            if let r = overlayRect {
                list.append(SKUniform(name: "u_orect", vectorFloat4: vector_float4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height))))
            }
            self.list = list
        }

        /// Fades baked crack lines (the vector cracks take over during the rewind).
        func setCrackAlpha(_ alpha: Double) { crackAlpha.floatValue = Float(alpha) }
    }

    static func shader(_ kind: Kind, uniforms: Uniforms) -> SKShader {
        // Common head: piece-local coordinates and the mask.
        let head = """
        vec2 local = (v_tex_coord - a_uvrect.xy) / a_uvrect.zw;
        vec4 m = texture2D(u_masks, a_maskrect.xy + local * a_maskrect.zw);
        """
        // A soft bright band across the piece: brightens opaque screenshot pieces, and lights up the nearly clear
        // glass-mode panes (premultiplied white where they are transparent).
        let glint = """
        float gd = dot(local - 0.5, a_glint.xy) - a_glint.z;
        float gb = a_glint.w * exp(-gd * gd * 28.0);
        c = c + vec4(gb, gb, gb, 0.0) * c.a + vec4(gb, gb, gb, gb) * (0.4 * (1.0 - c.a));
        """
        let body: String
        switch kind {
        case .backdropCell:
            body = "vec4 c = texture2D(u_texture, v_tex_coord);"
        case .backdropShard:
            body = """
            vec4 c = texture2D(u_texture, v_tex_coord);
            vec2 ouv = (v_tex_coord - u_orect.xy) / u_orect.zw;
            vec4 e = texture2D(u_erase, ouv);
            c = c * (1.0 - e.a) + e;
            vec4 k = texture2D(u_cracks, ouv) * u_crack_alpha;
            c = c * (1.0 - k.a) + k;
            \(glint)
            """
        case .glassCell:
            body = "float g = a_tint * (0.7 + 0.6 * local.y); vec4 c = vec4(g, g, g, g);"
        case .glassShard:
            body = """
            float g = a_tint * (0.7 + 0.6 * local.y);
            vec4 c = vec4(0.9 * g, 0.97 * g, g, g);
            vec4 k = texture2D(u_texture, v_tex_coord) * u_crack_alpha;
            c = c * (1.0 - k.a) + k;
            \(glint)
            """
        }
        let tail = """
        c.rgb = c.rgb * a_shade.x + a_shade.z * c.a;
        float edge = m.r * a_shade.w;
        c = c * (1.0 - edge) + vec4(edge);
        gl_FragColor = c * (m.g * a_shade.y);
        """
        let shader = SKShader(source: "void main() {\n\(head)\n\(body)\n\(tail)\n}")
        shader.uniforms = uniforms.list
        var attributes = [SKAttribute(name: "a_uvrect", type: .vectorFloat4), SKAttribute(name: "a_maskrect", type: .vectorFloat4),
                          SKAttribute(name: "a_shade", type: .vectorFloat4), SKAttribute(name: "a_tint", type: .float)]
        if kind == .backdropShard || kind == .glassShard { attributes.append(SKAttribute(name: "a_glint", type: .vectorFloat4)) }
        shader.attributes = attributes
        return shader
    }

    /// A sprite showing `textureRect` (unit rect of `texture`) over `box`, pivoting around `pivot` (scene points).
    static func sprite(texture: SKTexture, textureRect: CGRect, box: CGRect, pivot: FXVec, maskCell: CGRect,
                       shader: SKShader, tint: Double = 0) -> SKSpriteNode {
        let node = SKSpriteNode(texture: SKTexture(rect: textureRect, in: texture), size: box.size)
        node.anchorPoint = CGPoint(x: (pivot.x - box.minX) / box.width, y: (pivot.y - box.minY) / box.height)
        node.position = pivot.cgPoint
        node.shader = shader
        node.setValue(SKAttributeValue(vectorFloat4: vector_float4(Float(textureRect.minX), Float(textureRect.minY),
                                                                   Float(textureRect.width), Float(textureRect.height))),
                      forAttribute: "a_uvrect")
        node.setValue(SKAttributeValue(vectorFloat4: vector_float4(Float(maskCell.minX), Float(maskCell.minY),
                                                                   Float(maskCell.width), Float(maskCell.height))),
                      forAttribute: "a_maskrect")
        node.setValue(SKAttributeValue(float: Float(tint)), forAttribute: "a_tint")
        setShade(brightness: 1, opacity: 1, on: node)
        return node
    }

    static func setShade(brightness: Double, opacity: Double, sheen: Double = 0, edge: Double = 0, on node: SKSpriteNode) {
        node.setValue(SKAttributeValue(vectorFloat4: vector_float4(Float(brightness), Float(opacity), Float(sheen), Float(edge))),
                      forAttribute: "a_shade")
    }

    /// Shards only: a bright band across the piece along `angle`, `offset` from its centre (-0.7...0.7 spans it).
    static func setGlint(angle: Double, offset: Double, strength: Double, on node: SKSpriteNode) {
        node.setValue(SKAttributeValue(vectorFloat4: vector_float4(Float(cos(angle)), Float(sin(angle)), Float(offset), Float(strength))),
                      forAttribute: "a_glint")
    }

    static func setTint(_ tint: Double, on node: SKSpriteNode) {
        node.setValue(SKAttributeValue(float: Float(tint)), forAttribute: "a_tint")
    }
}
