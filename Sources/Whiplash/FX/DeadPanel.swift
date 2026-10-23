import AppKit
import SpriteKit

/// What the broken glass leaves behind: the display under it is dead, the way a real smashed laptop screen is — not a
/// hole into somewhere. Where the glass broke out, the bare panel: near-black, its torn films faintly showing, the
/// glass edge's thickness along the rim. Around it the liquid crystal bleeds out under the unbroken glass as dark
/// ink, seeping furthest along the cracks, with an oily sheen at its edge and a few patches of raw backlight; dead
/// pixel columns and rows run off across the screen. The ink keeps creeping while you look at it, and it all fades
/// on the rewind. The bitmaps are baked with the shatter kit, off the main thread (`makeArt`).
final class DeadPanel {
    /// Everything that can be worked out off the main thread (part of `ShatterKit`).
    struct Art {
        /// The bare panel where the glass broke out (transparent elsewhere), covering `interiorRect`.
        let interior: FXBitmap
        let interiorRect: CGRect
        /// The ink bleeding out around the hole, covering `bleedRect` at `bleedScale` (it is soft anyway).
        let bleed: FXBitmap
        let bleedRect: CGRect
        /// Where the ink spreads from: the biggest hole's centre.
        let origin: FXVec
        let lines: [Line]
    }

    /// A dead pixel column (or row): a thin line — now and then a wider band — of one colour, across the screen.
    struct Line {
        let vertical: Bool
        /// x of a column, y of a row, scene coordinates.
        let position: Double
        let width: Double
        /// Where along the screen it runs: y for a column, x for a row.
        let span: ClosedRange<Double>
        let color: NSColor
        let alpha: Double
        /// When it comes on, seconds after the shatter.
        let onset: Double
    }

    /// Above everything else on the glass except the rim: the lines, the ink, the bare panel.
    let node = SKNode()
    /// The bright glass edge (above the letters' erasers and the panel).
    let rim = SKNode()

    /// How long it all takes to fade on the rewind, in step with the pieces gliding home.
    static let closeDuration = 0.9
    static let bleedScale: CGFloat = 0.5

    private let start: Double
    private let bleed: SKSpriteNode
    private let sceneSize: CGSize
    private var lines: [(node: SKSpriteNode, line: Line, seed: Double)] = []
    /// More ink where you smashed the glass during the break, with when it started to spread (seconds after the shatter).
    private var blots: [(node: SKSpriteNode, born: Double, size: CGFloat)] = []
    private var rng: FXRandom
    /// Built once and faded in: rebuilding big strokes costs SpriteKit a re-tessellation per frame.
    private let rimLine: SKShapeNode
    /// When the rim appears: as the shards along it start to let go.
    private let rimReveal: Double
    private var closingAt: Double?

    /// `release(i)`: when shard i starts to move, seconds after the shatter.
    init(kit: ShatterKit, textures: ShatterTextures, sceneSize: CGSize, time: Double, release: (Int) -> Double) {
        start = time
        self.sceneSize = sceneSize
        let art = kit.panel
        let interior = SKSpriteNode(texture: textures.panelInterior, size: art.interiorRect.size)
        interior.anchorPoint = .zero
        interior.position = art.interiorRect.origin
        interior.zPosition = 2

        // Scaled about where it spreads from.
        bleed = SKSpriteNode(texture: textures.panelBleed, size: art.bleedRect.size)
        bleed.anchorPoint = CGPoint(x: (art.origin.x - art.bleedRect.minX) / max(art.bleedRect.width, 1),
                                    y: (art.origin.y - art.bleedRect.minY) / max(art.bleedRect.height, 1))
        bleed.position = art.origin.cgPoint
        bleed.zPosition = 1
        bleed.alpha = 0

        rng = FXRandom(seed: UInt64(art.lines.count) &* 0x9E37_79B9)
        node.addChild(bleed)
        node.addChild(interior)

        let releases = kit.plan.rim.map { release($0.shard) }.sorted()
        rimReveal = releases.isEmpty ? 0 : releases[releases.count / 4]
        let rimPath = CGMutablePath()
        for edge in kit.plan.rim {
            rimPath.move(to: edge.a.cgPoint)
            rimPath.addLine(to: edge.b.cgPoint)
        }
        rimLine = SKShapeNode(path: rimPath)
        rimLine.strokeColor = NSColor(white: 1, alpha: 0.4)
        rimLine.lineWidth = 1
        rimLine.lineJoin = .bevel
        rimLine.alpha = 0
        rim.addChild(rimLine)
        // Under the ink and the bare panel (their z is higher).
        for line in art.lines { addLine(line) }
    }

    /// The rewind started.
    func beginClosing(at time: Double) { closingAt = time }

    /// Another blow during the break: `onGlass`, the display dies a little more under the new crack (a spot of ink
    /// spreading from it); on the bare panel, another column of pixels gives out.
    func addDamage(at point: FXVec, onGlass: Bool, time: Double) {
        guard closingAt == nil else { return }
        let t = time - start
        if onGlass {
            let size = CGFloat(rng.range(48...96))
            let blot = SKSpriteNode(texture: Self.blotTexture, size: CGSize(width: size, height: size))
            blot.position = point.cgPoint
            blot.zRotation = CGFloat(rng.unit() * 2 * .pi)
            blot.zPosition = 1.5
            blot.alpha = 0
            node.addChild(blot)
            blots.append((blot, t, size))
        }
        if !onGlass || rng.chance(0.35) {
            let height = Double(sceneSize.height)
            let span: ClosedRange<Double> = rng.chance(0.5) ? 0...height : (rng.chance(0.5) ? 0...point.y : point.y...height)
            addLine(Line(vertical: true, position: point.x + rng.range(-6...6), width: rng.chance(0.75) ? 1 : 2, span: span,
                         color: Self.palette[rng.int(0...(Self.palette.count - 1))], alpha: rng.range(0.55...0.9), onset: t))
        }
    }

    private func addLine(_ line: Line) {
        let length = line.span.upperBound - line.span.lowerBound
        let size = line.vertical ? CGSize(width: line.width, height: length) : CGSize(width: length, height: line.width)
        let sprite = SKSpriteNode(color: line.color, size: size)
        let middle = (line.span.lowerBound + line.span.upperBound) / 2
        sprite.position = line.vertical ? CGPoint(x: line.position, y: middle) : CGPoint(x: middle, y: line.position)
        sprite.alpha = 0
        node.addChild(sprite)
        lines.append((sprite, line, rng.unit() * 100))
    }

    /// A ragged spot of dead liquid crystal, soft at the edge.
    private static let blotTexture: SKTexture = FXTextures.make(size: 96) { ctx, s in
        var rng = FXRandom(seed: 0xB107)
        let c = FXVec(Double(s) / 2, Double(s) / 2)
        let phases = (0..<3).map { _ in rng.unit() * 2 * .pi }
        let points = (0..<48).map { k -> FXVec in
            let a = 2 * .pi * Double(k) / 48
            var wobble = 1.0
            for (i, phase) in phases.enumerated() {
                wobble += 0.14 / Double(i + 1) * sin(Double(3 + 2 * i) * a + phase)
            }
            return c + FXVec.polar(a, Double(s) * 0.36 * wobble)
        }
        let ink = CGColor(srgbRed: 0.012, green: 0.012, blue: 0.018, alpha: 0.95)
        ctx.setShadow(offset: .zero, blur: s * 0.05, color: ink)
        ctx.addPath(FXPolygon.path(points))
        ctx.setFillColor(ink)
        ctx.fillPath()
    }

    /// The pieces are back in place: nothing of it may peek through the hairline gaps between them.
    func hide() {
        node.isHidden = true
        rim.isHidden = true
    }

    func step(time: Double) {
        let t = time - start
        let closing = closingAt.map { FXEase.inOutCubic(FXEase.clamp01((time - $0) / Self.closeDuration)) } ?? 0
        // The glass edge shows as the pieces along it let go, and fades as they land back in it.
        rimLine.alpha = CGFloat(FXEase.outCubic((t - rimReveal) / 0.15)
                                * (1 - (closingAt.map { FXEase.smoothstep(0.3, 1.1, time - $0) } ?? 0)))
        // The ink runs out from under the edge in a second, then keeps creeping.
        let spread = 0.78 + 0.22 * FXEase.outCubic(t / 1.1) + 0.04 * FXEase.clamp01((t - 1.1) / 12)
        bleed.setScale(CGFloat(spread * (1 - 0.12 * closing)))
        bleed.alpha = CGFloat(FXEase.smoothstep(0, 0.25, t) * (1 - closing))
        // Fresh ink under a smash spreads out in a moment.
        for blot in blots {
            let u = FXEase.clamp01((t - blot.born) / 0.35)
            blot.node.setScale(CGFloat(0.55 + 0.45 * FXEase.outCubic(u)) * (1 - 0.2 * CGFloat(closing)))
            blot.node.alpha = CGFloat(FXEase.outCubic(u) * (1 - closing))
        }
        // The dead lines go first on the rewind.
        let linesOff = closingAt.map { FXEase.smoothstep(0, 0.35, time - $0) } ?? 0
        for entry in lines {
            entry.node.alpha = CGFloat(entry.line.alpha * Self.lineLevel(t - entry.line.onset, seed: entry.seed) * (1 - linesOff))
        }
    }

    /// Brightness (0...1) of a dead line `u` seconds after it comes on: it stutters on, then holds, with the odd
    /// brief dip.
    static func lineLevel(_ u: Double, seed: Double) -> Double {
        guard u >= 0 else { return 0 }
        if u < 0.2 { return sin(u * 140 + seed * 37) > 0 ? 1 : 0.15 }
        let wobble = sin(u * 3.1 + seed * 11) * sin(u * 7.3 + seed * 5)
        return wobble > 0.93 ? 0.4 : 1
    }

    /// The colours dead pixel lines come in.
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.12, blue: 0.85, alpha: 1), NSColor(srgbRed: 0.2, green: 1, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.9, blue: 1, alpha: 1), NSColor(white: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 0.93, blue: 0.3, alpha: 1), NSColor(srgbRed: 1, green: 0.18, blue: 0.12, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.35, blue: 1, alpha: 1),
    ]

    // MARK: - Baking (any queue)

    /// Works out the dead panel for `plan` (the broken glass) and `cracks` (the ink seeps along them).
    static func makeArt(plan: ShatterPlan, cracks: [CrackPattern], sceneSize: CGSize, interiorRect: CGRect,
                        seed: UInt64) -> Art {
        var rng = FXRandom(seed: seed)
        let screen = CGRect(origin: .zero, size: sceneSize)
        let holeArea = plan.components.reduce(0) { $0 + $1.area }
        // How far the ink bleeds past the broken edge.
        let reach = min(max(holeArea.squareRoot() * 0.1, 14), 55)
        let bleedRect = plan.bounds.insetBy(dx: -reach * 3, dy: -reach * 3).intersection(screen)
        let origin = plan.components.max { $0.area < $1.area }?.centre ?? FXVec(screen.midX, screen.midY)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let clear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)

        let hole = CGMutablePath()
        for shard in plan.shards { hole.addPath(FXPolygon.path(shard.polygon)) }
        let rimPath = CGMutablePath()
        var rimPoints: [FXVec] = []
        for edge in plan.rim {
            rimPath.move(to: edge.a.cgPoint)
            rimPath.addLine(to: edge.b.cgPoint)
            let steps = max(1, Int(edge.a.distance(to: edge.b) / 12))
            for k in 0..<steps { rimPoints.append(edge.a + (edge.b - edge.a) * ((Double(k) + 0.5) / Double(steps))) }
        }

        func blob(_ ctx: CGContext, at c: FXVec, radius r: Double, colors: [CGColor], locations: [CGFloat]) {
            guard r > 0.5, let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
            ctx.drawRadialGradient(gradient, startCenter: c.cgPoint, startRadius: 0, endCenter: c.cgPoint, endRadius: r, options: [])
        }

        // Ragged blots of ink straddling the rim, of all sizes (a few much bigger), and a scatter of small ones nearby.
        // A blob with a wavy, organic outline (a few superposed ripples round the circle).
        func ragged(_ c: FXVec, _ r: Double) -> CGPath {
            let ripples = (0..<3).map { k in (order: Double([2, 3, 5, 7, 9][rng.int(0...4)] + k), phase: rng.unit() * 2 * .pi,
                                              depth: rng.range(0.06...0.2) / Double(k + 1)) }
            let points = (0..<40).map { k -> FXVec in
                let a = 2 * .pi * Double(k) / 40
                let wobble = ripples.reduce(1) { $0 + $1.depth * sin($1.order * a + $1.phase) }
                return c + FXVec.polar(a, r * wobble)
            }
            return FXPolygon.path(points)
        }
        var blots: [CGPath] = []
        var sheens: [(path: CGPath, color: CGColor)] = []
        for p in rimPoints where rng.chance(0.35) {
            let out = (p - origin).normalized
            let r = reach * rng.range(0.3...1) * (rng.chance(0.08) ? 2 : 1)
            let c = p + out * (r * rng.range(-0.2...0.6))
            let blot = ragged(c, r)
            blots.append(blot)
            if rng.chance(0.25) {
                let hue = [0.5, 0.58, 0.75, 0.88, 0.12][rng.int(0...4)]
                sheens.append((blot, NSColor(hue: hue, saturation: 0.55, brightness: 0.9, alpha: rng.range(0.1...0.18)).cgColor))
            }
            if rng.chance(0.2) { blots.append(ragged(c + out * (r * rng.range(1.3...2.4)), r * rng.range(0.12...0.3))) }
        }
        let ink = CGColor(srgbRed: 0.012, green: 0.012, blue: 0.018, alpha: 0.95)
        let bleed = FXBitmap(covering: bleedRect, scale: bleedScale) { ctx in
            // An oily sheen at the ink's edge: a thin, faint coloured rim round some blots, mostly hidden under the ink.
            ctx.setShadow(offset: .zero, blur: 1.5, color: nil)
            ctx.setLineWidth(3)
            for sheen in sheens {
                ctx.addPath(sheen.path)
                ctx.setStrokeColor(sheen.color)
                ctx.strokePath()
            }
            // The ink: solid, its edge just a little soft.
            ctx.setShadow(offset: .zero, blur: 2, color: ink)
            ctx.setFillColor(ink)
            for path in blots { ctx.addPath(path) }
            ctx.fillPath()
            // Seeping along the cracks, out from under the broken edge.
            ctx.setLineCap(.round)
            ctx.setShadow(offset: .zero, blur: 1.5, color: ink)
            ctx.setStrokeColor(ink.copy(alpha: 0.9) ?? ink)
            for pattern in cracks {
                for index in pattern.radials where rng.chance(0.7) {
                    let points = pattern.lines[index].points
                    guard let exit = points.firstIndex(where: { plan.shard(containing: $0) == nil }), exit > 0 else { continue }
                    let length = reach * rng.range(1...3)
                    var travelled = 0.0
                    var previous = points[exit - 1]
                    for p in points[exit...] {
                        let step = previous.distance(to: p)
                        travelled += step
                        let left = 1 - min(1, travelled / length)
                        guard left > 0 else { break }
                        ctx.setLineWidth(1 + 5 * left * left)
                        ctx.move(to: previous.cgPoint)
                        ctx.addLine(to: p.cgPoint)
                        ctx.strokePath()
                        previous = p
                    }
                }
            }
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            // Raw backlight where the layers came apart: a few cold-white patches just off the rim, stretched along it.
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            for _ in 0..<rng.int(2...4) {
                guard let p = rimPoints.isEmpty ? nil : rimPoints[rng.int(0...(rimPoints.count - 1))] else { break }
                let out = (p - origin).normalized
                let c = p + out * (reach * rng.range(0.2...0.6))
                let light = CGColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: rng.range(0.5...0.8))
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: atan2(out.y, out.x) + .pi / 2)
                ctx.scaleBy(x: rng.range(1.6...2.6), y: 1)
                blob(ctx, at: .zero, radius: rng.range(6...16), colors: [light, light.copy(alpha: 0.25) ?? light, clear],
                     locations: [0, 0.5, 1])
                ctx.restoreGState()
            }
        }

        let interior = FXBitmap(covering: interiorRect, scale: 1) { ctx in
            ctx.addPath(hole)
            ctx.clip()
            // The bare panel: as black as the ink, a touch lighter towards the middle where light still leaks through.
            ctx.setFillColor(CGColor(srgbRed: 0.01, green: 0.011, blue: 0.015, alpha: 1))
            ctx.fill(interiorRect)
            let glow = CGColor(srgbRed: 0.04, green: 0.043, blue: 0.052, alpha: 1)
            blob(ctx, at: origin, radius: holeArea.squareRoot() * 0.6, colors: [glow, glow.copy(alpha: 0) ?? clear], locations: [0, 1])
            // Its torn films: faint mottling.
            let mottles = min(220, max(30, Int(holeArea / 1400)))
            let box = plan.bounds
            for _ in 0..<mottles {
                let c = FXVec(rng.range(Double(box.minX)...Double(box.maxX)), rng.range(Double(box.minY)...Double(box.maxY)))
                let tone = CGColor(gray: rng.range(0...0.12), alpha: rng.range(0.05...0.16))
                blob(ctx, at: c, radius: rng.range(5...36), colors: [tone, tone.copy(alpha: 0) ?? clear], locations: [0, 1])
            }
            // The panel's colour filter, smeared.
            for _ in 0..<rng.int(2...4) {
                let c = FXVec(rng.range(Double(box.minX)...Double(box.maxX)), rng.range(Double(box.minY)...Double(box.maxY)))
                let tint = NSColor(hue: [0.83, 0.5, 0.1, 0.33][rng.int(0...3)], saturation: 0.8, brightness: 0.6,
                                   alpha: rng.range(0.07...0.14)).cgColor
                blob(ctx, at: c, radius: rng.range(18...70), colors: [tint, tint.copy(alpha: 0) ?? clear], locations: [0, 1])
            }
            // Subpixel columns showing through, very faintly.
            let stripes = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.035), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.035),
                           CGColor(srgbRed: 0, green: 0.3, blue: 1, alpha: 0.045)]
            var x = floor(interiorRect.minX)
            var k = 0
            while x < interiorRect.maxX {
                ctx.setFillColor(stripes[k % 3])
                ctx.fill(CGRect(x: x, y: interiorRect.minY, width: 1, height: interiorRect.height))
                x += 1
                k += 1
            }
            // The glass edge's thickness: a dark shadow, a greenish cross-section and a thin highlight along the rim
            // (only their inner halves show).
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for (color, width) in [(CGColor(gray: 0, alpha: 0.45), 16.0), (CGColor(gray: 0, alpha: 0.3), 7.0),
                                   (CGColor(srgbRed: 0.72, green: 0.95, blue: 0.9, alpha: 0.14), 4.0),
                                   (CGColor(gray: 1, alpha: 0.16), 1.2)] {
                ctx.addPath(rimPath)
                ctx.setStrokeColor(color)
                ctx.setLineWidth(width)
                ctx.strokePath()
            }
        }

        // Dead columns through the damage, sometimes a row or two.
        let palette = Self.palette
        let box = plan.bounds
        let height = Double(sceneSize.height), width = Double(sceneSize.width)
        var lines: [Line] = []
        for i in 0..<rng.int(3...7) {
            let band = i == 0 && rng.chance(0.6)
            let span: ClosedRange<Double>
            switch rng.int(0...3) {
            case 0: span = 0...Double(box.midY) // from the damage down
            case 1: span = Double(box.midY)...height // from the damage up
            default: span = 0...height
            }
            lines.append(Line(vertical: true, position: rng.range(Double(box.minX)...Double(box.maxX)),
                              width: band ? rng.range(5...14) : (rng.chance(0.7) ? 1 : 2), span: span,
                              color: palette[rng.int(0...(palette.count - 1))],
                              alpha: band ? rng.range(0.2...0.38) : rng.range(0.55...0.9), onset: rng.range(0.02...0.45)))
        }
        for _ in 0..<rng.int(0...2) {
            lines.append(Line(vertical: false, position: rng.range(Double(box.minY)...Double(box.maxY)),
                              width: rng.chance(0.75) ? 1 : 2, span: 0...width, color: palette[rng.int(0...(palette.count - 1))],
                              alpha: rng.range(0.5...0.85), onset: rng.range(0.05...0.5)))
        }
        return Art(interior: interior, interiorRect: interiorRect, bleed: bleed, bleedRect: bleedRect, origin: origin, lines: lines)
    }
}
