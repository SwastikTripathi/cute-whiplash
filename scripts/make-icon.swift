#!/usr/bin/env swift
// Draws Whiplash's app icon in code and builds Resources/AppIcon.icns with iconutil.
//
//   swift scripts/make-icon.swift                   # writes Resources/AppIcon.icns
//   swift scripts/make-icon.swift --preview x.png   # also writes a contact sheet of every size, and x.1024.png
//   swift scripts/make-icon.swift --iconset dir     # keep the .iconset PNGs in `dir`
//
// Lash (the gentleman Samoyed from Notch/LashFigure.swift, same proportions and palette) grins out of a dark glass tile
// while his leather whip curls overhead and cracks the glass. Every size is drawn from scratch rather than
// downscaled: 16 and 32 px get a simplified, bolder drawing so they still read in a Finder list.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { P(a.x + b.x, a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { P(a.x - b.x, a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { P(a.x * s, a.y * s) }
    var length: CGFloat { (x * x + y * y).squareRoot() }
    var unit: CGPoint { length > 0 ? self * (1 / length) : P(1, 0) }
    /// Rotated 90° (in a y-down space: toward the left of the direction of travel).
    var perp: CGPoint { P(y, -x) }
}

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: sRGB, colors: stops.map(\.0) as CFArray, locations: stops.map(\.1))!
}

func ellipse(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry), transform: nil)
}

/// Deterministic noise for the crack pattern (SplitMix64).
struct Seeded {
    var state: UInt64
    mutating func next() -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return CGFloat(z ^ (z >> 31)) / CGFloat(UInt64.max)
    }
    mutating func range(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * next() }
}

/// Catmull-Rom spline through `points`, resampled to `count` points evenly spaced by arc length.
func spline(_ points: [CGPoint], count: Int) -> [CGPoint] {
    var dense: [CGPoint] = []
    for i in 0..<(points.count - 1) {
        let p0 = points[max(0, i - 1)], p1 = points[i], p2 = points[i + 1], p3 = points[min(points.count - 1, i + 2)]
        for s in 0..<40 {
            let t = CGFloat(s) / 40, t2 = t * t, t3 = t2 * t
            let a = p1 * 2
            let b = (p2 - p0) * t
            let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
            let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
            dense.append((a + b + c + d) * 0.5)
        }
    }
    dense.append(points[points.count - 1])
    var lengths: [CGFloat] = [0]
    for i in 1..<dense.count { lengths.append(lengths[i - 1] + (dense[i] - dense[i - 1]).length) }
    let total = lengths[lengths.count - 1]
    var out: [CGPoint] = []
    var j = 0
    for k in 0..<count {
        let target = total * CGFloat(k) / CGFloat(count - 1)
        while j < dense.count - 2, lengths[j + 1] < target { j += 1 }
        let span = max(0.0001, lengths[j + 1] - lengths[j])
        let f = min(1, max(0, (target - lengths[j]) / span))
        out.append(dense[j] + (dense[j + 1] - dense[j]) * f)
    }
    return out
}

func tangents(_ pts: [CGPoint]) -> [CGPoint] {
    pts.indices.map { i in (pts[min(pts.count - 1, i + 1)] - pts[max(0, i - 1)]).unit }
}

/// A closed polygon hugging a centreline: width `widths[i]` at `pts[i]`, shifted sideways by `offsets[i]`.
func ribbon(_ pts: [CGPoint], widths: [CGFloat], offsets: [CGFloat]? = nil, range: Range<Int>? = nil) -> CGPath {
    let r = range ?? pts.indices
    let tan = tangents(pts)
    let path = CGMutablePath()
    var right: [CGPoint] = []
    for i in r {
        let n = tan[i].perp
        let c = pts[i] + n * (offsets?[i] ?? 0)
        let left = c + n * (widths[i] / 2)
        if i == r.lowerBound { path.move(to: left) } else { path.addLine(to: left) }
        right.append(c - n * (widths[i] / 2))
    }
    for p in right.reversed() { path.addLine(to: p) }
    path.closeSubpath()
    return path
}

/// A rounded square with continuous ("squircle") corners, like macOS's own icon shape.
func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
    // Corner offsets of the continuous-curvature rounded rect, in multiples of `radius`.
    let a: CGFloat = 1.528665, b: CGFloat = 1.088493, c: CGFloat = 0.868407
    let d: CGFloat = 0.669934, e: CGFloat = 0.065496, f: CGFloat = 0.372824, g: CGFloat = 0.169059
    let p = CGMutablePath()
    let x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY, q = radius
    p.move(to: P(x0 + a * q, y0))
    p.addLine(to: P(x1 - a * q, y0))
    p.addCurve(to: P(x1 - d * q, y0 + e * q), control1: P(x1 - b * q, y0), control2: P(x1 - c * q, y0))
    p.addCurve(to: P(x1 - e * q, y0 + d * q), control1: P(x1 - f * q, y0 + g * q), control2: P(x1 - g * q, y0 + f * q))
    p.addCurve(to: P(x1, y0 + a * q), control1: P(x1, y0 + c * q), control2: P(x1, y0 + b * q))
    p.addLine(to: P(x1, y1 - a * q))
    p.addCurve(to: P(x1 - e * q, y1 - d * q), control1: P(x1, y1 - b * q), control2: P(x1, y1 - c * q))
    p.addCurve(to: P(x1 - d * q, y1 - e * q), control1: P(x1 - g * q, y1 - f * q), control2: P(x1 - f * q, y1 - g * q))
    p.addCurve(to: P(x1 - a * q, y1), control1: P(x1 - c * q, y1), control2: P(x1 - b * q, y1))
    p.addLine(to: P(x0 + a * q, y1))
    p.addCurve(to: P(x0 + d * q, y1 - e * q), control1: P(x0 + b * q, y1), control2: P(x0 + c * q, y1))
    p.addCurve(to: P(x0 + e * q, y1 - d * q), control1: P(x0 + f * q, y1 - g * q), control2: P(x0 + g * q, y1 - f * q))
    p.addCurve(to: P(x0, y1 - a * q), control1: P(x0, y1 - c * q), control2: P(x0, y1 - b * q))
    p.addLine(to: P(x0, y0 + a * q))
    p.addCurve(to: P(x0 + e * q, y0 + d * q), control1: P(x0, y0 + b * q), control2: P(x0, y0 + c * q))
    p.addCurve(to: P(x0 + d * q, y0 + e * q), control1: P(x0 + g * q, y0 + f * q), control2: P(x0 + f * q, y0 + g * q))
    p.addCurve(to: P(x0 + a * q, y0), control1: P(x0 + c * q, y0), control2: P(x0 + b * q, y0))
    p.closeSubpath()
    return p
}

// MARK: - Palette (Lash's from LashPainter / LashFace.Skin.fur, the whip's from WhipSkin.Palette)

enum Ink {
    static let ink = rgb(0.05, 0.05, 0.07)
    static let eyeWhite = rgb(1, 1, 1)
    static let eyeShade = rgb(0.84, 0.85, 0.92)
    static let mouth = rgb(0.29, 0.04, 0.10)
    static let tongue = rgb(1.0, 0.44, 0.58)
    static let blush = rgb(1.0, 0.42, 0.62)
    // Lash's fluffy white Samoyed fur and gentleman's kit (as in LashFace.Skin.fur and LashPainter).
    static let skinTop = rgb(1.0, 0.995, 0.985)
    static let skinBottom = rgb(0.90, 0.90, 0.93)
    static let lid = rgb(0.96, 0.96, 0.97)
    static let rim = rgb(0.62, 0.62, 0.69)
    static let innerEar = rgb(0.97, 0.78, 0.81)
    static let ruff = rgb(0.93, 0.93, 0.96)
    static let nose = rgb(0.13, 0.08, 0.08)
    static let iris = rgb(0.10, 0.07, 0.06)
    static let brow = rgb(0.45, 0.40, 0.40)
    static let gold = rgb(0.95, 0.77, 0.33)
    static let goldDark = rgb(0.62, 0.45, 0.14)
    static let bowTie = rgb(0.62, 0.08, 0.17)
    static let bowTieDark = rgb(0.38, 0.03, 0.09)
    static let hat = rgb(0.13, 0.13, 0.16)
    static let hatRim = rgb(0.55, 0.55, 0.62)

    static let leather = rgb(0.47, 0.28, 0.15)
    static let leatherDark = rgb(0.19, 0.10, 0.05)
    static let leatherLight = rgb(0.86, 0.63, 0.39)
    static let cracker = rgb(0.96, 0.91, 0.80)
    static let wood = rgb(0.55, 0.33, 0.16)
    static let woodDark = rgb(0.30, 0.16, 0.07)
    static let brass = rgb(0.93, 0.74, 0.33)
}

// MARK: - The icon

/// How much detail a size can carry.
enum Detail: Int, Comparable {
    case tiny, small, medium, full
    static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
    init(pixels: Int) { self = pixels <= 16 ? .tiny : pixels <= 32 ? .small : pixels <= 64 ? .medium : .full }
}

/// Draws the icon into a context whose user space is 1024 × 1024, y down.
struct IconPainter {
    let ctx: CGContext
    let detail: Detail
    /// Device pixels per design unit.
    let k: CGFloat

    // Layout, in the 1024 design space.
    var tileRect: CGRect {
        switch detail {
        case .tiny: return CGRect(x: 40, y: 40, width: 944, height: 944)
        case .small: return CGRect(x: 64, y: 64, width: 896, height: 896)
        default: return CGRect(x: 100, y: 100, width: 824, height: 824)
        }
    }
    /// Top-left of Lash's 100-unit box, and its side.
    var lashBox: CGRect {
        switch detail {
        case .tiny: return CGRect(x: 92, y: 168, width: 840, height: 840)
        case .small: return CGRect(x: 94, y: 214, width: 800, height: 800)
        default: return CGRect(x: 158, y: 336, width: 580, height: 580)
        }
    }
    /// Where the whip cracks (and the glass breaks).
    var crackPoint: CGPoint {
        switch detail {
        case .tiny: return P(846, 196)
        case .small: return P(810, 200)
        default: return P(312, 258)
        }
    }

    func draw() {
        drawTile()
        if detail >= .medium {
            drawGlassCrack()
            drawWhip()
        }
        drawLash()
        drawSpark(at: crackPoint)
    }

    // MARK: Tile

    private func drawTile() {
        let tile = squircle(tileRect, radius: tileRect.width * 0.225)
        if detail >= .medium {
            // The drop shadow macOS icons sit on.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 24 * k, color: rgb(0, 0, 0, 0.45))
            ctx.addPath(tile)
            ctx.setFillColor(rgb(0.08, 0.07, 0.12))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        // Deep plum night, lighter at the top like a screen catching the room light. Small sizes get a brighter
        // plum so the head stands out against it.
        let plum: [(CGColor, CGFloat)] = detail <= .small
            ? [(rgb(0.46, 0.30, 0.66), 0), (rgb(0.27, 0.17, 0.42), 0.6), (rgb(0.16, 0.10, 0.26), 1)]
            : [(rgb(0.25, 0.18, 0.38), 0), (rgb(0.12, 0.09, 0.20), 0.55), (rgb(0.05, 0.04, 0.08), 1)]
        ctx.drawLinearGradient(gradient(plum), start: P(512, tileRect.minY), end: P(512, tileRect.maxY), options: [])
        // A mischievous purple glow behind Lash.
        let face = lashPoint(50, 60)
        ctx.drawRadialGradient(gradient([(rgb(0.62, 0.30, 0.95, 0.55), 0), (rgb(0.50, 0.22, 0.80, 0.18), 0.55), (rgb(0.4, 0.2, 0.7, 0), 1)]),
                               startCenter: face, startRadius: 0, endCenter: face, endRadius: lashBox.width * 0.78, options: [])
        // A warm flush from the crack.
        ctx.drawRadialGradient(gradient([(rgb(1.0, 0.72, 0.30, 0.30), 0), (rgb(1.0, 0.55, 0.20, 0), 1)]),
                               startCenter: crackPoint, startRadius: 0, endCenter: crackPoint, endRadius: 360, options: [])
        if detail >= .medium {
            // Glass: a soft diagonal sheen across the top-left.
            let sheen = CGMutablePath()
            sheen.move(to: P(tileRect.minX, tileRect.minY))
            sheen.addLine(to: P(tileRect.minX + 700, tileRect.minY))
            sheen.addLine(to: P(tileRect.minX, tileRect.minY + 560))
            sheen.closeSubpath()
            ctx.saveGState()
            ctx.addPath(sheen)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(rgb(1, 1, 1, 0.07), 0), (rgb(1, 1, 1, 0.0), 1)]),
                                   start: P(tileRect.minX, tileRect.minY), end: P(tileRect.minX + 320, tileRect.minY + 320), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
        // A hairline bezel so the dark tile doesn't dissolve into a dark Dock.
        ctx.saveGState()
        ctx.addPath(squircle(tileRect.insetBy(dx: 1.5, dy: 1.5), radius: (tileRect.width - 3) * 0.225))
        ctx.setLineWidth(max(3, 0.8 / k))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient([(rgb(1, 1, 1, 0.28), 0), (rgb(1, 1, 1, 0.06), 0.5), (rgb(1, 1, 1, 0.12), 1)]),
                               start: P(512, tileRect.minY), end: P(512, tileRect.maxY), options: [])
        ctx.restoreGState()
    }

    // MARK: Glass crack

    /// A spiderweb in the glass around the crack point: jagged radial cracks plus broken rings between them.
    private func drawGlassCrack() {
        var rng = Seeded(state: 0xC0FFEE)
        let center = crackPoint
        let radials = 8
        var spokes: [[CGPoint]] = []
        for i in 0..<radials {
            var angle = CGFloat(i) / CGFloat(radials) * 2 * .pi + rng.range(-0.3, 0.3)
            let reach = rng.range(170, 470)
            var p = center + P(cos(angle), sin(angle)) * rng.range(8, 18)
            var spoke = [p]
            var travelled: CGFloat = 0
            while travelled < reach {
                let step = rng.range(26, 62)
                angle += rng.range(-0.34, 0.34)
                p = p + P(cos(angle), sin(angle)) * step
                spoke.append(p)
                travelled += step
            }
            spokes.append(spoke)
        }
        let cracks = CGMutablePath()
        for spoke in spokes { cracks.addLines(between: spoke) }
        // Rings: join neighbouring spokes at similar distances with slightly sagging segments.
        for (ring, odds) in [(2, 0.7), (4, 0.4)] as [(Int, CGFloat)] {
            for i in 0..<radials where rng.next() < odds {
                let a = spokes[i], b = spokes[(i + 1) % radials]
                guard ring < a.count, ring < b.count else { continue }
                let pa = a[ring], pb = b[ring]
                let mid = (pa + pb) * 0.5
                let sag = center + (mid - center) * rng.range(0.86, 0.96)
                cracks.move(to: pa)
                cracks.addLine(to: sag)
                cracks.addLine(to: pb)
            }
        }
        ctx.saveGState()
        ctx.addPath(squircle(tileRect, radius: tileRect.width * 0.225))
        ctx.clip()
        // Fade the web out with distance from the impact.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(cracks)
        ctx.setStrokeColor(rgb(0, 0, 0, 0.5))
        ctx.setLineWidth(max(4, 1.0 / k))
        ctx.strokePath()
        ctx.translateBy(x: -1.5, y: -1.5)
        ctx.addPath(cracks)
        ctx.setStrokeColor(rgb(0.93, 0.95, 1.0, 0.9))
        ctx.setLineWidth(max(1.8, 0.55 / k))
        ctx.strokePath()
        ctx.translateBy(x: 1.5, y: 1.5)
        // Mask: bright near the impact, gone at the far ends.
        ctx.setBlendMode(.destinationIn)
        ctx.drawRadialGradient(gradient([(rgb(0, 0, 0, 1), 0), (rgb(0, 0, 0, 0.6), 0.4), (rgb(0, 0, 0, 0), 1)]),
                               startCenter: center, startRadius: 0, endCenter: center, endRadius: 520, options: [])
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Whip

    /// The thong's centreline, from the handle's ferrule to the cracker: up the right side, a curl over the
    /// top-right, then a snap across the top toward the crack point.
    private var thongPoints: [CGPoint] {
        [P(790, 662), P(804, 566), P(846, 464), P(870, 364), P(846, 272), P(772, 228), P(716, 272), P(744, 336),
         P(810, 320), P(810, 236), P(730, 178), P(600, 172), P(478, 200), P(392, 236), P(346, 250)]
    }

    private func drawWhip() {
        let pts = spline(thongPoints, count: 260)
        let n = pts.count
        let widths = (0..<n).map { i -> CGFloat in
            let u = CGFloat(i) / CGFloat(n - 1)
            return 7 + 27 * pow(1 - u, 1.25)
        }
        // The curl crosses itself: the part after the crossing is drawn on top, with its own outline.
        let split = n * 44 / 100
        let portions = [0..<(split + 1), split..<n]

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 6 * k, height: -14 * k), blur: 22 * k, color: rgb(0, 0, 0, 0.5))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for portion in portions {
            drawThong(pts, widths: widths, range: portion)
        }
        drawCracker(pts)
        drawHandle(ferrule: pts[0], direction: (pts[0] - pts[6]).unit)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func drawThong(_ pts: [CGPoint], widths: [CGFloat], range: Range<Int>) {
        let outline = ribbon(pts, widths: widths.map { $0 + 7 }, range: range)
        ctx.addPath(outline)
        ctx.setFillColor(Ink.leatherDark)
        ctx.fillPath()
        let body = ribbon(pts, widths: widths, range: range)
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.addPath(body)
        ctx.setFillColor(Ink.leather)
        ctx.fillPath()
        // Plaited chevrons pointing down the thong.
        let tan = tangents(pts)
        ctx.setStrokeColor(Ink.leatherDark.copy(alpha: 0.55)!)
        ctx.setLineCap(.round)
        var i = range.lowerBound + 2
        while i < range.upperBound - 3, widths[i] > 10 {
            let nrm = tan[i].perp, w = widths[i]
            let ahead = pts[min(pts.count - 1, i + 3)]
            ctx.move(to: pts[i] + nrm * (w * 0.55))
            ctx.addLine(to: ahead)
            ctx.addLine(to: pts[i] - nrm * (w * 0.55))
            ctx.setLineWidth(max(2.2, w * 0.1))
            ctx.strokePath()
            i += max(4, Int(w / 3.2))
        }
        // A light catching the upper side.
        let shine = ribbon(pts, widths: widths.map { $0 * 0.2 }, offsets: widths.map { $0 * 0.22 }, range: range)
        ctx.addPath(shine)
        ctx.setFillColor(Ink.leatherLight.copy(alpha: 0.55)!)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The frayed cream popper that actually breaks the sound barrier.
    private func drawCracker(_ pts: [CGPoint]) {
        let tip = pts[pts.count - 1]
        let dir = (tip - pts[pts.count - 6]).unit
        ctx.setStrokeColor(Ink.cracker)
        ctx.setLineCap(.round)
        for (spread, length, width) in [(-0.38, 44.0, 4.5), (0.0, 54.0, 5.5), (0.34, 42.0, 4.5)] as [(CGFloat, CGFloat, CGFloat)] {
            let a = atan2(dir.y, dir.x) + spread
            let end = tip + P(cos(a), sin(a)) * length
            let mid = tip + dir * (length * 0.5) + dir.perp * (spread * 12)
            ctx.move(to: tip)
            ctx.addQuadCurve(to: end, control: mid)
            ctx.setLineWidth(width)
            ctx.strokePath()
        }
    }

    /// A wooden grip with a leather wrap, a brass ferrule where the thong starts and a brass pommel.
    private func drawHandle(ferrule: CGPoint, direction: CGPoint) {
        let length: CGFloat = 164, radius: CGFloat = 27
        ctx.saveGState()
        ctx.translateBy(x: ferrule.x, y: ferrule.y)
        ctx.rotate(by: atan2(direction.y, direction.x))
        // Local frame: x runs from the ferrule (0) to the pommel (length).
        let grip = CGPath(roundedRect: CGRect(x: 6, y: -radius, width: length - 12, height: 2 * radius),
                          cornerWidth: 14, cornerHeight: 14, transform: nil)
        ctx.addPath(grip)
        ctx.setFillColor(Ink.woodDark)
        ctx.setLineWidth(7)
        ctx.drawPath(using: .fillStroke)
        ctx.saveGState()
        ctx.addPath(grip)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(Ink.woodDark, 0), (Ink.wood, 0.35), (rgb(0.72, 0.47, 0.26), 0.5), (Ink.wood, 0.7), (Ink.woodDark, 1)]),
                               start: P(0, -radius), end: P(0, radius), options: [])
        // Leather wrap: diagonal bands.
        ctx.setStrokeColor(Ink.leatherDark.copy(alpha: 0.75)!)
        ctx.setLineWidth(6)
        var x: CGFloat = 20
        while x < length + 30 {
            ctx.move(to: P(x - 18, -radius - 2))
            ctx.addLine(to: P(x + 10, radius + 2))
            x += 24
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Ferrule band and pommel.
        let band = CGPath(roundedRect: CGRect(x: -6, y: -radius - 4, width: 26, height: 2 * radius + 8),
                          cornerWidth: 6, cornerHeight: 6, transform: nil)
        let knob = ellipse(P(length + 8, 0), 31, 31)
        for shape in [band, knob] {
            ctx.addPath(shape)
            ctx.setStrokeColor(Ink.leatherDark)
            ctx.setLineWidth(7)
            ctx.strokePath()
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.clip()
            let box = shape.boundingBox
            ctx.drawLinearGradient(gradient([(rgb(1, 0.93, 0.66), 0), (Ink.brass, 0.4), (rgb(0.62, 0.43, 0.14), 1)]),
                                   start: P(box.midX, box.minY), end: P(box.midX, box.maxY), options: [])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: Spark

    /// The crack itself: a hot white-gold starburst with a few flying sparks.
    private func drawSpark(at c: CGPoint) {
        let scale: CGFloat = detail == .tiny ? 2.1 : detail == .small ? 1.75 : detail == .medium ? 1.2 : 1
        ctx.saveGState()
        ctx.drawRadialGradient(gradient([(rgb(1, 0.95, 0.7, 0.95), 0), (rgb(1, 0.75, 0.25, 0.55), 0.3), (rgb(1, 0.5, 0.1, 0), 1)]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 120 * scale, options: [])
        // Eight-point star: long rays on the diagonals of a slightly turned cross.
        let star = CGMutablePath()
        let radii: [CGFloat] = [82, 20, 48, 20, 82, 20, 48, 20, 82, 20, 48, 20, 82, 20, 48, 20]
        for (j, r) in radii.enumerated() {
            let a = CGFloat(j) / CGFloat(radii.count) * 2 * .pi - .pi / 2 + 0.22
            let p = c + P(cos(a), sin(a)) * (r * scale)
            if j == 0 { star.move(to: p) } else { star.addLine(to: p) }
        }
        star.closeSubpath()
        ctx.addPath(star)
        ctx.setStrokeColor(rgb(1, 0.52, 0.08))
        ctx.setLineWidth(9 * scale)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.saveGState()
        ctx.addPath(star)
        ctx.clip()
        ctx.drawRadialGradient(gradient([(rgb(1, 1, 1), 0), (rgb(1, 1, 0.85), 0.35), (rgb(1, 0.82, 0.25), 1)]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: 80 * scale, options: [])
        ctx.restoreGState()
        if detail >= .medium {
            // Sparks flung outward.
            ctx.setStrokeColor(rgb(1, 0.82, 0.3))
            ctx.setLineCap(.round)
            ctx.setLineWidth(7)
            for (angle, r0, r1) in [(-2.5, 102.0, 136.0), (-1.05, 98.0, 132.0), (0.45, 100.0, 132.0), (2.2, 104.0, 132.0), (3.05, 98.0, 126.0)] as [(CGFloat, CGFloat, CGFloat)] {
                ctx.move(to: c + P(cos(angle), sin(angle)) * r0)
                ctx.addLine(to: c + P(cos(angle), sin(angle)) * r1)
            }
            ctx.strokePath()
            ctx.setFillColor(rgb(1, 0.92, 0.6))
            for (angle, r, size) in [(-1.75, 132.0, 6.5), (-0.2, 152.0, 6.0), (1.35, 142.0, 5.0), (-2.95, 150.0, 5.0)] as [(CGFloat, CGFloat, CGFloat)] {
                ctx.addPath(ellipse(c + P(cos(angle), sin(angle)) * r, size, size))
            }
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    // MARK: Lash

    /// A point in Lash's unit box (0...100, y down) in design space.
    private func lashPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        P(lashBox.minX + x / 100 * lashBox.width, lashBox.minY + y / 100 * lashBox.height)
    }

    /// Lash as LashPainter draws him, but with a face made for the icon: scheming half-lidded side-eye, one brow
    /// cocked and a wide grin under a button nose.
    private func drawLash() {
        let unitPx = k * lashBox.width / 100
        /// A line width in Lash units that never drops below `px` device pixels.
        func line(_ units: CGFloat, minPx: CGFloat = 0.75) -> CGFloat { max(units, minPx / unitPx) }

        ctx.saveGState()
        ctx.translateBy(x: lashBox.minX, y: lashBox.minY)
        ctx.scaleBy(x: lashBox.width / 100, y: lashBox.height / 100)

        // Everything but the face features casts one soft shadow onto the glass.
        ctx.saveGState()
        if detail >= .medium {
            ctx.setShadow(offset: CGSize(width: 0, height: -16 * k), blur: 30 * k, color: rgb(0, 0, 0, 0.55))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        drawRuff(line: line)
        drawEars(line: line)
        drawHead(line: line)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        if detail >= .small { drawCheeks() }
        drawEyes(line: line)
        if detail >= .small { drawMonocle(line: line) }
        if detail >= .small { drawBrows(line: line) }
        drawMouth(line: line)
        drawNose()
        drawBowTie(line: line)
        drawTopHat(line: line)
        ctx.restoreGState()
    }

    private func mirrored(_ path: CGPath) -> CGPath {
        var t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
        return path.copy(using: &t)!
    }

    /// A soft, scalloped outline round an ellipse: `bumps` tufts of fur (as LashPainter.fluff).
    private func fluff(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, bumps: Int, depth: CGFloat, phase: CGFloat = 0) -> CGPath {
        func point(_ angle: CGFloat, _ out: CGFloat) -> CGPoint { P(c.x + (rx + out) * cos(angle), c.y + (ry + out) * sin(angle)) }
        let p = CGMutablePath()
        let step = 2 * .pi / CGFloat(bumps)
        p.move(to: point(phase, 0))
        for i in 0..<bumps {
            let a0 = phase + CGFloat(i) * step
            p.addQuadCurve(to: point(a0 + step, 0), control: point(a0 + step / 2, depth * 2))
        }
        p.closeSubpath()
        return p
    }

    /// The big fluffy ruff behind the face.
    private func drawRuff(line: (CGFloat, CGFloat) -> CGFloat) {
        let ruff = fluff(P(50, 66), 43, 34, bumps: 16, depth: 3.6, phase: 0.2)
        ctx.saveGState()
        ctx.addPath(ruff)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(Ink.ruff, 0), (Ink.skinBottom, 1)]), start: P(50, 30), end: P(50, 104), options: [])
        ctx.restoreGState()
        ctx.addPath(ruff)
        ctx.setStrokeColor(Ink.rim.copy(alpha: 0.55)!)
        ctx.setLineWidth(line(1.2, 0.5))
        ctx.strokePath()
    }

    /// Pointy upright ears, white with pink insides (behind the face).
    private func drawEars(line: (CGFloat, CGFloat) -> CGFloat) {
        let ear = CGMutablePath()
        ear.move(to: P(17, 42))
        ear.addQuadCurve(to: P(21.5, 6), control: P(9, 20))
        ear.addQuadCurve(to: P(43, 29), control: P(31, 11))
        ear.closeSubpath()
        let inner = CGMutablePath()
        inner.move(to: P(22, 36))
        inner.addQuadCurve(to: P(23.5, 13), control: P(17, 22))
        inner.addQuadCurve(to: P(37, 29), control: P(30, 17))
        inner.closeSubpath()
        for (outer, hole) in [(ear as CGPath, inner as CGPath), (mirrored(ear), mirrored(inner))] {
            ctx.addPath(outer)
            ctx.setFillColor(Ink.skinTop)
            ctx.fillPath()
            ctx.addPath(outer)
            ctx.setStrokeColor(Ink.rim.copy(alpha: 0.7)!)
            ctx.setLineWidth(line(1.2, 0.5))
            ctx.strokePath()
            ctx.addPath(hole)
            ctx.setFillColor(Ink.innerEar)
            ctx.fillPath()
        }
    }

    /// A gold monocle over his right eye, its chain looping down to the ruff.
    private func drawMonocle(line: (CGFloat, CGFloat) -> CGFloat) {
        let c = P(63, 53), r: CGFloat = 13.6
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [2, 1.6])
        ctx.move(to: P(c.x + r * 0.72, c.y + r * 0.7))
        ctx.addQuadCurve(to: P(84, 92), control: P(86, 70))
        ctx.setStrokeColor(Ink.goldDark)
        ctx.setLineWidth(line(1.2, 0.5))
        ctx.strokePath()
        ctx.restoreGState()
        for (color, width) in [(Ink.goldDark, CGFloat(3.2)), (Ink.gold, CGFloat(2))] {
            ctx.addPath(ellipse(c, r, r))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(line(width, 0.6))
            ctx.strokePath()
        }
        ctx.addArc(center: c, radius: r - 3.2, startAngle: 200 * .pi / 180, endAngle: 245 * .pi / 180, clockwise: false)
        ctx.setStrokeColor(rgb(1, 1, 1, 0.85))
        ctx.setLineCap(.round)
        ctx.setLineWidth(line(1.6, 0.5))
        ctx.strokePath()
    }

    /// A burgundy bow tie under the chin.
    private func drawBowTie(line: (CGFloat, CGFloat) -> CGFloat) {
        let knot = P(50, 95)
        for side: CGFloat in [-1, 1] {
            let wing = CGMutablePath()
            wing.move(to: P(knot.x + side * 2, knot.y))
            wing.addQuadCurve(to: P(knot.x + side * 13, knot.y - 6.5), control: P(knot.x + side * 6, knot.y - 5))
            wing.addQuadCurve(to: P(knot.x + side * 13, knot.y + 6.5), control: P(knot.x + side * 15.5, knot.y))
            wing.addQuadCurve(to: P(knot.x + side * 2, knot.y), control: P(knot.x + side * 6, knot.y + 5))
            wing.closeSubpath()
            ctx.saveGState()
            ctx.addPath(wing)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(Ink.bowTie, 0), (Ink.bowTieDark, 1)]), start: P(knot.x, knot.y - 6), end: P(knot.x, knot.y + 6), options: [])
            ctx.restoreGState()
            ctx.addPath(wing)
            ctx.setStrokeColor(Ink.bowTieDark)
            ctx.setLineWidth(line(0.9, 0.4))
            ctx.strokePath()
        }
        let middle = CGPath(roundedRect: CGRect(x: knot.x - 3.2, y: knot.y - 4, width: 6.4, height: 8), cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.addPath(middle)
        ctx.setFillColor(Ink.bowTie)
        ctx.fillPath()
    }

    /// A dapper little top hat, tipped to one side between the ears.
    private func drawTopHat(line: (CGFloat, CGFloat) -> CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: 53, y: 25)
        ctx.rotate(by: 9 * .pi / 180)
        let crown = CGPath(roundedRect: CGRect(x: -10.5, y: -21, width: 21, height: 19.5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        let brim = CGPath(roundedRect: CGRect(x: -16, y: -3, width: 32, height: 5.5), cornerWidth: 2.75, cornerHeight: 2.75, transform: nil)
        ctx.saveGState()
        ctx.addPath(crown)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(Ink.hat, 0), (rgb(0.24, 0.24, 0.29), 1)]), start: P(-10, -14), end: P(10, -14), options: [])
        ctx.setFillColor(Ink.bowTie)
        ctx.fill(CGRect(x: -10.5, y: -7, width: 21, height: 4))
        if detail >= .small {
            ctx.setFillColor(rgb(1, 1, 1, 0.28))
            ctx.addPath(CGPath(roundedRect: CGRect(x: -7.5, y: -19, width: 2.4, height: 11), cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
        for shape in [crown, brim] {
            if shape === brim {
                ctx.addPath(brim)
                ctx.setFillColor(Ink.hat)
                ctx.fillPath()
            }
            ctx.addPath(shape)
            ctx.setStrokeColor(Ink.hatRim.copy(alpha: 0.9)!)
            ctx.setLineWidth(line(1, 0.5))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// A black button nose with a shine, on top of the grin.
    private func drawNose() {
        let nose = CGMutablePath()
        nose.move(to: P(42.5, 67.5))
        nose.addQuadCurve(to: P(57.5, 67.5), control: P(50, 64))
        nose.addQuadCurve(to: P(50, 76), control: P(58, 72.5))
        nose.addQuadCurve(to: P(42.5, 67.5), control: P(42, 72.5))
        nose.closeSubpath()
        ctx.addPath(nose)
        ctx.setFillColor(Ink.nose)
        ctx.fillPath()
        if detail >= .small {
            ctx.addPath(ellipse(P(48, 68.25), 2, 1.15))
            ctx.setFillColor(rgb(1, 1, 1, 0.75))
            ctx.fillPath()
        }
    }

    private var headPath: CGPath { fluff(P(50, 59), 34, 32, bumps: 24, depth: 0.8) }

    private func drawHead(line: (CGFloat, CGFloat) -> CGFloat) {
        ctx.saveGState()
        ctx.addPath(headPath)
        ctx.clip()
        ctx.drawLinearGradient(gradient([(Ink.skinTop, 0), (Ink.skinBottom, 1)]), start: P(50, 27), end: P(50, 92), options: [])
        // The snout: a touch brighter, with a faint shadow along its lower edge.
        ctx.addPath(ellipse(P(50, 75.5), 16, 13.5))
        ctx.setFillColor(Ink.skinTop)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addArc(center: P(50, 75.5), radius: 16, startAngle: 25 * .pi / 180, endAngle: 155 * .pi / 180, clockwise: false)
        ctx.setStrokeColor(Ink.rim.copy(alpha: 0.45)!)
        ctx.setLineWidth(line(1, 0.5))
        ctx.strokePath()
        ctx.addPath(headPath)
        ctx.setStrokeColor(Ink.rim.copy(alpha: 0.5)!)
        ctx.setLineWidth(line(1.5, detail == .tiny ? 0.6 : 0.8))
        ctx.strokePath()
        if detail >= .small {
            // A soft sheen on the forehead.
            ctx.saveGState()
            ctx.translateBy(x: 37, y: 33)
            ctx.rotate(by: -24 * .pi / 180)
            ctx.addPath(ellipse(.zero, 10, 3.6))
            ctx.setFillColor(rgb(1, 1, 1, 0.16))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    private func drawCheeks() {
        for c in [P(22.5, 71), P(77.5, 71)] {
            ctx.saveGState()
            ctx.addPath(ellipse(c, 9, 6))
            ctx.clip()
            ctx.drawRadialGradient(gradient([(Ink.blush.copy(alpha: 0.85)!, 0), (Ink.blush.copy(alpha: 0)!, 1)]),
                                   startCenter: c, startRadius: 0, endCenter: c, endRadius: 8.5, options: [])
            ctx.restoreGState()
        }
    }

    private func drawEyes(line: (CGFloat, CGFloat) -> CGFloat) {
        // Scheming: lids lowered and slanted toward the nose, pupils sliding right toward the whip.
        let big = detail <= .small
        // At 16 px a lid would eat the whole eye: there it's just two big whites with pupils.
        let lidOpen: CGFloat = detail == .tiny ? 1 : big ? 0.8 : 0.7
        let slant: CGFloat = detail == .tiny ? 0 : big ? 0.28 : 0.3
        let pupilScale: CGFloat = detail == .tiny ? 1.4 : big ? 1.12 : 0.95
        let eyeScale: CGFloat = detail == .tiny ? 1.02 : 1
        let gaze = detail == .tiny ? P(0.5, 0.15) : P(0.62, 0.22)
        for (c, isLeft) in [(P(37, 53), true), (P(63, 53), false)] {
            let rx: CGFloat = 10.5 * eyeScale, ry: CGFloat = 12 * eyeScale
            let rect = CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)
            let eye = ellipse(c, rx, ry)
            ctx.saveGState()
            ctx.addPath(eye)
            ctx.clip()
            ctx.drawLinearGradient(gradient([(Ink.eyeWhite, 0), (Ink.eyeShade, 1)]),
                                   start: P(c.x, rect.minY + ry * 0.8), end: P(c.x, rect.maxY), options: [])
            let pr = 6.1 * pupilScale
            let pupil = P(c.x + gaze.x * (rx - pr - 1.4), c.y + gaze.y * (ry - pr - 1.4))
            ctx.addPath(ellipse(pupil, pr, pr))
            ctx.setFillColor(Ink.iris)
            ctx.fillPath()
            if detail >= .small {
                let glint = max(1.2, pr * 0.36)
                ctx.addPath(ellipse(P(pupil.x - pr * 0.42, pupil.y - pr * 0.45), glint, glint))
                ctx.setFillColor(rgb(1, 1, 1))
                ctx.fillPath()
                if detail >= .medium {
                    ctx.addPath(ellipse(P(pupil.x + pr * 0.35 + glint * 0.45, pupil.y + pr * 0.3 + glint * 0.45), glint * 0.45, glint * 0.45))
                    ctx.setFillColor(rgb(1, 1, 1, 0.8))
                    ctx.fillPath()
                }
            }
            // Upper lid.
            if lidOpen < 1 {
                let inward: CGFloat = isLeft ? 1 : -1
                let mid = rect.minY + (1 - lidOpen) * 2 * ry
                let drop = slant * ry
                let x0 = rect.minX - 2, x1 = rect.maxX + 2
                let y0 = mid + drop * ((x0 - c.x) / rx) * inward
                let y1 = mid + drop * ((x1 - c.x) / rx) * inward
                let lid = CGMutablePath()
                lid.addLines(between: [P(x0, rect.minY - 4), P(x1, rect.minY - 4), P(x1, y1), P(x0, y0)])
                lid.closeSubpath()
                ctx.addPath(lid)
                ctx.setFillColor(Ink.lid)
                ctx.fillPath()
                ctx.move(to: P(x0, y0))
                ctx.addLine(to: P(x1, y1))
                ctx.setStrokeColor(Ink.ink)
                ctx.setLineWidth(line(2.2, 0.7))
                ctx.strokePath()
            }
            ctx.restoreGState()
            if detail >= .small {
                ctx.addPath(eye)
                ctx.setStrokeColor(Ink.ink)
                ctx.setLineWidth(line(1.5, 0.6))
                ctx.strokePath()
            }
        }
    }

    private func drawBrows(line: (CGFloat, CGFloat) -> CGFloat) {
        // Left brow dives toward the nose; the right one is cocked up: "I know something you don't."
        let brows: [(outer: CGPoint, inner: CGPoint, arch: CGFloat)] = [
            (P(27, 36.5), P(45.5, 42), -0.4),
            (P(73.5, 32.5), P(55, 37.5), 2.2),
        ]
        ctx.setStrokeColor(Ink.brow)
        ctx.setLineCap(.round)
        ctx.setLineWidth(line(3.8, 0.9))
        for brow in brows {
            let mid = (brow.outer + brow.inner) * 0.5 - P(0, brow.arch * 2)
            ctx.move(to: brow.outer)
            ctx.addQuadCurve(to: brow.inner, control: mid)
        }
        ctx.strokePath()
    }

    private func drawMouth(line: (CGFloat, CGFloat) -> CGFloat) {
        // A wide, lopsided grin: the right corner hikes up.
        let left = P(32.5, 73.5), right = P(67.5, 70.5), lip = P(49, 80.5)
        let mouth = CGMutablePath()
        mouth.move(to: left)
        mouth.addQuadCurve(to: right, control: lip)
        mouth.addQuadCurve(to: P(51, 89.5), control: P(66.5, 88))
        mouth.addQuadCurve(to: left, control: P(35, 89))
        mouth.closeSubpath()
        ctx.addPath(mouth)
        ctx.setFillColor(Ink.mouth)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(mouth)
        ctx.clip()
        ctx.addPath(detail == .tiny ? ellipse(P(51, 85), 13, 8) : ellipse(P(51, 87.5), 10, 6))
        ctx.setFillColor(Ink.tongue)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(mouth)
        ctx.setStrokeColor(Ink.ink)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(line(1.8, 0.7))
        ctx.strokePath()
    }
}

// MARK: - Rendering and packaging

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixels) / 1024
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: k, y: -k)
    IconPainter(ctx: ctx, detail: Detail(pixels: pixels), k: k).draw()
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

/// Every size at 1×, on a dark and a light strip, plus the two smallest blown up with hard pixels.
func contactSheet(_ images: [Int: CGImage]) -> CGImage {
    let sizes = [512, 256, 128, 64, 32, 16]
    let gap = 28
    let width = sizes.reduce(gap) { $0 + $1 + gap }
    let stripHeight = 512 + 2 * gap
    let zoomHeight = 16 * 12 + 2 * gap
    let height = 2 * stripHeight + zoomHeight
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CG's default space is y up: the dark strip is drawn at the top.
    for (row, shade) in [(0, 0.12), (1, 0.93)] as [(Int, CGFloat)] {
        let y = height - (row + 1) * stripHeight
        ctx.setFillColor(rgb(shade, shade, shade))
        ctx.fill(CGRect(x: 0, y: y, width: width, height: stripHeight))
        var x = gap
        for size in sizes {
            ctx.draw(images[size]!, in: CGRect(x: x, y: y + gap + (512 - size) / 2, width: size, height: size))
            x += size + gap
        }
    }
    ctx.setFillColor(rgb(0.2, 0.2, 0.22))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: zoomHeight))
    ctx.interpolationQuality = .none
    var x = gap
    for (size, zoom) in [(16, 12), (32, 6), (64, 3)] {
        ctx.draw(images[size]!, in: CGRect(x: x, y: gap, width: size * zoom, height: size * zoom))
        x += size * zoom + gap
    }
    return ctx.makeImage()!
}

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let scriptURL = URL(fileURLWithPath: #filePath)
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let keepIconset = option("--iconset").map { URL(fileURLWithPath: $0) }
let iconset = (keepIconset ?? FileManager.default.temporaryDirectory.appendingPathComponent("Whiplash-\(UUID().uuidString)"))
    .appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var images: [Int: CGImage] = [:]
for pixels in [16, 32, 64, 128, 256, 512, 1024] { images[pixels] = render(pixels: pixels) }
for points in [16, 32, 128, 256, 512] {
    writePNG(images[points]!, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(images[points * 2]!, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed (\(iconutil.terminationStatus))") }
if keepIconset == nil { try? FileManager.default.removeItem(at: iconset.deletingLastPathComponent()) }
print("Wrote \(output.path)")

if let preview = option("--preview") {
    let url = URL(fileURLWithPath: preview)
    writePNG(contactSheet(images), to: url)
    writePNG(images[1024]!, to: url.deletingPathExtension().appendingPathExtension("1024.png"))
    print("Wrote \(url.path)")
}
