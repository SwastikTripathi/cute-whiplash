import SwiftUI

/// The streak as a burning fuse: a hemp rope that burns down toward a bomb, with a flickering spark and embers at
/// the burning end. Unlit (no terminal frontmost) it is a still rope and costs nothing; lit, it animates.
struct BurningFuse: View {
    /// 0...1 of the fuse already burnt.
    var progress: Double
    var lit: Bool
    @Environment(\.islandFrozenTime) private var frozenTime

    var body: some View {
        TimelineView(.animation(minimumInterval: IslandFrameRate.decorative, paused: !lit || frozenTime != nil)) { timeline in
            let time = frozenTime ?? timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                FusePainter(progress: CGFloat(min(1, max(0, progress))), lit: lit, time: time).draw(in: ctx, size: size)
            }
        }
        .frame(height: 24)
        .accessibilityLabel("Fuse, \(Int(progress * 100)) percent burnt")
    }
}

private struct FusePainter {
    let progress: CGFloat
    let lit: Bool
    let time: TimeInterval

    private static let hemp = Color(.sRGB, red: 0.84, green: 0.66, blue: 0.42)
    private static let hempDark = Color(.sRGB, red: 0.52, green: 0.36, blue: 0.19)
    private static let spark = Color(.sRGB, red: 1.0, green: 0.62, blue: 0.18)
    private static let sparkCore = Color(.sRGB, red: 1.0, green: 0.95, blue: 0.7)

    func draw(in ctx: GraphicsContext, size: CGSize) {
        let bomb = CGPoint(x: size.width - 11, y: size.height / 2 + 1.5)
        let start = CGPoint(x: 5, y: size.height / 2)
        let end = CGPoint(x: bomb.x - 7, y: bomb.y - 7)
        // The rope sags in a lazy wave from start to the bomb's cap.
        func point(_ u: CGFloat) -> CGPoint {
            CGPoint(x: start.x + (end.x - start.x) * u,
                    y: start.y + (end.y - start.y) * u * u + sin(u * .pi * 2.4) * 2.2 * (1 - u))
        }
        func rope(from a: CGFloat, to b: CGFloat) -> Path {
            var p = Path()
            let steps = max(2, Int((b - a) * 80))
            for i in 0...steps {
                let pt = point(a + (b - a) * CGFloat(i) / CGFloat(steps))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }

        drawBomb(at: bomb, in: ctx, urgent: lit ? progress : 0)

        // Burnt part: a trail of ash.
        if progress > 0.01 {
            ctx.stroke(rope(from: 0, to: progress), with: .color(.white.opacity(0.2)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1.5, 3]))
        }
        // What's left: twisted hemp — a shaded cord with slanted strands wound around it.
        if progress < 0.995 {
            let remaining = rope(from: progress, to: 1)
            let dim = lit ? 1.0 : 0.6
            let cord = StrokeStyle(lineWidth: 5.4, lineCap: .round)
            var shade = ctx
            shade.translateBy(x: 0, y: 0.9)
            shade.stroke(remaining, with: .color(Self.hempDark.opacity(dim)), style: cord)
            ctx.stroke(remaining, with: .color(Self.hemp.opacity(dim)), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))
            var strands = ctx
            strands.clip(to: remaining.strokedPath(cord))
            strands.stroke(twist(from: progress, along: point), with: .color(Self.hempDark.opacity(0.9 * dim)),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            var sheen = ctx
            sheen.translateBy(x: 0, y: -1.2)
            sheen.stroke(remaining, with: .color(.white.opacity(lit ? 0.3 : 0.14)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }

        let head = point(progress)
        if lit {
            drawSpark(at: head, in: ctx)
        } else if progress > 0.01 {
            // A cold, charred tip.
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - 2.6, y: head.y - 2.6, width: 5.2, height: 5.2)), with: .color(.white.opacity(0.3)))
        }
    }

    /// Slanted strand marks every few points from `start` to the bomb, following the rope's curve.
    private func twist(from start: CGFloat, along point: (CGFloat) -> CGPoint) -> Path {
        var strands = Path()
        let spacing: CGFloat = 3.1
        var u = start
        var here = point(u)
        while u < 1 {
            let next = point(min(1, u + 0.01))
            let dx = next.x - here.x, dy = next.y - here.y
            let len = max(0.001, hypot(dx, dy))
            let t = CGPoint(x: dx / len, y: dy / len), n = CGPoint(x: -t.y, y: t.x)
            strands.move(to: CGPoint(x: here.x - n.x * 3 - t.x * 1.6, y: here.y - n.y * 3 - t.y * 1.6))
            strands.addLine(to: CGPoint(x: here.x + n.x * 3 + t.x * 1.6, y: here.y + n.y * 3 + t.y * 1.6))
            // Step by arc length, so the strands stay evenly spaced where the rope curves.
            u += 0.01 * spacing / len
            here = point(u)
        }
        return strands
    }

    private func drawBomb(at c: CGPoint, in ctx: GraphicsContext, urgent: CGFloat) {
        let r: CGFloat = 8.5
        // It glows hotter as the spark closes in.
        if urgent > 0.6 {
            let heat = (urgent - 0.6) / 0.4 * CGFloat(0.75 + 0.25 * sin(time * 12))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 15, y: c.y - 15, width: 30, height: 30)),
                     with: .radialGradient(Gradient(colors: [IslandPalette.danger.opacity(0.6 * heat), .clear]),
                                           center: c, startRadius: 4, endRadius: 15))
        }
        var cap = ctx
        cap.translateBy(x: c.x, y: c.y)
        cap.rotate(by: .degrees(-45))
        cap.fill(Path(roundedRect: CGRect(x: -3.2, y: -r - 3, width: 6.4, height: 5), cornerRadius: 1.2),
                 with: .color(Color(.sRGB, red: 0.55, green: 0.55, blue: 0.62)))
        let body = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(body, with: .radialGradient(Gradient(colors: [Color(.sRGB, red: 0.36, green: 0.36, blue: 0.43), Color(.sRGB, red: 0.1, green: 0.1, blue: 0.13)]),
                                             center: CGPoint(x: c.x - 3, y: c.y - 3), startRadius: 0, endRadius: r * 1.3))
        ctx.stroke(body, with: .color(.white.opacity(0.22)), lineWidth: 0.8)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5.5, width: 4, height: 2.6)), with: .color(.white.opacity(0.45)))
    }

    private func drawSpark(at p: CGPoint, in ctx: GraphicsContext) {
        let flicker = CGFloat(0.8 + 0.12 * sin(time * 31) + 0.08 * sin(time * 53 + 1.7))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28)),
                 with: .radialGradient(Gradient(colors: [Self.spark.opacity(0.9 * flicker), Self.spark.opacity(0)]),
                                       center: p, startRadius: 1, endRadius: 13 * flicker))

        // Embers: drift up and back along the burnt fuse, arc down, fade. Deterministic in time — no state.
        for i in 0..<9 {
            let seed = Double(i) * 0.618
            let life = 0.55 + 0.35 * (seed.truncatingRemainder(dividingBy: 1))
            let phase = CGFloat((time / life + Double(i) * 0.137).truncatingRemainder(dividingBy: 1))
            let spread = CGFloat(sin(Double(i) * 12.9898) * 0.5 + 0.5)
            let pos = CGPoint(x: p.x - (4 + 10 * spread) * phase + CGFloat(sin(Double(i) * 3.1)) * 2,
                              y: p.y - 13 * phase * (0.6 + spread) + 11 * phase * phase)
            let r = 1.3 * (1 - phase) + 0.3
            let color = phase < 0.4 ? Self.sparkCore : (phase < 0.75 ? Self.spark : IslandPalette.danger)
            ctx.fill(Path(ellipseIn: CGRect(x: pos.x - r, y: pos.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color.opacity(Double(1 - phase))))
        }

        // A spinning, jittering star of sparks.
        var rays = Path()
        for i in 0..<7 {
            let angle = Double(i) * 2 * .pi / 7 + time * 7
            let length = 3.5 + 5 * CGFloat(0.5 + 0.5 * sin(time * 37 + Double(i) * 12.9))
            rays.move(to: CGPoint(x: p.x + CGFloat(cos(angle)) * 2, y: p.y + CGFloat(sin(angle)) * 2))
            rays.addLine(to: CGPoint(x: p.x + CGFloat(cos(angle)) * length, y: p.y + CGFloat(sin(angle)) * length))
        }
        ctx.stroke(rays, with: .color(Self.sparkCore), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
    }
}
