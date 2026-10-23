import AppKit
import SpriteKit

/// Small procedural textures shared by every DestructionLayer (no asset files in this app).
enum FXTextures {
    /// Soft round blob, white → transparent. Dust, glows, the crushed impact haze.
    static let softDot: SKTexture = make(size: 64) { ctx, s in
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.35, 1])!
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
    }

    /// Four-pointed specular star: light catching a crack edge.
    static let sparkle: SKTexture = make(size: 96) { ctx, s in
        let c = CGPoint(x: s / 2, y: s / 2)
        let colors = [CGColor(gray: 1, alpha: 0.9), CGColor(gray: 1, alpha: 0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.22, options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for angle in [0.0, .pi / 2] {
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: angle)
            let ray = CGMutablePath()
            ray.move(to: CGPoint(x: -s / 2, y: 0))
            ray.addQuadCurve(to: CGPoint(x: 0, y: s * 0.035), control: CGPoint(x: -s * 0.05, y: s * 0.012))
            ray.addQuadCurve(to: CGPoint(x: s / 2, y: 0), control: CGPoint(x: s * 0.05, y: s * 0.012))
            ray.addQuadCurve(to: CGPoint(x: 0, y: -s * 0.035), control: CGPoint(x: s * 0.05, y: -s * 0.012))
            ray.addQuadCurve(to: CGPoint(x: -s / 2, y: 0), control: CGPoint(x: -s * 0.05, y: -s * 0.012))
            ctx.addPath(ray)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// A sharp little glass sliver: bright edges, a translucent body.
    static let chip: SKTexture = make(size: 32) { ctx, s in
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: s * 0.04, y: s * 0.46), CGPoint(x: s * 0.62, y: s * 0.7),
                                CGPoint(x: s * 0.97, y: s * 0.52), CGPoint(x: s * 0.5, y: s * 0.3)])
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.6))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(s * 0.06)
        ctx.strokePath()
    }

    static func make(size: CGFloat, _ draw: (CGContext, CGFloat) -> Void) -> SKTexture {
        let px = Int(size)
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, size)
        let texture = SKTexture(cgImage: ctx.makeImage()!)
        texture.filteringMode = .linear
        return texture
    }
}

/// Draws textures once, invisibly — each on a sprite far smaller than a pixel, which covers no pixel centre — so
/// SpriteKit uploads them to the GPU on a quiet frame instead of the busy frame that first shows them (about 2.5 ms
/// per 11 MB at the shatter). Add it to the scene and call `step()` once per frame.
final class FXPrimer: SKNode {
    private var drawn = false

    func prime(_ textures: [SKTexture]) {
        for texture in textures {
            let sprite = SKSpriteNode(texture: texture, size: CGSize(width: 0.01, height: 0.01))
            // 0.9 pt: clear of every pixel centre at 1x, 2x and 3x.
            sprite.position = CGPoint(x: 0.9, y: 0.9)
            addChild(sprite)
        }
        drawn = false
    }

    /// Drops the sprites once they have been drawn (they were added before the last render).
    func step() {
        guard !children.isEmpty else { return }
        if drawn { removeAllChildren() } else { drawn = true }
    }
}
