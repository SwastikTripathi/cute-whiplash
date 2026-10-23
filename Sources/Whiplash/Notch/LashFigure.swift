import SwiftUI

/// Lash, a fluffy gentleman Samoyed. A pure function of its inputs — expression, gaze, blink and (only for expressions with
/// motion, and only while `animated`) the time — so it can be rendered headlessly and costs nothing while idle.
///
/// The figure's frame is Lash's 100×100 unit box; steam, stars, Zzz and glow spill 30% past it on every side.
struct LashFigure: View, Animatable {
    /// Height of the eyes as a fraction of the figure's frame, for gaze maths.
    static let eyeLine: CGFloat = 0.53
    /// How far the drawing may spill past the frame, as a fraction of its side.
    static let overflow: CGFloat = 0.3

    var expression: LashExpression
    /// Pupil deflection, length ≤ 1, y down. (0, 0) looks straight ahead.
    var gaze: CGVector = .zero
    /// 0 = eyes as the expression wants them, 1 = shut mid-blink.
    var blink: CGFloat = 0
    /// Run the expression's time-based motion. False draws one still frame and schedules nothing.
    var animated = false
    /// Shortest time between redraws while animating.
    var frameInterval: TimeInterval = 1.0 / 60

    @Environment(\.islandFrozenTime) private var frozenTime

    var animatableData: CGFloat {
        get { blink }
        set { blink = newValue }
    }

    var body: some View {
        let live = animated && expression.hasMotion && frozenTime == nil
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * (1 + 2 * Self.overflow)
            TimelineView(.animation(minimumInterval: frameInterval, paused: !live)) { timeline in
                let time = frozenTime ?? (live ? timeline.date.timeIntervalSinceReferenceDate : 0)
                Canvas { context, size in
                    LashPainter(face: LashFace(expression), gaze: gaze, blink: blink, time: time)
                        .draw(in: context, size: size)
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        // The drawing spills past the frame; it must never swallow clicks meant for neighbours.
        // Hosts that want pokes give the figure a content shape (see `LiveLash`).
        .allowsHitTesting(false)
        .accessibilityLabel("Lash")
    }
}

private struct IslandFrozenTimeKey: EnvironmentKey {
    static let defaultValue: TimeInterval? = nil
}

extension EnvironmentValues {
    /// Demos freeze every island animation at this time so renders are reproducible. nil = live.
    var islandFrozenTime: TimeInterval? {
        get { self[IslandFrozenTimeKey.self] }
        set { self[IslandFrozenTimeKey.self] = newValue }
    }
}

/// Draws Lash into a Canvas. Works in Lash's unit box: (0, 0)...(100, 100), y down, head centred at (50, 57).
struct LashPainter {
    let face: LashFace
    let gaze: CGVector
    let blink: CGFloat
    let time: TimeInterval

    private static let ink = Color(.sRGB, red: 0.05, green: 0.05, blue: 0.07)
    private static let eyeWhite = Color.white
    private static let eyeShade = Color(.sRGB, red: 0.84, green: 0.85, blue: 0.92)
    private static let mouthInk = Color(.sRGB, red: 0.29, green: 0.04, blue: 0.10)
    private static let tongue = Color(.sRGB, red: 1.0, green: 0.44, blue: 0.58)
    private static let blush = Color(.sRGB, red: 1.0, green: 0.42, blue: 0.62)
    private static let noseInk = Color(.sRGB, red: 0.13, green: 0.08, blue: 0.08)
    /// Warm brown puppy eyes.
    private static let iris = Color(.sRGB, red: 0.10, green: 0.07, blue: 0.06)
    private static let browInk = Color(.sRGB, red: 0.45, green: 0.40, blue: 0.40)
    /// Closed, happy and laughing eyes are drawn as dark strokes on the white fur.
    private static let closedEye = Color(.sRGB, red: 0.16, green: 0.13, blue: 0.13)
    private static let gold = Color(.sRGB, red: 0.95, green: 0.77, blue: 0.33)
    private static let goldDark = Color(.sRGB, red: 0.62, green: 0.45, blue: 0.14)
    private static let bowTie = Color(.sRGB, red: 0.62, green: 0.08, blue: 0.17)
    private static let bowTieDark = Color(.sRGB, red: 0.38, green: 0.03, blue: 0.09)
    private static let hat = Color(.sRGB, red: 0.13, green: 0.13, blue: 0.16)
    private static let hatRim = Color(.sRGB, red: 0.55, green: 0.55, blue: 0.62)

    private static let leftEye = CGPoint(x: 37, y: 53)
    private static let rightEye = CGPoint(x: 63, y: 53)
    private static let eyeRadii = CGSize(width: 10.5, height: 12)

    /// `size` is the whole canvas, which is the unit box plus `LashFigure.overflow` on every side.
    func draw(in context: GraphicsContext, size: CGSize) {
        var ctx = context
        let scale = min(size.width, size.height) / (100 * (1 + 2 * LashFigure.overflow))
        ctx.translateBy(x: size.width / 2 - 50 * scale, y: size.height / 2 - 50 * scale)
        ctx.scaleBy(x: scale, y: scale)
        // Strokes never get thinner than ~0.6 pt, so tiny Lash (in the closed pill) stays crisp.
        let hairline = 0.6 / scale

        if let glow = face.glow { drawGlow(glow, in: ctx) }

        var head = ctx
        var tilt = face.tilt, shift = CGSize.zero, breath: CGFloat = 1
        switch face.motion {
        case .still: break
        case .shake: shift = CGSize(width: sin(time * 47) * 1.4 + sin(time * 29) * 0.8, height: cos(time * 41) * 0.6)
        case .cackle:
            shift.height = -abs(sin(time * 9)) * 3.5
            tilt += sin(time * 9) * 5
        case .wobble: tilt += sin(time * 5) * 8
        case .breathe: breath = 1 + sin(time * 1.7) * 0.02
        }
        head.translateBy(x: 50 + shift.width, y: 80 + shift.height)
        head.rotate(by: .degrees(tilt))
        head.scaleBy(x: 1 / breath, y: breath)
        head.translateBy(x: -50, y: -80)

        if face.steam { drawSteam(in: head) }
        drawRuff(in: head, hairline: hairline)
        drawEars(in: head, hairline: hairline)
        drawHead(in: head, hairline: hairline)
        if face.cheeks > 0 { drawCheeks(in: head) }
        drawEyes(in: head, hairline: hairline)
        drawMonocle(in: head, hairline: hairline)
        if let brows = face.brows { drawBrows(brows, in: head) }
        drawMouth(in: head, hairline: hairline)
        drawNose(in: head)
        drawBowTie(in: head, hairline: hairline)
        drawTopHat(in: head, hairline: hairline)
        if face.angerMark { drawAngerMark(in: head) }
        if face.stars { drawStars(in: head) }
        if face.zzz { drawZzz(in: ctx) }
    }

    // MARK: - Head

    private func drawGlow(_ color: Color, in ctx: GraphicsContext) {
        let pulse = 0.8 + 0.2 * sin(time * 6)
        let center = CGPoint(x: 50, y: 58)
        let gradient = Gradient(stops: [
            .init(color: color.opacity(0.6 * pulse), location: 0),
            .init(color: color.opacity(0.22 * pulse), location: 0.6),
            .init(color: color.opacity(0), location: 1),
        ])
        ctx.fill(Path(ellipseIn: CGRect(x: center.x - 64, y: center.y - 64, width: 128, height: 128)),
                 with: .radialGradient(gradient, center: center, startRadius: 24, endRadius: 64))
    }

    /// A soft, scalloped outline round an ellipse: `bumps` tufts of fur, each bulging `depth` beyond it.
    private static func fluff(center: CGPoint, radii: CGSize, bumps: Int, depth: CGFloat, phase: Double = 0) -> Path {
        func point(_ angle: Double, _ out: CGFloat) -> CGPoint {
            CGPoint(x: center.x + (radii.width + out) * CGFloat(cos(angle)), y: center.y + (radii.height + out) * CGFloat(sin(angle)))
        }
        var p = Path()
        let step = 2 * Double.pi / Double(bumps)
        p.move(to: point(phase, 0))
        for i in 0..<bumps {
            let a0 = phase + Double(i) * step
            p.addQuadCurve(to: point(a0 + step, 0), control: point(a0 + step / 2, depth * 2))
        }
        p.closeSubpath()
        return p
    }

    /// The face: round, with soft tufts all round.
    private static let headPath = fluff(center: CGPoint(x: 50, y: 59), radii: CGSize(width: 34, height: 32), bumps: 24, depth: 0.8)
    /// The big fluffy ruff behind it, fuller at the cheeks and chin: the Samoyed's lion mane.
    private static let ruffPath = fluff(center: CGPoint(x: 50, y: 66), radii: CGSize(width: 43, height: 34), bumps: 16,
                                        depth: 3.6, phase: 0.2)
    /// The snout: a soft rounded muzzle round the nose and mouth.
    private static let muzzlePath = Path(ellipseIn: CGRect(x: 34, y: 62, width: 32, height: 27))

    private func drawRuff(in ctx: GraphicsContext, hairline: CGFloat) {
        let skin = face.skin
        ctx.fill(Self.ruffPath, with: .linearGradient(Gradient(colors: [skin.ruff, skin.bottom]),
                                                      startPoint: CGPoint(x: 50, y: 30), endPoint: CGPoint(x: 50, y: 104)))
        ctx.stroke(Self.ruffPath, with: .color(skin.rim.opacity(0.55)), lineWidth: max(1.2, hairline))
    }

    private func drawHead(in ctx: GraphicsContext, hairline: CGFloat) {
        let skin = face.skin
        ctx.fill(Self.headPath, with: .linearGradient(Gradient(colors: [skin.top, skin.bottom]),
                                                      startPoint: CGPoint(x: 50, y: 27), endPoint: CGPoint(x: 50, y: 92)))
        ctx.stroke(Self.headPath, with: .color(skin.rim.opacity(0.5)), lineWidth: max(1.1, hairline))
        // The snout: a touch brighter, with a faint shadow along its lower edge.
        ctx.fill(Self.muzzlePath, with: .color(skin.top))
        var underside = Path()
        underside.addArc(center: CGPoint(x: 50, y: 75.5), radius: 16, startAngle: .degrees(25), endAngle: .degrees(155), clockwise: false)
        ctx.stroke(underside, with: .color(skin.rim.opacity(0.45)), style: StrokeStyle(lineWidth: max(1, hairline), lineCap: .round))
    }

    /// Pointy upright ears, fluffy white with pink insides (drawn behind the face).
    private func drawEars(in ctx: GraphicsContext, hairline: CGFloat) {
        var ear = Path()
        ear.move(to: CGPoint(x: 17, y: 42))
        ear.addQuadCurve(to: CGPoint(x: 21.5, y: 6), control: CGPoint(x: 9, y: 20))
        ear.addQuadCurve(to: CGPoint(x: 43, y: 29), control: CGPoint(x: 31, y: 11))
        ear.closeSubpath()
        var inner = Path()
        inner.move(to: CGPoint(x: 22, y: 36))
        inner.addQuadCurve(to: CGPoint(x: 23.5, y: 13), control: CGPoint(x: 17, y: 22))
        inner.addQuadCurve(to: CGPoint(x: 37, y: 29), control: CGPoint(x: 30, y: 17))
        inner.closeSubpath()
        let skin = face.skin
        for mirror in [false, true] {
            let t = mirror ? Self.mirror : .identity
            ctx.fill(ear.applying(t), with: .color(skin.top))
            ctx.stroke(ear.applying(t), with: .color(skin.rim.opacity(0.7)), lineWidth: max(1.2, hairline))
            ctx.fill(inner.applying(t), with: .color(skin.innerEar))
        }
    }

    /// A gold monocle over his right eye, its chain looping down to the ruff.
    private func drawMonocle(in ctx: GraphicsContext, hairline: CGFloat) {
        let c = Self.rightEye
        let r: CGFloat = 13.6
        let ring = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(ring, with: .color(.white.opacity(0.1)))
        var chain = Path()
        chain.move(to: CGPoint(x: c.x + r * 0.72, y: c.y + r * 0.7))
        chain.addQuadCurve(to: CGPoint(x: 84, y: 92), control: CGPoint(x: 86, y: 70))
        ctx.stroke(chain, with: .color(Self.goldDark), style: StrokeStyle(lineWidth: max(1.2, hairline), lineCap: .round, dash: [2, 1.6]))
        ctx.stroke(ring, with: .color(Self.goldDark), lineWidth: 3.2)
        ctx.stroke(ring, with: .color(Self.gold), lineWidth: 2)
        // A glint across the glass.
        var glint = Path()
        glint.addArc(center: c, radius: r - 3.2, startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
        ctx.stroke(glint, with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    /// A burgundy bow tie under the chin.
    private func drawBowTie(in ctx: GraphicsContext, hairline: CGFloat) {
        let knot = CGPoint(x: 50, y: 95)
        for side: CGFloat in [-1, 1] {
            var wing = Path()
            wing.move(to: CGPoint(x: knot.x + side * 2, y: knot.y))
            wing.addQuadCurve(to: CGPoint(x: knot.x + side * 13, y: knot.y - 6.5), control: CGPoint(x: knot.x + side * 6, y: knot.y - 5))
            wing.addQuadCurve(to: CGPoint(x: knot.x + side * 13, y: knot.y + 6.5), control: CGPoint(x: knot.x + side * 15.5, y: knot.y))
            wing.addQuadCurve(to: CGPoint(x: knot.x + side * 2, y: knot.y), control: CGPoint(x: knot.x + side * 6, y: knot.y + 5))
            wing.closeSubpath()
            ctx.fill(wing, with: .linearGradient(Gradient(colors: [Self.bowTie, Self.bowTieDark]),
                                                 startPoint: CGPoint(x: knot.x, y: knot.y - 6), endPoint: CGPoint(x: knot.x, y: knot.y + 6)))
            ctx.stroke(wing, with: .color(Self.bowTieDark), lineWidth: max(0.9, hairline))
        }
        let middle = Path(roundedRect: CGRect(x: knot.x - 3.2, y: knot.y - 4, width: 6.4, height: 8), cornerRadius: 2)
        ctx.fill(middle, with: .color(Self.bowTie))
        ctx.stroke(middle, with: .color(Self.bowTieDark), lineWidth: max(0.9, hairline))
    }

    /// A dapper little top hat, tipped to one side between the ears.
    private func drawTopHat(in ctx: GraphicsContext, hairline: CGFloat) {
        var hat = ctx
        hat.translateBy(x: 53, y: 25)
        hat.rotate(by: .degrees(9))
        let brim = Path(roundedRect: CGRect(x: -16, y: -3, width: 32, height: 5.5), cornerRadius: 2.75)
        let crown = Path(roundedRect: CGRect(x: -10.5, y: -21, width: 21, height: 19.5), cornerRadius: 2.5)
        let band = Path(CGRect(x: -10.5, y: -7, width: 21, height: 4))
        hat.fill(crown, with: .linearGradient(Gradient(colors: [Self.hat.opacity(1), Color(.sRGB, red: 0.24, green: 0.24, blue: 0.29)]),
                                              startPoint: CGPoint(x: -10, y: -14), endPoint: CGPoint(x: 10, y: -14)))
        hat.fill(band, with: .color(Self.bowTie))
        hat.stroke(crown, with: .color(Self.hatRim.opacity(0.9)), lineWidth: max(1, hairline))
        hat.fill(brim, with: .color(Self.hat))
        hat.stroke(brim, with: .color(Self.hatRim.opacity(0.9)), lineWidth: max(1, hairline))
        // A sheen down the crown.
        hat.fill(Path(roundedRect: CGRect(x: -7.5, y: -19, width: 2.4, height: 11), cornerRadius: 1.2), with: .color(.white.opacity(0.28)))
    }

    /// A black button nose with a shine, sitting on top of the mouth.
    private func drawNose(in ctx: GraphicsContext) {
        var nose = Path()
        nose.move(to: CGPoint(x: 42.5, y: 67.5))
        nose.addQuadCurve(to: CGPoint(x: 57.5, y: 67.5), control: CGPoint(x: 50, y: 64))
        nose.addQuadCurve(to: CGPoint(x: 50, y: 76), control: CGPoint(x: 58, y: 72.5))
        nose.addQuadCurve(to: CGPoint(x: 42.5, y: 67.5), control: CGPoint(x: 42, y: 72.5))
        nose.closeSubpath()
        ctx.fill(nose, with: .color(Self.noseInk))
        ctx.fill(Path(ellipseIn: CGRect(x: 45, y: 66.5, width: 5, height: 2.6)), with: .color(.white.opacity(0.75)))
    }

    private func drawCheeks(in ctx: GraphicsContext) {
        for center in [CGPoint(x: 22.5, y: 71), CGPoint(x: 77.5, y: 71)] {
            let gradient = Gradient(colors: [Self.blush.opacity(0.85 * face.cheeks), Self.blush.opacity(0)])
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 6, width: 18, height: 12)),
                     with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: 8.5))
        }
    }

    // MARK: - Eyes

    private func drawEyes(in ctx: GraphicsContext, hairline: CGFloat) {
        switch face.eyes {
        case .open(let lids):
            drawOpenEye(at: Self.leftEye, scale: lids.leftScale, lids: lids, isLeft: true, in: ctx, hairline: hairline)
            drawOpenEye(at: Self.rightEye, scale: lids.rightScale, lids: lids, isLeft: false, in: ctx, hairline: hairline)
        case .squeezed:
            for (c, dir) in [(Self.leftEye, CGFloat(1)), (Self.rightEye, CGFloat(-1))] {
                var p = Path()
                p.move(to: CGPoint(x: c.x - 7 * dir, y: c.y - 8))
                p.addLine(to: CGPoint(x: c.x + 6 * dir, y: c.y))
                p.addLine(to: CGPoint(x: c.x - 7 * dir, y: c.y + 8))
                ctx.stroke(p, with: .color(Self.closedEye), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        case .closed:
            for c in [Self.leftEye, Self.rightEye] {
                var p = Path()
                p.move(to: CGPoint(x: c.x - 8.5, y: c.y + 1))
                p.addQuadCurve(to: CGPoint(x: c.x + 8.5, y: c.y + 1), control: CGPoint(x: c.x, y: c.y + 8))
                ctx.stroke(p, with: .color(Self.closedEye), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
            }
        case .joyful:
            for c in [Self.leftEye, Self.rightEye] {
                var p = Path()
                p.move(to: CGPoint(x: c.x - 8.5, y: c.y + 4))
                p.addQuadCurve(to: CGPoint(x: c.x + 8.5, y: c.y + 4), control: CGPoint(x: c.x, y: c.y - 7))
                ctx.stroke(p, with: .color(Self.closedEye), style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
            }
        case .spiral:
            for (c, spin) in [(Self.leftEye, 1.0), (Self.rightEye, -1.0)] {
                let eye = Path(ellipseIn: CGRect(x: c.x - Self.eyeRadii.width, y: c.y - Self.eyeRadii.height,
                                                 width: Self.eyeRadii.width * 2, height: Self.eyeRadii.height * 2))
                ctx.fill(eye, with: .color(Self.eyeWhite))
                var spiral = Path()
                let turns = 2.6, steps = 80
                for i in 0...steps {
                    let f = Double(i) / Double(steps)
                    let angle = f * turns * 2 * .pi * spin + time * 7 * spin
                    let r = 1 + f * (Self.eyeRadii.width - 3)
                    let point = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r * 1.1)
                    if i == 0 { spiral.move(to: point) } else { spiral.addLine(to: point) }
                }
                ctx.stroke(spiral, with: .color(Self.ink), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
                ctx.stroke(eye, with: .color(Self.ink), lineWidth: max(1.4, hairline))
            }
        }
    }

    private func drawOpenEye(at c: CGPoint, scale: CGFloat, lids: LashFace.Lids, isLeft: Bool,
                             in ctx: GraphicsContext, hairline: CGFloat) {
        let rx = Self.eyeRadii.width * scale, ry = Self.eyeRadii.height * scale
        let rect = CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)
        let eye = Path(ellipseIn: rect)
        ctx.fill(eye, with: .linearGradient(Gradient(colors: [Self.eyeWhite, Self.eyeShade]),
                                            startPoint: CGPoint(x: c.x, y: rect.minY + ry * 0.8), endPoint: CGPoint(x: c.x, y: rect.maxY)))
        var inside = ctx
        inside.clip(to: eye)

        // Pupil, deflected toward the gaze but always fully inside the eye.
        let pr = 6.6 * lids.pupil * scale
        let pupil = CGPoint(x: c.x + gaze.dx * (rx - pr - 1.4), y: c.y + gaze.dy * (ry - pr - 1.4))
        inside.fill(Path(ellipseIn: CGRect(x: pupil.x - pr, y: pupil.y - pr, width: 2 * pr, height: 2 * pr)), with: .color(Self.iris))
        let glint = max(1.2, pr * 0.4)
        inside.fill(Path(ellipseIn: CGRect(x: pupil.x - pr * 0.42 - glint, y: pupil.y - pr * 0.45 - glint, width: 2 * glint, height: 2 * glint)),
                    with: .color(.white))
        inside.fill(Path(ellipseIn: CGRect(x: pupil.x + pr * 0.35, y: pupil.y + pr * 0.3, width: glint * 0.9, height: glint * 0.9)),
                    with: .color(.white.opacity(0.8)))

        // Upper lid: lowered by (1 - open), tilted by slant, closed completely by a blink.
        let open = lids.open * (1 - blink)
        if open < 0.995 || lids.slant != 0 {
            let inward: CGFloat = isLeft ? 1 : -1
            let mid = rect.minY + (1 - open) * 2 * ry
            let drop = lids.slant * ry * (1 - blink)
            let x0 = rect.minX - 2, x1 = rect.maxX + 2
            let y0 = mid + drop * ((x0 - c.x) / rx) * inward
            let y1 = mid + drop * ((x1 - c.x) / rx) * inward
            var lid = Path()
            lid.move(to: CGPoint(x: x0, y: rect.minY - 4))
            lid.addLine(to: CGPoint(x: x1, y: rect.minY - 4))
            lid.addLine(to: CGPoint(x: x1, y: y1))
            lid.addLine(to: CGPoint(x: x0, y: y0))
            lid.closeSubpath()
            inside.fill(lid, with: .color(face.skin.lid))
            var edge = Path()
            edge.move(to: CGPoint(x: x0, y: y0))
            edge.addLine(to: CGPoint(x: x1, y: y1))
            inside.stroke(edge, with: .color(Self.ink), lineWidth: 2.2)
        }
        // Lower lid: a gentle upward curve.
        if lids.lower > 0 {
            let y = rect.maxY - lids.lower * 2 * ry
            var lid = Path()
            lid.move(to: CGPoint(x: rect.minX - 2, y: y + 1.5))
            lid.addQuadCurve(to: CGPoint(x: rect.maxX + 2, y: y + 1.5), control: CGPoint(x: c.x, y: y - 2.5))
            lid.addLine(to: CGPoint(x: rect.maxX + 2, y: rect.maxY + 4))
            lid.addLine(to: CGPoint(x: rect.minX - 2, y: rect.maxY + 4))
            lid.closeSubpath()
            inside.fill(lid, with: .color(face.skin.lid))
            inside.stroke(lid, with: .color(Self.ink.opacity(0.7)), lineWidth: 1.4)
        }
        ctx.stroke(eye, with: .color(Self.ink), lineWidth: max(2, hairline))
    }

    private func drawBrows(_ brows: (left: LashFace.Brow, right: LashFace.Brow), in ctx: GraphicsContext) {
        let style = StrokeStyle(lineWidth: 3.2, lineCap: .round)
        for (brow, outerX, innerX) in [(brows.left, CGFloat(26), CGFloat(46)), (brows.right, CGFloat(74), CGFloat(54))] {
            var p = Path()
            p.move(to: CGPoint(x: outerX, y: brow.outer))
            p.addQuadCurve(to: CGPoint(x: innerX, y: brow.inner),
                           control: CGPoint(x: (outerX + innerX) / 2, y: (brow.outer + brow.inner) / 2 - brow.arch * 2))
            ctx.stroke(p, with: .color(Self.browInk), style: style)
        }
    }

    // MARK: - Mouth

    private func drawMouth(in ctx: GraphicsContext, hairline: CGFloat) {
        let line = StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
        switch face.mouth {
        case .smile:
            var p = Path()
            p.move(to: CGPoint(x: 40.5, y: 74))
            p.addQuadCurve(to: CGPoint(x: 59.5, y: 74), control: CGPoint(x: 50, y: 76))
            p.addQuadCurve(to: CGPoint(x: 50, y: 87), control: CGPoint(x: 59, y: 86.5))
            p.addQuadCurve(to: CGPoint(x: 40.5, y: 74), control: CGPoint(x: 41, y: 86.5))
            p.closeSubpath()
            drawOpenMouth(p, tongue: CGRect(x: 44, y: 81, width: 12, height: 7.5), teethDepth: 0, in: ctx, hairline: hairline)
        case .laugh:
            var p = Path()
            p.move(to: CGPoint(x: 33.5, y: 71))
            p.addQuadCurve(to: CGPoint(x: 66.5, y: 71), control: CGPoint(x: 50, y: 74.5))
            p.addQuadCurve(to: CGPoint(x: 50, y: 92.5), control: CGPoint(x: 65, y: 92))
            p.addQuadCurve(to: CGPoint(x: 33.5, y: 71), control: CGPoint(x: 35, y: 92))
            p.closeSubpath()
            drawOpenMouth(p, tongue: CGRect(x: 41, y: 84.5, width: 18, height: 10), teethDepth: 4.5, in: ctx, hairline: hairline)
        case .oh:
            let p = Path(ellipseIn: CGRect(x: 47.5, y: 74.5, width: 7.5, height: 9))
            ctx.fill(p, with: .color(Self.mouthInk))
            ctx.stroke(p, with: .color(Self.ink), lineWidth: max(1.3, hairline))
        case .snore:
            let p = Path(ellipseIn: CGRect(x: 46.5, y: 77.5, width: 7, height: 5))
            ctx.fill(p, with: .color(Self.mouthInk))
            ctx.stroke(p, with: .color(Self.ink), lineWidth: max(1.3, hairline))
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: 41, y: 80.5))
            p.addQuadCurve(to: CGPoint(x: 59, y: 80.5), control: CGPoint(x: 50, y: 79))
            ctx.stroke(p, with: .color(Self.ink), style: line)
        case .wavy:
            var p = Path()
            p.move(to: CGPoint(x: 41, y: 80))
            p.addCurve(to: CGPoint(x: 51, y: 80), control1: CGPoint(x: 44.5, y: 76.5), control2: CGPoint(x: 47.5, y: 83.5))
            p.addCurve(to: CGPoint(x: 61, y: 78.5), control1: CGPoint(x: 54.5, y: 76.5), control2: CGPoint(x: 57.5, y: 81.5))
            ctx.stroke(p, with: .color(Self.ink), style: line)
        case .wobble:
            var p = Path()
            p.move(to: CGPoint(x: 39, y: 80))
            for (i, x) in stride(from: 43.5, through: 61, by: 4.5).enumerated() {
                p.addQuadCurve(to: CGPoint(x: x, y: 80), control: CGPoint(x: x - 2.25, y: i % 2 == 0 ? 75.5 : 84.5))
            }
            ctx.stroke(p, with: .color(Self.ink), style: line)
        case .smirk:
            var p = Path()
            p.move(to: CGPoint(x: 40, y: 79))
            p.addQuadCurve(to: CGPoint(x: 61, y: 73.5), control: CGPoint(x: 53, y: 83))
            ctx.stroke(p, with: .color(Self.ink), style: line)
            var dimple = Path()
            dimple.move(to: CGPoint(x: 59.5, y: 71.5))
            dimple.addQuadCurve(to: CGPoint(x: 62.5, y: 75.5), control: CGPoint(x: 63.5, y: 72.5))
            ctx.stroke(dimple, with: .color(Self.ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        case .gritted:
            let box = CGRect(x: 37.5, y: 73, width: 25, height: 11)
            let p = Path(roundedRect: box, cornerRadius: 4)
            ctx.fill(p, with: .color(.white))
            var teeth = Path()
            for x in stride(from: box.minX + box.width / 4, to: box.maxX - 1, by: box.width / 4) {
                teeth.move(to: CGPoint(x: x, y: box.minY))
                teeth.addLine(to: CGPoint(x: x, y: box.maxY))
            }
            teeth.move(to: CGPoint(x: box.minX, y: box.midY))
            teeth.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            var inside = ctx
            inside.clip(to: p)
            inside.stroke(teeth, with: .color(Self.ink.opacity(0.75)), lineWidth: 1.3)
            ctx.stroke(p, with: .color(Self.ink), lineWidth: 2)
        }
    }

    private func drawOpenMouth(_ mouth: Path, tongue: CGRect, teethDepth: CGFloat, in ctx: GraphicsContext, hairline: CGFloat) {
        ctx.fill(mouth, with: .color(Self.mouthInk))
        var inside = ctx
        inside.clip(to: mouth)
        inside.fill(Path(ellipseIn: tongue), with: .color(Self.tongue))
        if teethDepth > 0 {
            let top = mouth.boundingRect
            inside.fill(Path(CGRect(x: top.minX, y: top.minY - 2, width: top.width, height: teethDepth + 2.5)), with: .color(.white))
        }
        ctx.stroke(mouth, with: .color(Self.ink), style: StrokeStyle(lineWidth: max(1.6, hairline), lineJoin: .round))
    }

    // MARK: - Extras

    private func drawSteam(in ctx: GraphicsContext) {
        for (origin, dir) in [(CGPoint(x: 13, y: 38), CGFloat(-1)), (CGPoint(x: 87, y: 38), CGFloat(1))] {
            for i in 0..<3 {
                let phase = (time * 1.25 + Double(i) / 3 + (dir > 0 ? 0.17 : 0)).truncatingRemainder(dividingBy: 1)
                let p = CGFloat(phase)
                let center = CGPoint(x: origin.x + dir * (3 + 12 * p), y: origin.y - 30 * p)
                let r = 3 + 6 * p
                let alpha = 0.85 * sin(Double.pi * min(1, Double(p) * 1.4 + 0.12))
                var puff = Path()
                puff.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                puff.addEllipse(in: CGRect(x: center.x - r * 1.5, y: center.y - r * 0.2, width: 1.2 * r, height: 1.2 * r))
                puff.addEllipse(in: CGRect(x: center.x + r * 0.3, y: center.y - r * 0.1, width: 1.2 * r, height: 1.2 * r))
                ctx.fill(puff, with: .color(.white.opacity(max(0, alpha))))
            }
        }
    }

    /// The manga "💢" vein, pulsing.
    private func drawAngerMark(in ctx: GraphicsContext) {
        var mark = ctx
        let beat = 1 + 0.12 * sin(time * 14)
        mark.translateBy(x: 85, y: 22)
        mark.scaleBy(x: beat, y: beat)
        var p = Path()
        for quarter in 0..<4 {
            var arc = Path()
            arc.move(to: CGPoint(x: 1.6, y: 6.5))
            arc.addQuadCurve(to: CGPoint(x: 6.5, y: 1.6), control: CGPoint(x: 1.6, y: 1.6))
            p.addPath(arc.applying(CGAffineTransform(rotationAngle: CGFloat(quarter) * .pi / 2)))
        }
        mark.stroke(p, with: .color(Color(.sRGB, red: 1, green: 0.16, blue: 0.2)), style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
    }

    private func drawStars(in ctx: GraphicsContext) {
        for i in 0..<3 {
            let angle = time * 3.2 + Double(i) * 2 * .pi / 3
            let center = CGPoint(x: 50 + cos(angle) * 36, y: 17 + sin(angle) * 7)
            let r: CGFloat = 5.5 + 1.2 * CGFloat(sin(angle))
            var star = Path()
            for k in 0..<10 {
                let a = Double(k) * .pi / 5 - .pi / 2
                let radius = k % 2 == 0 ? r : r * 0.45
                let point = CGPoint(x: center.x + CGFloat(cos(a)) * radius, y: center.y + CGFloat(sin(a)) * radius)
                if k == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath()
            ctx.fill(star, with: .color(IslandPalette.gold))
        }
    }

    /// Three Zs drifting up from above the right ear (the sleepy head leans the other way to make room), growing as
    /// they go but staying inside Lash's own column, clear of the dashboard's text. Drawn as paths, not `Text`: no
    /// text layout every frame, and crisp even on the tiny closed-pill Lash.
    private func drawZzz(in ctx: GraphicsContext) {
        for i in 0..<3 {
            let phase = (time * 0.45 + (Double(i) + 0.5) / 3).truncatingRemainder(dividingBy: 1)
            let p = CGFloat(phase)
            let center = CGPoint(x: 84 + 8 * p + CGFloat(sin(phase * 2 * .pi)) * 2.5, y: 34 - 38 * p)
            let half = 2.6 + 3.2 * p
            var z = Path()
            z.move(to: CGPoint(x: center.x - half, y: center.y - half))
            z.addLine(to: CGPoint(x: center.x + half, y: center.y - half))
            z.addLine(to: CGPoint(x: center.x - half, y: center.y + half))
            z.addLine(to: CGPoint(x: center.x + half, y: center.y + half))
            let alpha = sin(Double.pi * phase)
            ctx.stroke(z, with: .color(Color(.sRGB, red: 0.72, green: 0.80, blue: 1, opacity: alpha)),
                       style: StrokeStyle(lineWidth: 1.2 + half * 0.36, lineCap: .round, lineJoin: .round))
        }
    }

    /// Reflects a path drawn for the left side onto the right side of the unit box.
    private static let mirror = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
}
