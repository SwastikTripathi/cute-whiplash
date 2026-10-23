import SwiftUI

/// Content of the compact presentations (closed, peek, whipping). Lash himself is drawn by `IslandView`, on the right.
/// Closed and peeking, the work timer runs down the island's right end as a bar, and the peek's lip carries Lash's
/// quip. Whipping, the left wing laughs (or eggs you on), and the lip says how to leave manual whip mode, or counts
/// down the break after a shatter.
struct CompactContent: View {
    @ObservedObject var model: IslandModel
    let presentation: IslandPresentation
    let layout: IslandLayout

    var body: some View {
        let island = layout.islandRect(for: presentation)
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if presentation == .whipping {
                        WhipWing(model: model)
                            .frame(width: IslandLayout.whipWing - 6, height: layout.notchSize.height)
                            .padding(.leading, 6)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: layout.notchSize.height)
                if presentation == .whipping, model.phase == .manual {
                    // The overlay has the mouse now; say how to give it back.
                    Text("esc or right-click to stop")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(IslandPalette.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if presentation == .whipping, model.phase == .whipping, let seconds = model.breakSecondsLeft {
                    // The break: what Lash thinks of you, and when the screen comes back.
                    (Text(model.breakTaunt.map { "\($0)  ·  " } ?? "").foregroundColor(IslandPalette.mania)
                     + Text("back in \(seconds)").foregroundColor(IslandPalette.text))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                if presentation == .peek, let quip = model.quip {
                    Text(quip)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(IslandPalette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.leading, 16)
                        .padding(.trailing, island.maxX - layout.lashRect(for: .peek).minX + 4)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                        .id(quip)
                }
            }
            if let fuse = layout.fuseRect(for: presentation) {
                FuseBar(model: model)
                    .frame(width: fuse.width, height: fuse.height)
                    .offset(x: fuse.minX - island.minX, y: fuse.minY - island.minY)
            }
        }
    }
}

/// The work timer as a bar down the island's right end: how much of the session is left before the break reminder.
/// Full and green when there's all the time in the world (no session running yet), then shorter as it runs out,
/// draining towards the bottom and turning amber, then red. Blue while snoozed, grey while auto-whip is off. The
/// empty part stays visible as a faint track, so you can see how much has gone. No digits: the dashboard has those.
struct FuseBar: View {
    @ObservedObject var model: IslandModel

    /// How much of the bar is left (0...1) and its colour.
    static func state(phase: IslandPhase, streakSeconds: TimeInterval, progress: Double) -> (left: Double, color: Color) {
        switch phase {
        case .snoozed: return (1, IslandPalette.calm)
        case .disabled: return (1, Color(white: 0.55))
        default:
            guard streakSeconds >= 1 else { return (1, ProgressPalette.color(0)) }
            return (max(0, 1 - progress), ProgressPalette.color(progress))
        }
    }

    var body: some View {
        let state = Self.state(phase: model.phase, streakSeconds: model.streakSeconds, progress: model.progress)
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.2))
                Capsule()
                    .fill(state.color)
                    .frame(height: max(geometry.size.width, geometry.size.height * state.left))
                    .shadow(color: state.color.opacity(0.7), radius: 3)
                    .opacity(state.left > 0 ? 1 : 0)
            }
        }
        .animation(.linear(duration: 1), value: state.left)
    }
}

/// The whipping island's left wing: Lash cackling at your screen, or egging you on while you hold the whip.
private struct WhipWing: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.phase == .manual {
            Text("crack it!")
                .font(.system(size: 11.5, weight: .black, design: .rounded))
                .foregroundColor(IslandPalette.mania)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else {
            Cackle(hard: model.laughingHard)
        }
    }
}

/// "HA HA" bouncing to the rhythm of Lash's laugh; "BWAHAHA", bigger and wilder, as the glass shatters.
private struct Cackle: View {
    var hard = false
    @Environment(\.islandFrozenTime) private var frozenTime

    var body: some View {
        TimelineView(.animation(minimumInterval: IslandFrameRate.decorative, paused: frozenTime != nil)) { timeline in
            let time = frozenTime ?? timeline.date.timeIntervalSinceReferenceDate
            let syllables = hard ? ["BWA", "HA!"] : ["HA", "HA"]
            let rate = hard ? 13.0 : 9.0
            HStack(spacing: hard ? 0 : 1) {
                ForEach(syllables.indices, id: \.self) { i in
                    Text(syllables[i])
                        .font(.system(size: hard ? 12 : 14, weight: .black, design: .rounded))
                        .foregroundStyle(i % 2 == 0 ? IslandPalette.mania : Color.white)
                        .fixedSize()
                        .offset(y: -abs(sin(time * rate + Double(i) * 1.3)) * (hard ? 4 : 3))
                        .rotationEffect(.degrees(sin(time * rate + Double(i)) * (hard ? 12 : 8)))
                }
            }
        }
    }
}
