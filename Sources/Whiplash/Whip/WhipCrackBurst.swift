import AppKit
import SpriteKit

/// Small deterministic random source (SplitMix64), so demos and tests are repeatable.
struct WhipRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The "you just broke the sound barrier" moment at the tip: a white flash, comic impact lines rushing
/// outward, a shockwave ring, spark streaks and a comic word that pops in tilted and fades. Driven by `advance(dt:)`; remove it when that
/// returns false.
final class WhipCrackBurst: SKNode {
    static let words = ["CRACK!", "SNAP!", "THWACK!", "WHAPOW!"]
    static let lifetime = 0.85

    /// One radial impact line: a sliver pointing at the crack, thick at its outer end.
    private struct ImpactLine {
        var angle: CGFloat
        var length: CGFloat
        var width: CGFloat
    }

    private struct Spark {
        var direction: CGVector
        var speed: CGFloat
        var length: CGFloat
        var life: Double
        var gold: Bool
    }

    private let intensity: CGFloat
    private let glow = SKSpriteNode(texture: WhipCrackBurst.glowTexture)
    private let flash = SKShapeNode()
    private let starSpikes: [CGFloat]
    private let ring = SKShapeNode()
    private let impact = SKShapeNode()
    private let impactLines: [ImpactLine]
    private let whiteSparks = SKShapeNode()
    private let goldSparks = SKShapeNode()
    private let word: SKSpriteNode
    private let wordOffset: CGPoint
    private let wordTilt: CGFloat
    private var sparks: [Spark] = []
    private var age = 0.0

    /// `point` is where the tip cracked; the word is drawn at `point + wordOffset`.
    init(at point: CGPoint, intensity: CGFloat, word text: String, wordOffset: CGPoint, random: inout WhipRandom) {
        self.intensity = max(0, min(1, intensity))
        self.wordOffset = wordOffset
        wordTilt = CGFloat.random(in: -0.26...0.26, using: &random)
        let lettering = Self.lettering(for: text)
        word = SKSpriteNode(texture: lettering.texture, size: lettering.size)
        starSpikes = (0..<14).map { _ in CGFloat.random(in: 0.7...1.15, using: &random) }
        let strength = max(0, min(1, intensity))
        let lineCount = 16 + Int(8 * strength)
        impactLines = (0..<lineCount).map { k in
            ImpactLine(angle: (CGFloat(k) + CGFloat.random(in: 0...0.7, using: &random)) / CGFloat(lineCount) * 2 * .pi,
                       length: CGFloat.random(in: 50...130, using: &random) * (0.7 + 0.5 * strength),
                       width: CGFloat.random(in: 3...7, using: &random))
        }
        super.init()
        position = point

        glow.color = NSColor(srgbRed: 1, green: 0.9, blue: 0.62, alpha: 1)
        glow.colorBlendFactor = 1
        // Additive, so the flash lights up whatever is behind it instead of greying it.
        glow.blendMode = .add
        impact.fillColor = .white
        // A faint dark edge keeps the lines readable over light windows too.
        impact.strokeColor = NSColor(white: 0, alpha: 0.28)
        impact.lineWidth = 1
        flash.fillColor = .white
        flash.strokeColor = NSColor(srgbRed: 1, green: 0.84, blue: 0.3, alpha: 1)
        flash.lineWidth = 3
        flash.lineJoin = .miter
        ring.fillColor = .clear
        ring.strokeColor = NSColor(white: 1, alpha: 0.95)
        whiteSparks.strokeColor = .white
        goldSparks.strokeColor = NSColor(srgbRed: 1, green: 0.8, blue: 0.3, alpha: 1)
        for s in [whiteSparks, goldSparks] {
            s.lineWidth = 2.6
            s.lineCap = .round
            s.fillColor = .clear
        }

        let count = 10 + Int((6 * self.intensity).rounded())
        for k in 0..<count {
            let angle = (Double(k) + Double.random(in: 0...0.8, using: &random)) / Double(count) * 2 * .pi
            sparks.append(Spark(direction: CGVector(dx: cos(angle), dy: sin(angle)),
                                speed: CGFloat.random(in: 700...1500, using: &random) * (0.6 + 0.4 * self.intensity),
                                length: CGFloat.random(in: 18...40, using: &random),
                                life: Double.random(in: 0.22...0.4, using: &random),
                                gold: k % 3 == 0))
        }
        word.position = wordOffset
        word.zRotation = wordTilt
        word.setScale(0.01)
        for (z, node) in [glow, impact, ring, whiteSparks, goldSparks, flash, word].enumerated() {
            node.zPosition = CGFloat(z)
            addChild(node)
        }
        _ = advance(dt: 0)
    }

    required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Animates by `dt`; returns false once the burst has fully faded.
    func advance(dt: Double) -> Bool {
        age += max(0, dt)
        let t = age
        let power = 0.7 + 0.3 * intensity

        // A jagged comic starburst that punches out at full brightness, yellows, and is gone in a blink
        // (a half-faded white flash would just read as grey haze).
        // It collapses back into the crack rather than fading: a half-transparent yellow over a dark terminal
        // reads as mud.
        let flashT = t / 0.13
        flash.isHidden = flashT >= 1
        if !flash.isHidden {
            let grow = 0.45 + 0.75 * WhipMath.easeOutBack(flashT / 0.45, overshoot: 1.2)
            let collapse = 1 - WhipMath.smoothstep((flashT - 0.5) / 0.5)
            let radius = (34 + 26 * intensity) * CGFloat(grow * collapse)
            flash.path = starburst(radius: max(radius, 0.5))
            flash.fillColor = Self.flashWhite.blended(withFraction: CGFloat(min(1, flashT * 1.4)), of: Self.flashYellow) ?? Self.flashWhite
            flash.alpha = CGFloat(1 - WhipMath.smoothstep((flashT - 0.8) / 0.2))
        }
        let glowT = t / 0.2
        glow.isHidden = glowT >= 1
        if !glow.isHidden {
            let diameter = (130 + 110 * intensity) * CGFloat(0.6 + 0.5 * glowT)
            glow.size = CGSize(width: diameter, height: diameter)
            glow.alpha = CGFloat(0.9 * (1 - WhipMath.smoothstep(glowT)))
        }

        // Comic impact lines rush outward from the crack and are gone within a few frames.
        let impactT = t / 0.16
        impact.isHidden = impactT >= 1
        if !impact.isHidden {
            let rush = CGFloat(1 - pow(1 - impactT, 2))
            let inner = (46 + 18 * intensity) + 90 * power * rush
            let path = CGMutablePath()
            for line in impactLines {
                let c = cos(line.angle), s = sin(line.angle)
                let outer = inner + line.length * (1 - 0.35 * rush)
                let half = line.width / 2 * (1 - 0.5 * rush)
                path.move(to: CGPoint(x: c * inner, y: s * inner))
                path.addLine(to: CGPoint(x: c * outer - s * half, y: s * outer + c * half))
                path.addLine(to: CGPoint(x: c * outer + s * half, y: s * outer - c * half))
                path.closeSubpath()
            }
            impact.path = path
            impact.alpha = CGFloat(0.95 * (1 - WhipMath.smoothstep((impactT - 0.3) / 0.7)))
        }

        let ringT = t / 0.4
        ring.isHidden = ringT >= 1
        if !ring.isHidden {
            let eased = 1 - pow(1 - ringT, 3)
            let radius = 12 + (140 * power - 12) * CGFloat(eased)
            ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
            ring.lineWidth = CGFloat(6 - 5 * ringT) * power
            ring.alpha = CGFloat(0.95 * (1 - ringT))
        }

        let white = CGMutablePath(), gold = CGMutablePath()
        for spark in sparks where t < spark.life {
            let u = t / spark.life
            // Decelerating streaks that shrink as they fly out.
            let distance = spark.speed * CGFloat(t * (1 - 0.5 * u)) + 10
            let length = spark.length * CGFloat(1 - u)
            let head = CGPoint(x: spark.direction.dx * distance, y: spark.direction.dy * distance)
            let tail = CGPoint(x: head.x - spark.direction.dx * length, y: head.y - spark.direction.dy * length)
            let path = spark.gold ? gold : white
            path.move(to: tail)
            path.addLine(to: head)
        }
        whiteSparks.path = white
        goldSparks.path = gold

        // The word pops in with an overshoot, jiggles, then drifts up and fades.
        let pop = t < 0.18 ? CGFloat(WhipMath.easeOutBack(t / 0.18, overshoot: 2.4)) : 1
        let jiggle = 1 + 0.04 * CGFloat(sin(t * 38) * exp(-t * 6))
        word.setScale(max(0.01, (0.8 + 0.3 * intensity) * pop * jiggle))
        word.zRotation = wordTilt * CGFloat(0.6 + 0.4 * min(1, t / 0.18))
        word.position = CGPoint(x: wordOffset.x, y: wordOffset.y + CGFloat(22 * t))
        word.alpha = CGFloat(1 - WhipMath.smoothstep((t - 0.55) / 0.3))
        return t < Self.lifetime
    }

    private static let flashWhite = NSColor.white
    private static let flashYellow = NSColor(srgbRed: 1, green: 0.9, blue: 0.35, alpha: 1)

    private func starburst(radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let count = starSpikes.count
        for k in 0..<(count * 2) {
            let angle = CGFloat(k) / CGFloat(count * 2) * 2 * .pi
            let r = k % 2 == 0 ? radius * starSpikes[k / 2] : radius * 0.48
            let p = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Textures

    /// Soft white radial falloff, tinted per use.
    private static let glowTexture: SKTexture = {
        let side = 128
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0.35), CGColor(gray: 1, alpha: 0)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.35, 1])!
        let c = CGPoint(x: side / 2, y: side / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(side) / 2, options: [])
        return SKTexture(cgImage: ctx.makeImage()!)
    }()

    private static var letteringCache: [String: (texture: SKTexture, size: CGSize)] = [:]

    /// Renders every word and the glow up front (the first render loads fonts and takes ~50 ms — not
    /// something to do in the very frame the whip cracks).
    static func prepareTextures() {
        _ = glowTexture
        for word in words { _ = lettering(for: word) }
    }

    /// Comic lettering: heavy rounded type, hot yellow-to-orange fill, thick dark outline and a hard shadow.
    /// Rendered at 2x; `size` is in points.
    static func lettering(for text: String) -> (texture: SKTexture, size: CGSize) {
        if let cached = letteringCache[text] { return cached }
        let image = renderWord(text)
        let result = (SKTexture(cgImage: image), CGSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
        letteringCache[text] = result
        return result
    }

    private static func renderWord(_ text: String) -> CGImage {
        let scale: CGFloat = 2
        let pointSize: CGFloat = 64
        var font = NSFont.systemFont(ofSize: pointSize, weight: .black)
        if let rounded = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: rounded, size: pointSize) {
            font = f
        }
        let ink = NSColor(srgbRed: 0.16, green: 0.06, blue: 0.02, alpha: 1)
        let base: [NSAttributedString.Key: Any] = [.font: font, .kern: 1.5]
        let size = (text as NSString).size(withAttributes: base)
        let pad: CGFloat = 16
        let width = Int(((size.width + pad * 2) * scale).rounded(.up))
        let height = Int(((size.height + pad * 2) * scale).rounded(.up))
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let origin = CGPoint(x: pad, y: pad)

        func draw(_ extra: [NSAttributedString.Key: Any], at point: CGPoint) {
            (text as NSString).draw(at: point, withAttributes: base.merging(extra) { $1 })
        }
        // Hard drop shadow, then a fat outline, then the fill.
        draw([.strokeColor: ink, .strokeWidth: 24, .foregroundColor: ink], at: CGPoint(x: origin.x + 3.5, y: origin.y - 4.5))
        draw([.foregroundColor: ink], at: CGPoint(x: origin.x + 3.5, y: origin.y - 4.5))
        draw([.strokeColor: ink, .strokeWidth: 24], at: origin)
        draw([.foregroundColor: NSColor(patternImage: gradientSwatch(height: size.height + pad * 2))], at: origin)
        // A little white shine along the top of the letters.
        draw([.strokeColor: NSColor.white.withAlphaComponent(0.55), .strokeWidth: 3], at: CGPoint(x: origin.x - 0.8, y: origin.y + 1.2))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// Vertical fill gradient used as a pattern colour for the lettering.
    private static func gradientSwatch(height: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 4, height: height), flipped: false) { rect in
            NSGradient(colors: [
                NSColor(srgbRed: 1.0, green: 0.42, blue: 0.10, alpha: 1),
                NSColor(srgbRed: 1.0, green: 0.78, blue: 0.16, alpha: 1),
                NSColor(srgbRed: 1.0, green: 0.97, blue: 0.62, alpha: 1),
            ])?.draw(in: rect, angle: 90)
            return true
        }
    }
}
