import CoreGraphics

/// Decides where the scripted strikes land. Everything here is in scene coordinates.
enum StrikeTargeting {
    /// Target rects smaller than this (after clipping to the screen) are not worth aiming at.
    static let minimumTargetSize = CGSize(width: 160, height: 120)
    /// Strip at the top of the screen strikes never land in (menu bar + notch).
    static let topExclusion: CGFloat = 44
    /// Distance of the volley's later strikes from the first one, points (the webs must overlap to break out as one
    /// hole), for an aim region at least `fullSpreadSize` across; smaller regions get a tighter volley.
    static let clusterRadius: ClosedRange<CGFloat> = 120...170
    static let fullSpreadSize: CGFloat = 500
    /// Strikes after the fourth go a little wider (the hole is big by then).
    static let outerRingFactor: CGFloat = 1.3
    /// Candidates tried per strike; the one farthest from the others wins, so no two strikes land on each other.
    private static let candidatesPerStrike = 6
    private static let goldenAngle: CGFloat = 2.39996

    /// The central area of the screen, aimed at when there is no usable target.
    static func fallbackRegion(in sceneSize: CGSize) -> CGRect {
        CGRect(x: sceneSize.width * 0.22, y: sceneSize.height * 0.2,
               width: sceneSize.width * 0.56, height: sceneSize.height * 0.55)
    }

    /// The rect strikes may land in: `target` clipped to the screen (minus the menu-bar strip) and inset from its
    /// edges, so cracks never start on a window border; the central fallback when `target` is nil, off-screen or tiny.
    static func aimRegion(target: CGRect?, sceneSize: CGSize) -> CGRect {
        let usable = CGRect(x: 0, y: 0, width: sceneSize.width, height: max(0, sceneSize.height - topExclusion))
        var region = fallbackRegion(in: sceneSize)
        if let target {
            let clipped = target.standardized.intersection(usable)
            if !clipped.isNull, clipped.width >= minimumTargetSize.width, clipped.height >= minimumTargetSize.height {
                region = clipped
            }
        }
        return region.insetBy(dx: max(24, region.width * 0.12), dy: max(24, region.height * 0.12))
    }

    /// How far round a point the ink map looks when judging how much text a hit there would knock loose, points.
    static let inkRadius: CGFloat = 170
    /// Grid step for the search for the inkiest cluster centre, points.
    private static let inkSearchStep: CGFloat = 40
    /// Below this much ink (stroke edges) round the best spot there is no text worth aiming at.
    private static let minimumInk: Float = 60

    /// `count` distinct strike points clustered round one centre, so their webs join into ONE big hole in the middle
    /// of the target — with room for the taunt — instead of a few small unrelated ones. The first strike is that
    /// centre; the others ring it at golden-angle steps.
    ///
    /// With an `ink` map (screenshot mode) the centre is where the text is — the inkiest spot of the aim region, with
    /// a gentle pull towards its middle — and ring points prefer text too, so every hit has letters to knock loose.
    /// Without one, the centre sits a little above the middle of the aim region.
    static func targets<R: RandomNumberGenerator>(count: Int, target: CGRect?, sceneSize: CGSize, ink: InkMap? = nil,
                                                  using rng: inout R) -> [CGPoint] {
        guard count > 0 else { return [] }
        let region = aimRegion(target: target, sceneSize: sceneSize)
        var centre = CGPoint(x: region.midX + region.width * CGFloat.random(in: -0.06...0.06, using: &rng),
                             y: region.minY + region.height * CGFloat.random(in: 0.5...0.62, using: &rng))
        var centreInk: Float = 0
        if let ink, let inky = inkiestSpot(in: region, near: centre, ink: ink, using: &rng) {
            centre = inky.point
            centreInk = inky.ink
        }
        let scale = min(1, max(0.6, min(region.width, region.height) / fullSpreadSize))
        let base = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
        var points = [centre]
        for i in 1..<max(1, count) {
            var best = centre
            var bestClearance = -CGFloat.infinity
            for _ in 0..<candidatesPerStrike {
                let angle = base + CGFloat(i) * goldenAngle + CGFloat.random(in: -0.3...0.3, using: &rng)
                let radius = CGFloat.random(in: clusterRadius, using: &rng) * scale * (i > 3 ? outerRingFactor : 1)
                let candidate = CGPoint(x: min(region.maxX, max(region.minX, centre.x + cos(angle) * radius)),
                                        y: min(region.maxY, max(region.minY, centre.y + sin(angle) * radius)))
                var clearance = points.map { hypot($0.x - candidate.x, $0.y - candidate.y) }.min() ?? 0
                if let ink, centreInk > 0 {
                    // Text beats spacing: a spot with as much text as the centre is worth ~150 pt of clearance.
                    clearance += 150 * CGFloat(min(1.5, ink.ink(around: candidate, radius: inkRadius * 0.7) / centreInk))
                }
                if clearance > bestClearance {
                    best = candidate
                    bestClearance = clearance
                }
            }
            points.append(best)
        }
        return points
    }

    /// The spot in `region` with the most text round it, scored down gently with distance from `preferred` (so
    /// several equally busy spots favour the middle). nil when the region holds no real text.
    private static func inkiestSpot<R: RandomNumberGenerator>(in region: CGRect, near preferred: CGPoint, ink: InkMap,
                                                              using rng: inout R) -> (point: CGPoint, ink: Float)? {
        let diagonal = max(1, hypot(region.width, region.height))
        var best: (point: CGPoint, ink: Float, score: Float)?
        var y = region.minY
        while y <= region.maxY {
            var x = region.minX
            while x <= region.maxX {
                let p = CGPoint(x: x, y: y)
                let amount = ink.ink(around: p, radius: inkRadius)
                let distance = Float(hypot(p.x - preferred.x, p.y - preferred.y) / diagonal)
                let score = amount * (1 - 0.35 * distance) * Float.random(in: 0.94...1.06, using: &rng)
                if score > (best?.score ?? 0) { best = (p, amount, score) }
                x += inkSearchStep
            }
            y += inkSearchStep
        }
        guard let best, best.ink >= minimumInk else { return nil }
        return (best.point, best.ink)
    }
}
