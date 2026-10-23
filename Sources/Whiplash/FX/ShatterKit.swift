import AppKit
import SpriteKit

/// Everything about a shatter that can be worked out off the main thread: how the glass breaks (the plan), the
/// shards' mask atlas, the dead panel behind the glass, and the two overlays the shards carry — the crack lines baked
/// in, and (screenshot mode) the letters' spots painted over. `DestructionLayer` prepares one in the background as soon as
/// the cracks settle, so `shatter()` itself only has to build nodes. Pure value work: safe to run on any queue.
struct ShatterKit {
    /// What the kit is made from, captured on the main thread.
    struct Input {
        /// Each crack with how far it has grown (pattern time).
        var cracks: [(pattern: CrackPattern, time: Double)]
        /// Where letters will peel off, with the colour to paint there (screenshot mode only).
        var erasedSpots: [(rect: CGRect, color: CGColor)]
        var sceneSize: CGSize
        /// Pixels per point of the crack overlay (the screenshot's scale).
        var scale: CGFloat
        var screenshotMode: Bool
        var seed: UInt64
    }

    let plan: ShatterPlan
    /// Scene rect the overlays and the dead panel's interior cover.
    let overlayRect: CGRect
    let cracks: FXBitmap
    /// Nil in glass mode.
    let erase: FXBitmap?
    /// One cell per shard (same order as `plan.shards`).
    let masks: GlassPieces.MaskAtlas
    /// What shows where the glass broke out, and around it.
    let panel: DeadPanel.Art

    /// Nil when nothing breaks out (degenerate damage).
    static func make(_ input: Input) -> ShatterKit? {
        let discs = input.cracks.map { damageDisc(for: $0.pattern) }
        let plan = ShatterPlan.make(discs: discs, bounds: CGRect(origin: .zero, size: input.sceneSize), seed: input.seed)
        guard !plan.shards.isEmpty else { return nil }
        let overlayRect = pixelAligned(plan.bounds.insetBy(dx: -3, dy: -3), scale: input.scale)
        // Only what lies on the breaking glass (plus the grid's few points of margin, so strokes reach the edges);
        // the faint glow is left out — invisible on falling shards and by far the most expensive stroke.
        let inside = { (p: FXVec) in plan.grid.shard(at: p) != nil || plan.shard(containing: p) != nil }
        let cracks = FXBitmap(covering: overlayRect, scale: input.scale) { ctx in
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for (pattern, time) in input.cracks {
                let paths = CrackPaths(pattern: pattern, time: time, hidden: { !inside($0) })
                ctx.saveGState()
                ctx.translateBy(x: CrackStyle.shadowOffset.x, y: CrackStyle.shadowOffset.y)
                ctx.addPath(paths.all)
                ctx.setStrokeColor(CrackStyle.shadowColor.cgColor)
                ctx.setLineWidth(CrackStyle.shadowWidth)
                ctx.strokePath()
                ctx.restoreGState()
                for (i, path) in paths.strokes.enumerated() {
                    ctx.addPath(path)
                    ctx.setStrokeColor(CGColor(gray: 1, alpha: CrackStyle.strokes[i].alpha))
                    ctx.setLineWidth(CrackStyle.strokes[i].width)
                    ctx.strokePath()
                }
                guard time > 0 else { continue }
                let zone = FXPolygon.path(pattern.impactZone)
                ctx.addPath(zone)
                ctx.setFillColor(CrackStyle.zoneFill.cgColor)
                ctx.fillPath()
                ctx.addPath(zone)
                ctx.setStrokeColor(CrackStyle.zoneStroke.cgColor)
                ctx.setLineWidth(0.6)
                ctx.strokePath()
            }
        }
        // Flat background colour next to background colour: 1x is plenty.
        let erase = input.screenshotMode ? FXBitmap(covering: overlayRect, scale: 1) { ctx in
            for spot in input.erasedSpots where spot.rect.intersects(overlayRect) {
                ctx.setFillColor(spot.color)
                ctx.fill(spot.rect)
            }
        } : nil
        let panel = DeadPanel.makeArt(plan: plan, cracks: input.cracks.map(\.pattern), sceneSize: input.sceneSize,
                                      interiorRect: overlayRect, seed: input.seed &+ 1)
        return ShatterKit(plan: plan, overlayRect: overlayRect, cracks: cracks, erase: erase,
                          masks: GlassPieces.MaskAtlas(polygons: plan.shards.map(\.polygon), edgeWidth: 0.9), panel: panel)
    }

    /// Glass around an impact that breaks out: ~0.7 × the typical reach of its radial cracks, but at least
    /// `minimumDiscShare` of the crack's full extent. (A crack landing next to earlier ones has most radials stopped
    /// short by them — crack arrest — which would otherwise shrink its disc to almost nothing, so hits clustered
    /// together wouldn't grow the hole.)
    static func damageDisc(for pattern: CrackPattern) -> DamageDisc {
        let radials = pattern.radials.map { pattern.lines[$0].points }
        let reaches = radials.compactMap { $0.last?.distance(to: pattern.center) }.sorted()
        let typical = reaches.isEmpty ? pattern.extent : reaches[reaches.count / 2]
        return DamageDisc(center: pattern.center, radius: max(0.7 * typical, minimumDiscShare * pattern.extent),
                          radials: radials)
    }

    static let minimumDiscShare = 0.4

    private static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = floor(rect.minX * scale) / scale, minY = floor(rect.minY * scale) / scale
        let maxX = ceil(rect.maxX * scale) / scale, maxY = ceil(rect.maxY * scale) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// A kit's bitmaps as textures (main thread). Made — and primed — ahead of the shatter when possible.
final class ShatterTextures {
    let masks: SKTexture
    let cracks: SKTexture
    let erase: SKTexture?
    let panelInterior: SKTexture
    let panelBleed: SKTexture

    init(kit: ShatterKit) {
        masks = kit.masks.bitmap.texture()
        cracks = kit.cracks.texture()
        erase = kit.erase?.texture()
        panelInterior = kit.panel.interior.texture()
        panelBleed = kit.panel.bleed.texture()
    }

    var all: [SKTexture] { [masks, cracks, panelInterior, panelBleed] + (erase.map { [$0] } ?? []) }
}
