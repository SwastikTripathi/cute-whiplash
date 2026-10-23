import SwiftUI

/// The hover dashboard: mood and toggles in the ears beside the notch; below, the streak, the burning fuse, stats,
/// Lash's quip and the actions on the left, and room for big Lash on the right.
struct ExpandedContent: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var ui: IslandUIState
    /// Only read by the mood chip (which observes it); the dashboard doesn't redraw when Lash's eyes move.
    let lash: LashState

    private var layout: IslandLayout { ui.layout }

    var body: some View {
        let island = layout.islandRect(for: .expanded)
        let lashColumn = island.maxX - layout.lashRect(for: .expanded).minX + 8
        VStack(spacing: 0) {
            EarRow(layout: layout, islandWidth: island.width) {
                LiveMoodChip(lash: lash, mood: model.mood)
            } trailing: {
                HStack(spacing: 5) {
                    EarToggle(isOn: model.soundEnabled, onSymbol: "speaker.wave.2.fill", offSymbol: "speaker.slash.fill",
                              help: model.soundEnabled ? "Mute Lash" : "Unmute Lash") { model.onToggleSound() }
                    EarToggle(isOn: model.autoWhipEnabled, onSymbol: "bolt.fill", offSymbol: "bolt.slash.fill",
                              help: model.autoWhipEnabled ? "Auto-whip is on" : "Auto-whip is off") { model.onToggleAutoWhip() }
                }
            }

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    HStack(spacing: 8) {
                        BurningFuse(progress: fuseProgress, lit: fuseLit)
                        // Snuff the fuse: the work timer starts over, any time.
                        Button { model.onSpareOnce() } label: {
                            IconLabel(title: "Spare me this once", symbol: "arrow.counterclockwise")
                        }
                        .buttonStyle(IslandPillStyle(height: 22, compact: true))
                        .fixedSize()
                        .disabled(model.streakSeconds < 1)
                        .opacity(model.streakSeconds < 1 ? 0.45 : 1)
                        .help("Reset the work timer to 0:00")
                    }
                    stats
                    quipLine
                    actions
                }
                .padding(.top, 4)
                .padding(.leading, 18)

                VStack {
                    Spacer(minLength: 0)
                    if !model.screenCaptureGranted {
                        if model.screenCaptureRelaunchOffered { relaunchLink } else { captureLink }
                    }
                }
                .frame(width: lashColumn)
                .padding(.bottom, 10)
            }
        }
        // Next time the dashboard opens, it starts with the regular buttons.
        .onDisappear { ui.choosingSnooze = false }
    }

    // MARK: Rows

    @ViewBuilder private var header: some View {
        HStack(spacing: 0) {
            Group {
                switch model.phase {
                case .snoozed(let until):
                    TimelineView(.everyMinute) { timeline in
                        (Text("snoozed").foregroundColor(IslandPalette.calm)
                         + Text(" · \(IslandFormat.remaining(until.timeIntervalSince(timeline.date))) left").foregroundColor(IslandPalette.secondary))
                    }
                case .disabled:
                    Text("auto-whip is off").foregroundColor(IslandPalette.secondary)
                default:
                    if model.streakSeconds >= 1 {
                        Text("work").foregroundColor(IslandPalette.text)
                            + Text("  \(IslandFormat.clock(model.streakSeconds)) / \(IslandFormat.clock(model.thresholdSeconds))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundColor(IslandPalette.secondary)
                    } else {
                        Text("rested").foregroundColor(IslandPalette.calm)
                            + Text("  break at \(IslandFormat.clock(model.thresholdSeconds))")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundColor(IslandPalette.secondary)
                    }
                }
            }
            .font(.system(size: 13.5, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            ThresholdChooser(seconds: model.thresholdSeconds) { model.onSetThreshold($0) }
        }
    }

    private var stats: some View {
        HStack(spacing: 11) {
            stat("flame.fill", tint: IslandPalette.flame, "\(model.whipsToday) today")
                // Bumps when a new whip lands.
                .keyframeAnimator(initialValue: CGFloat(1), trigger: model.whipsToday) { view, scale in
                    view.scaleEffect(scale, anchor: .leading)
                } keyframes: { _ in
                    CubicKeyframe(1.35, duration: 0.08)
                    SpringKeyframe(1, duration: 0.5, spring: .init(response: 0.3, dampingRatio: 0.4))
                }
            stat("sum", tint: IslandPalette.secondary, "\(model.totalWhips) total")
            stat("trophy.fill", tint: IslandPalette.gold, "best \(IslandFormat.clock(model.longestStreakSeconds))")
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
        .foregroundColor(IslandPalette.secondary)
        .lineLimit(1)
    }

    private func stat(_ symbol: String, tint: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).foregroundColor(tint)
            Text(text)
        }
    }

    private var quipLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "quote.bubble.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(model.quip == nil ? IslandPalette.tertiary : MoodChip.color(for: model.mood))
            Group {
                if let quip = model.quip {
                    Text(quip).foregroundColor(IslandPalette.text).transition(.opacity).id(quip)
                } else {
                    Text(QuipBook.status(for: model.mood)).foregroundColor(IslandPalette.tertiary)
                }
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .frame(height: 17)
        .animation(.easeInOut(duration: 0.2), value: model.quip)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if ui.choosingSnooze {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(IslandPalette.calm)
                    .padding(.trailing, 2)
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.title) {
                        ui.choosingSnooze = false
                        model.onSnooze(option.duration())
                    }
                    .buttonStyle(IslandPillStyle())
                }
                Button {
                    ui.choosingSnooze = false
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .heavy))
                }
                .buttonStyle(IslandPillStyle())
                .help("Never mind")
            } else {
                Button { model.onWhipNow() } label: { IconLabel(title: "Whip me", symbol: "flame.fill") }
                    .buttonStyle(IslandPillStyle(fill: IslandPalette.flame))
                    .help("Crack the screen right now")
                switch model.phase {
                case .snoozed:
                    Button { model.onResume() } label: { IconLabel(title: "Wake up", symbol: "sun.max.fill") }
                        .buttonStyle(IslandPillStyle(fill: IslandPalette.calm))
                case .disabled:
                    Button { model.onToggleAutoWhip() } label: { IconLabel(title: "Turn on", symbol: "power") }
                        .buttonStyle(IslandPillStyle(fill: ProgressPalette.color(0)))
                default:
                    Button { ui.choosingSnooze = true } label: { IconLabel(title: "Snooze", symbol: "moon.zzz.fill") }
                        .buttonStyle(IslandPillStyle())
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: ui.choosingSnooze)
    }

    /// Shown only while Screen Recording is missing: once granted, real shattering just works.
    private var captureLink: some View {
        linkButton("sparkles", "Enable real\nshattering", help: "Let Lash see the screen so the real pixels shatter") {
            model.onRequestScreenCapture()
        }
    }

    /// The user has been to System Settings and the grant still isn't visible: macOS may want a fresh process.
    private var relaunchLink: some View {
        linkButton("arrow.clockwise", "Switched on?\nRelaunch me",
                   help: "If Whiplash is switched on in System Settings › Privacy & Security › Screen & System Audio "
                       + "Recording, relaunch it so macOS applies the permission") {
            model.onRelaunch()
        }
    }

    private func linkButton(_ symbol: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            (Text(Image(systemName: symbol)) + Text(" ") + Text(title).underline())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(IslandPalette.mania)
                .multilineTextAlignment(.center)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Fuse state

    private var fuseLit: Bool {
        guard case .idle = model.phase else { return false }
        return model.streakAdvancing
    }

    private var fuseProgress: Double {
        switch model.phase {
        case .aftermath: return 1
        case .snoozed, .disabled: return 0
        default: return model.progress
        }
    }
}

/// The countdown (auto-expanded, giant digit popping each second, Lash furious), and the gentler nudge before it
/// (same layout, calm colours: a break suggestion with the time left to take it).
struct WarningContent: View {
    @ObservedObject var model: IslandModel
    let layout: IslandLayout

    var body: some View {
        let island = layout.islandRect(for: .warning)
        VStack(spacing: 0) {
            if case .nudge(let seconds) = model.phase {
                nudge(secondsLeft: max(0, seconds), island: island)
            } else {
                warning(secondsLeft: { if case .warning(let s) = model.phase { return max(0, s) }; return 0 }(), island: island)
            }
        }
    }

    /// The way out: put it off for 15 minutes, or start the work timer over.
    private var reprieveButtons: some View {
        HStack(spacing: 6) {
            Button { model.onSnooze(SnoozeOption.fifteenMinutes.duration()) } label: {
                IconLabel(title: "Not now · 15 min", symbol: "hand.raised.fill")
            }
            .help("Snooze the reminders for 15 minutes")
            Button { model.onSpareOnce() } label: {
                IconLabel(title: "Spare me this once", symbol: "arrow.counterclockwise")
            }
            .help("Reset the work timer: no whip this time")
        }
        .buttonStyle(IslandPillStyle(height: 24, compact: true))
        .fixedSize()
    }

    @ViewBuilder
    private func nudge(secondsLeft: Int, island: CGRect) -> some View {
        EarRow(layout: layout, islandWidth: island.width) {
            HStack(spacing: 3) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 9.5, weight: .black))
                Text("BREAK TIME").font(.system(size: 10, weight: .black, design: .rounded)).tracking(0.4)
            }
            .foregroundColor(IslandPalette.calm)
        } trailing: {
            HStack(spacing: 4) {
                Image(systemName: "clock.fill").font(.system(size: 10, weight: .bold))
                Text("worked \(IslandFormat.clock(model.streakSeconds))")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundColor(IslandPalette.secondary)
        }

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(IslandFormat.clock(TimeInterval(secondsLeft)))
                        .font(.system(size: 30, weight: .black, design: .rounded).monospacedDigit())
                        .foregroundColor(IslandPalette.calm)
                        .frame(minWidth: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(QuipBook.nudge(workSeconds: model.streakSeconds))
                            .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                            .foregroundColor(IslandPalette.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("step away to call off the whip")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(IslandPalette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                reprieveButtons
            }
            Spacer(minLength: 0)
            // Big Lash's corner.
            Color.clear.frame(width: island.maxX - layout.lashRect(for: .warning).minX + 2)
        }
        .padding(.leading, 16)
        .padding(.bottom, 6)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func warning(secondsLeft seconds: Int, island: CGRect) -> some View {
        EarRow(layout: layout, islandWidth: island.width) {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5, weight: .black))
                Text("WHIP INCOMING").font(.system(size: 10, weight: .black, design: .rounded)).tracking(0.4)
            }
            .foregroundColor(IslandPalette.danger)
        } trailing: {
            HStack(spacing: 4) {
                Image(systemName: "clock.fill").font(.system(size: 10, weight: .bold))
                Text("worked \(IslandFormat.clock(model.streakSeconds))")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
            }
            .foregroundColor(IslandPalette.secondary)
        }

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    CountdownDigit(seconds: seconds)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(QuipBook.warning(secondsLeft: seconds))
                            .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                            .foregroundColor(IslandPalette.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(seconds)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                        Text("step away to cancel")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundColor(IslandPalette.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .animation(.easeOut(duration: 0.2), value: seconds)
                }
                reprieveButtons
            }
            Spacer(minLength: 0)
            // Big Lash's corner.
            Color.clear.frame(width: island.maxX - layout.lashRect(for: .warning).minX + 2)
        }
        .padding(.leading, 16)
        .padding(.bottom, 6)
        .frame(maxHeight: .infinity)
    }
}

private struct CountdownDigit: View {
    let seconds: Int

    var body: some View {
        Text("\(seconds)")
            .font(.system(size: 76, weight: .black, design: .rounded).monospacedDigit())
            .foregroundStyle(LinearGradient(colors: [Color(.sRGB, red: 1, green: 0.55, blue: 0.3), IslandPalette.danger],
                                            startPoint: .top, endPoint: .bottom))
            .shadow(color: IslandPalette.danger.opacity(0.8), radius: 12)
            .contentTransition(.numericText(countsDown: true))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: seconds)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: seconds) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(1.4, duration: 0.06)
                SpringKeyframe(1, duration: 0.45, spring: .init(response: 0.3, dampingRatio: 0.45))
            }
            .frame(width: 60)
    }
}
