import SwiftUI

/// The whole island panel: the black pill hugging the notch, its per-presentation content, and Lash.
/// Driven only by `IslandModel` (app state), `IslandUIState` (geometry + hover) and `LashState` (Lash's behaviour);
/// user actions go straight to `model.onXxx`. Fills exactly `ui.layout.panelSize`.
struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var ui: IslandUIState
    let lash: LashState

    /// The island's shape spring, iPhone-style.
    static let shapeSpring = Animation.spring(response: 0.38, dampingFraction: 0.72)
    /// Content fades and scales in just after the shape has started to grow; it leaves quickly.
    static let contentTransition = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top))
            .animation(.spring(response: 0.34, dampingFraction: 0.8).delay(0.1)),
        removal: .opacity.animation(.easeOut(duration: 0.09)))

    var body: some View {
        let layout = ui.layout
        let presentation = IslandPresentation.resolve(phase: model.phase, hovering: ui.isHovering, hasQuip: model.quip != nil)
        let island = layout.islandRect(for: presentation)
        let radius = layout.bottomRadius(for: presentation)
        let lashRect = layout.lashRect(for: presentation)

        ZStack(alignment: .topLeading) {
            if let glow = glowColor(for: presentation) {
                IslandGlow(color: glow, rect: island, bottomRadius: radius, heartbeat: isWarning)
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
            // No whip handle here: the overlay draws the whip, handle and Lash's paw included, coming out from under the
            // pill (see `IslandLayout.whipGrip`), so there is only ever one handle and the rope never leaves it.
            IslandBody(rect: island, bottomRadius: radius, pulses: presentation == .whipping,
                       hard: presentation == .whipping && model.laughingHard)
            // Behind the content and Lash: hearts emerge from behind Lash's head.
            HeartsLayer(lash: lash, lashRect: lashRect)

            // Content is laid out at its final size and revealed by the island as it grows (clipped to the
            // animating shape), like the iPhone's Dynamic Island.
            Color.clear
                .frame(width: island.width + 2 * IslandLayout.topFlare, height: island.height)
                .overlay(alignment: .top) {
                    Group {
                        if presentation.isCompact {
                            CompactContent(model: model, presentation: presentation, layout: layout)
                        } else if presentation == .expanded {
                            ExpandedContent(model: model, ui: ui, lash: lash)
                        } else {
                            WarningContent(model: model, layout: layout)
                        }
                    }
                    .frame(width: island.width, height: island.height, alignment: .topLeading)
                    .transition(Self.contentTransition)
                    .id(presentation.isCompact ? IslandPresentation.closed : presentation)
                }
                .clipShape(IslandShape(bottomRadius: radius))
                .offset(x: island.minX - IslandLayout.topFlare, y: island.minY)

            LiveLash(lash: lash, mood: model.mood, rect: lashRect, resting: presentation == .closed,
                     streakAdvancing: model.streakAdvancing)
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height, alignment: .topLeading)
        .animation(Self.shapeSpring, value: presentation)
        .environment(\.colorScheme, .dark)
    }

    /// The real countdown (not the nudge, which shares its layout but not its alarm).
    private var isWarning: Bool {
        if case .warning = model.phase { return true }
        return false
    }

    private func glowColor(for presentation: IslandPresentation) -> Color? {
        switch presentation {
        case .warning: return isWarning ? IslandPalette.danger : IslandPalette.calm
        case .whipping: return IslandPalette.mania
        case .closed, .peek, .expanded: return nil
        }
    }
}

// MARK: - Shape

/// The island silhouette: square top corners flush with the screen edge, small concave flares where it meets the
/// top edge (like the physical notch), rounded bottom corners. `rect` passed to `path(in:)` includes the flares.
struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var flare: CGFloat = IslandLayout.topFlare

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: flare, dy: 0)
        let r = max(0, min(bottomRadius, body.height / 2, body.width / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: body.maxX, y: body.minY + flare), control: CGPoint(x: body.maxX, y: body.minY))
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        p.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: body.minX, y: body.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Body

/// How often the island's decorative loops redraw. Throbs and flickers look the same at 60 fps as at a ProMotion
/// display's 120, for half the work.
enum IslandFrameRate {
    static let decorative: TimeInterval = 1.0 / 60
    /// Tiny Lash in the closed pill (a furious shake at 31 pt).
    static let tiny: TimeInterval = 1.0 / 30
}

/// The black pill. While whipping it throbs with Lash's cackle — twice as hard when the glass shatters.
private struct IslandBody: View {
    let rect: CGRect
    let bottomRadius: CGFloat
    let pulses: Bool
    var hard = false
    @Environment(\.islandFrozenTime) private var frozenTime

    var body: some View {
        TimelineView(.animation(minimumInterval: IslandFrameRate.decorative, paused: !pulses || frozenTime != nil)) { timeline in
            let time = frozenTime ?? timeline.date.timeIntervalSinceReferenceDate
            let throb = pulses ? CGFloat(abs(sin(time * (hard ? 13 : 9)))) * (hard ? 1.8 : 1) : 0
            IslandShape(bottomRadius: bottomRadius)
                .fill(IslandPalette.ink)
                .frame(width: rect.width + 2 * IslandLayout.topFlare, height: rect.height)
                .scaleEffect(x: 1 + 0.025 * throb, y: 1 + 0.06 * throb, anchor: .top)
                .offset(x: rect.minX - IslandLayout.topFlare, y: rect.minY)
        }
    }
}

/// A soft coloured halo around the island (red while warning, purple while whipping), breathing.
private struct IslandGlow: View {
    let color: Color
    let rect: CGRect
    let bottomRadius: CGFloat
    /// Pulse once a second, like the countdown. Otherwise throb in time with Lash's cackle.
    let heartbeat: Bool
    @Environment(\.islandFrozenTime) private var frozenTime

    var body: some View {
        TimelineView(.animation(minimumInterval: IslandFrameRate.decorative, paused: frozenTime != nil)) { timeline in
            let time = frozenTime ?? timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.5 + 0.5 * sin(time * (heartbeat ? 2 * .pi : 9))
            // The blur radius never changes, so only opacity and scale animate: cheap compositor work instead of
            // a fresh Gaussian blur of the whole halo every frame. Blur before moving into place: a blur is
            // rendered within the view's own layout bounds.
            IslandShape(bottomRadius: bottomRadius)
                .fill(color)
                .frame(width: rect.width + 2 * IslandLayout.topFlare, height: rect.height)
                .padding(40)
                .blur(radius: 15)
                .scaleEffect(1 + 0.05 * pulse, anchor: .top)
                .opacity(0.5 + 0.5 * pulse)
                .offset(x: rect.minX - IslandLayout.topFlare - 40, y: rect.minY - 40)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Lash

/// Lash wired to its live state: gaze, blinking, reactions, poke squish.
private struct LiveLash: View {
    @ObservedObject var lash: LashState
    let mood: CritterMood
    let rect: CGRect
    /// In the closed pill. There, mood faces move only while the streak is running — a sleeping Lash (snoozed for
    /// hours) or a furious one waiting for an idle user holds still, so the island costs nothing — and short-lived
    /// faces (furious, dizzy) move at a tiny face's frame rate. Reactions (dizzy) always play.
    let resting: Bool
    var streakAdvancing = true

    var body: some View {
        let expression = lash.expression(for: mood)
        let holdsStill: Bool = {
            guard resting, case .mood(let mood) = expression else { return false }
            return mood == .sleepy || !streakAdvancing
        }()
        ZStack {
            LashFigure(expression: expression, gaze: lash.gaze, blink: lash.blink,
                       animated: !holdsStill,
                       frameInterval: resting ? IslandFrameRate.tiny : IslandFrameRate.decorative)
                .keyframeAnimator(initialValue: Squish(), trigger: SquishTrigger(pokes: lash.squishes, expression: expression)) { view, squish in
                    view.scaleEffect(x: squish.x, y: squish.y, anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(1.2, duration: 0.07)
                        SpringKeyframe(1, duration: 0.5, spring: .init(response: 0.32, dampingRatio: 0.38))
                    }
                    KeyframeTrack(\.y) {
                        CubicKeyframe(0.8, duration: 0.07)
                        SpringKeyframe(1, duration: 0.5, spring: .init(response: 0.32, dampingRatio: 0.38))
                    }
                }
                // A head pat: the head dips under the hand and bounces back up.
                .keyframeAnimator(initialValue: Squish(), trigger: lash.pats) { view, squish in
                    view.scaleEffect(x: squish.x, y: squish.y, anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack(\.x) {
                        CubicKeyframe(1.06, duration: 0.07)
                        SpringKeyframe(1, duration: 0.35, spring: .init(response: 0.24, dampingRatio: 0.5))
                    }
                    KeyframeTrack(\.y) {
                        CubicKeyframe(0.88, duration: 0.07)
                        SpringKeyframe(1, duration: 0.35, spring: .init(response: 0.24, dampingRatio: 0.5))
                    }
                }
                // Double-click: a full spin with a little hop.
                .keyframeAnimator(initialValue: Spin(), trigger: lash.spins) { view, spin in
                    view.rotationEffect(.degrees(spin.angle)).offset(y: spin.hop)
                } keyframes: { _ in
                    KeyframeTrack(\.angle) {
                        CubicKeyframe(0, duration: 0.04)
                        CubicKeyframe(360, duration: 0.55)
                        CubicKeyframe(360, duration: 0.01)
                    }
                    KeyframeTrack(\.hop) {
                        CubicKeyframe(-rect.height * 0.12, duration: 0.22)
                        CubicKeyframe(0, duration: 0.36)
                    }
                }
            // The figure itself never takes clicks (its glow and steam spill over its neighbours); this circle does:
            // a click pokes, a double-click spins.
            Color.clear
                .contentShape(Circle())
                .onTapGesture { lash.tapped() }
                .accessibilityLabel("Poke Lash")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { lash.poke() }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    private struct Squish { var x: CGFloat = 1; var y: CGFloat = 1 }
    private struct Spin { var angle: Double = 0; var hop: CGFloat = 0 }
    /// Squash & stretch on every poke and whenever the face changes.
    private struct SquishTrigger: Equatable { let pokes: Int; let expression: LashExpression }
}

/// Hearts fanning up and out from behind Lash's head while it's petted. Sized to Lash, and they top out below the
/// ear row, so they never cover the dashboard's text. Animates only while hearts exist.
private struct HeartsLayer: View {
    @ObservedObject var lash: LashState
    let lashRect: CGRect
    @Environment(\.islandFrozenTime) private var frozenTime

    private static let fill = LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.55, blue: 0.74), Color(.sRGB, red: 1, green: 0.24, blue: 0.45)],
                                             startPoint: .top, endPoint: .bottom)

    var body: some View {
        if !lash.hearts.isEmpty {
            let side = lashRect.width
            let origin = CGPoint(x: lashRect.midX, y: lashRect.minY + side * 0.34)
            TimelineView(.animation(minimumInterval: IslandFrameRate.decorative, paused: frozenTime != nil)) { timeline in
                let now = frozenTime ?? timeline.date.timeIntervalSinceReferenceDate
                ZStack(alignment: .topLeading) {
                    ForEach(lash.hearts) { heart in
                        let age = now - heart.born
                        if age >= 0, age < HeartPuff.lifetime {
                            let f = age / HeartPuff.lifetime
                            let rise = CGFloat(1 - pow(1 - f, 2.2))
                            // Pop in past full size, settle, then shrink a little while fading out.
                            let pop = f < 0.12 ? f / 0.12 * 1.3 : max(1, 1.3 - (f - 0.12) * 3)
                            Image(systemName: "heart.fill")
                                .font(.system(size: max(8, side * 0.14), weight: .bold))
                                .foregroundStyle(Self.fill)
                                .scaleEffect(pop * (1 - 0.2 * f))
                                .rotationEffect(.degrees(Double(heart.drift) * 20 * Double(rise)))
                                .opacity(f < 0.6 ? 1 : 1 - (f - 0.6) / 0.4)
                                .position(x: origin.x + heart.drift * side * 0.5 * rise + CGFloat(sin(age * 7)) * side * 0.03,
                                          y: origin.y - side * 0.38 * rise)
                        }
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
}
