import SpriteKit
import SwiftUI

extension DemoRegistry {
    static var notchDemos: [Demo] {
        [
            islandDemo("notch.closed-idle", "Closed pill, no terminal: happy Lash, dim ring") { _ in },
            islandDemo("notch.closed-streak", "Closed pill, 1:23 of 2:00 in kitty") { model in
                model.terminalName = "kitty"
                model.streakSeconds = 83
            },
            stackedDemo("notch.shared", "Sharing the notch with Sapphire playing music (drawn underneath): its album art shows on the left; Lash and the timer's bar on the right (fresh, halfway, nearly out)", [
                IslandDemoScene(hovering: false, sapphire: true) { model in
                    model.terminalName = "kitty"
                    model.streakSeconds = 60
                },
                IslandDemoScene(hovering: false, sapphire: true) { model in
                    model.terminalName = "kitty"
                    model.streakSeconds = 25 * 60
                },
                IslandDemoScene(hovering: false, sapphire: true) { model in
                    model.terminalName = "kitty"
                    model.streakSeconds = 46 * 60
                },
            ]),
            islandDemo("notch.peek", "Closed + a quip after a poke: the island peeks") { model in
                model.quip = "hi. I'm Lash. I bite."
            },
            islandDemo("notch.expanded", "Hover dashboard: fuse, stats, quip, actions", hovering: true) { model in
                model.terminalName = "kitty"
                model.streakSeconds = 83
                model.whipsToday = 3
                model.totalWhips = 42
                model.longestStreakSeconds = 462
                model.quip = "is that a semicolon?"
            },
            islandDemo("notch.nudge", "Break time: 50 min of work, Lash suggests a break before the whip (calm glow)") { model in
                model.terminalName = "kitty"
                model.streakSeconds = 50 * 60 + 12
                model.thresholdSeconds = 50 * 60
                model.phase = .nudge(secondsLeft: 107)
            },
            islandDemo("notch.warning", "Countdown: furious Lash, giant digit, red glow") { model in
                model.terminalName = "kitty"
                model.streakSeconds = 52 * 60
                model.thresholdSeconds = 50 * 60
                model.phase = .warning(secondsLeft: 3)
            },
            stackedDemo("notch.whipping", "Whipping: maniacal Lash cackling, then laughing its hardest as the glass shatters (the whip itself is the overlay's: see overlay.island)", [
                IslandDemoScene(hovering: false) { model in
                    model.terminalName = "kitty"
                    model.phase = .whipping
                },
                IslandDemoScene(hovering: false) { model in
                    model.terminalName = "kitty"
                    model.phase = .whipping
                    model.laughingHard = true
                },
            ]),
            islandDemo("notch.manual", "Manual whip mode") { model in
                model.phase = .manual
            },
            islandDemo("notch.aftermath", "Smug Lash, +1, \"feel better?\"") { model in
                model.terminalName = "kitty"
                model.phase = .aftermath
                model.whipsToday = 4
                model.quip = "feel better?"
            },
            stackedDemo("notch.snoozed", "Snoozed: sleeping Lash, Zzz, time left (closed and hovered)", [
                IslandDemoScene(hovering: false) { $0.phase = .snoozed(until: Date().addingTimeInterval(42 * 60 + 5)) },
                IslandDemoScene(hovering: true) { model in
                    model.phase = .snoozed(until: Date().addingTimeInterval(42 * 60 + 5))
                    model.whipsToday = 2
                    model.totalWhips = 17
                    model.longestStreakSeconds = 301
                    model.screenCaptureGranted = true
                },
            ]),
            islandDemo("notch.snooze-menu", "Dashboard after pressing Snooze: the durations", hovering: true,
                       choosingSnooze: true) { model in
                model.terminalName = "kitty"
                model.streakSeconds = 52
                model.whipsToday = 1
                model.totalWhips = 9
                model.longestStreakSeconds = 140
            },
            islandDemo("notch.petted", "Expanded, being petted: hearts and bliss", hovering: true,
                       reaction: .blissful, hearts: true) { model in
                model.quip = "scritches accepted"
                model.screenCaptureGranted = true
            },
            stackedDemo("notch.play", "Playing with Lash: head pats (hearts, bliss), and a nap", [
                IslandDemoScene(hovering: true, reaction: .blissful, hearts: true) { model in
                    model.quip = "pat pat pat 🥹"
                    model.screenCaptureGranted = true
                },
                IslandDemoScene(hovering: false, reaction: .mood(.sleepy)) { _ in },
            ]),
            stackedDemo("notch.virtual", "External display without a notch: virtual notch (closed and warning)", [
                IslandDemoScene(hovering: false, physicalNotch: false) { model in
                    model.terminalName = "Ghostty"
                    model.streakSeconds = 41
                },
                IslandDemoScene(hovering: false, physicalNotch: false) { model in
                    model.terminalName = "Ghostty"
                    model.phase = .warning(secondsLeft: 5)
                },
            ]),
            Demo(name: "notch.moods", summary: "Lash in every mood and reaction, large",
                 size: CGSize(width: 1000, height: 560),
                 payload: .view(ViewDemo(make: { AnyView(LashMoodGrid()) }, background: NSColor(white: 0.05, alpha: 1)))),
            Demo(name: "notch.motion", summary: "Filmstrips of every looping animation, frame by frame (time runs left → right)",
                 size: MotionStrips.size,
                 payload: .view(ViewDemo(make: { AnyView(MotionStrips()) }, background: NSColor(white: 0.07, alpha: 1)))),
        ]
    }

    private static func islandDemo(_ name: String, _ summary: String, hovering: Bool = false,
                                   reaction: LashExpression? = nil, hearts: Bool = false, choosingSnooze: Bool = false,
                                   configure: @escaping (IslandModel) -> Void) -> Demo {
        let scene = IslandDemoScene(hovering: hovering, reaction: reaction, hearts: hearts, choosingSnooze: choosingSnooze,
                                    configure: configure)
        return Demo(name: name, summary: summary, size: IslandDemoScene.size,
                    payload: .view(ViewDemo(make: { AnyView(scene) }, background: nil)))
    }

    private static func stackedDemo(_ name: String, _ summary: String, _ scenes: [IslandDemoScene]) -> Demo {
        Demo(name: name, summary: summary,
             size: CGSize(width: IslandDemoScene.size.width, height: IslandDemoScene.size.height * CGFloat(scenes.count) + CGFloat(scenes.count - 1) * 4),
             payload: .view(ViewDemo(make: {
                 AnyView(VStack(spacing: 4) { ForEach(scenes.indices, id: \.self) { scenes[$0] } })
             }, background: NSColor(white: 0.1, alpha: 1))))
    }
}

// MARK: - Scene

/// A slice of a 16" MacBook desktop around the notch — wallpaper, menu bar, a terminal — with the island on top,
/// then the physical notch painted over it (as the hardware would hide those pixels) to prove the seamless merge.
private struct IslandDemoScene: View {
    static let size = CGSize(width: 760, height: 260)
    /// Every animation is frozen at this instant, so renders are reproducible.
    static let frozenTime: TimeInterval = 1000.35

    let hovering: Bool
    var reaction: LashExpression?
    var hearts = false
    var physicalNotch = true
    var choosingSnooze = false
    /// Another app's island (Sapphire playing music) under ours.
    var sapphire = false
    let configure: (IslandModel) -> Void

    var body: some View {
        let model = IslandModel()
        configure(model)
        let notch = physicalNotch
            ? NotchGeometry.demo(size: Self.size).notchRect.size
            : NotchGeometry.virtualNotchSize
        let layout = IslandLayout(notchSize: notch, sharesLeft: sapphire)
        let panel = layout.panelSize
        let eye = layout.eyeCenter(for: IslandPresentation.resolve(phase: model.phase, hovering: hovering, hasQuip: model.quip != nil))
        // Pretend the cursor is down in the terminal, bottom right.
        let cursor = CGPoint(x: panel.width * 0.85, y: panel.height * 2.2)
        let puffs = hearts ? [0.25, 0.55, 0.85].enumerated().map { i, age in
            HeartPuff(id: i, born: Self.frozenTime - age, drift: [-0.85, 0.1, 0.8][i])
        } : []
        let lash = LashState(model: model, gaze: Gaze.quantized(Gaze.vector(from: eye, to: cursor)), reaction: reaction, hearts: puffs)

        return ZStack(alignment: .top) {
            DemoDesktop(menuBarHeight: notch.height)
            if sapphire { FakeSapphire(notch: notch) }
            IslandView(model: model, ui: IslandUIState(layout: layout, isHovering: hovering, choosingSnooze: choosingSnooze), lash: lash)
                .frame(width: panel.width, height: panel.height)
            if physicalNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(Color.black)
                    .frame(width: notch.width, height: notch.height)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .clipped()
        .environment(\.islandFrozenTime, Self.frozenTime)
    }

    init(hovering: Bool, reaction: LashExpression? = nil, hearts: Bool = false, physicalNotch: Bool = true,
         choosingSnooze: Bool = false, sapphire: Bool = false, configure: @escaping (IslandModel) -> Void) {
        self.hovering = hovering
        self.reaction = reaction
        self.hearts = hearts
        self.physicalNotch = physicalNotch
        self.choosingSnooze = choosingSnooze
        self.sapphire = sapphire
        self.configure = configure
    }
}

/// Sapphire's island playing music, as it looks on the user's Mac (about 282 × 38 pt round the notch): album art on
/// the left, a level meter on the right.
private struct FakeSapphire: View {
    let notch: CGSize

    var body: some View {
        let reach: CGFloat = 49
        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12).fill(Color.black)
            HStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(.sRGB, red: 0.95, green: 0.75, blue: 0.6), Color(.sRGB, red: 0.35, green: 0.2, blue: 0.25)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .padding(.leading, 12)
                Spacer()
                HStack(spacing: 3) {
                    ForEach([6.0, 6.0, 18.0], id: \.self) { height in
                        Capsule().fill(Color(.sRGB, red: 0.95, green: 0.55, blue: 0.35)).frame(width: 4, height: height)
                    }
                }
                .padding(.trailing, 14)
            }
        }
        .frame(width: notch.width + 2 * reach, height: notch.height + 1)
    }
}

/// Wallpaper, a translucent menu bar with menus and a clock, and the top of a kitty window.
private struct DemoDesktop: View {
    let menuBarHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(.sRGB, red: 0.10, green: 0.07, blue: 0.28), Color(.sRGB, red: 0.42, green: 0.16, blue: 0.48),
                                    Color(.sRGB, red: 0.95, green: 0.45, blue: 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.teal.opacity(0.35), .clear], center: UnitPoint(x: 0.15, y: 0.9), startRadius: 0, endRadius: 380)

            terminal
                .frame(width: 560, height: 170)
                .offset(x: 40, y: 150)

            HStack(spacing: 22) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("kitty").font(.system(size: 13.5, weight: .bold))
                ForEach(["Shell", "Edit", "View"], id: \.self) { Text($0) }
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text("Wed 24 Sep  14:02")
            }
            .font(.system(size: 13.5, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: menuBarHeight)
            .background(Color.black.opacity(0.35))
        }
    }

    private var terminal: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 11, height: 11) }
                Spacer()
                Text("kitty — zsh").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color(.sRGB, red: 0.14, green: 0.14, blue: 0.19))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(FakeBackdrop.terminalLines.prefix(6), id: \.self) { line in
                    Text(line).foregroundColor(line.hasPrefix("$") ? .green : .white.opacity(0.85))
                }
            }
            .font(.system(size: 13, design: .monospaced))
            .padding(12)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: FakeBackdrop.terminalBackground))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}

// MARK: - Moods

/// Every expression Lash has, in a labelled grid.
private struct LashMoodGrid: View {
    private let cells: [(String, LashExpression)] =
        CritterMood.allCases.map { ($0.rawValue, LashExpression.mood($0)) } + [("dizzy", .dizzy), ("petted", .blissful)]

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(180), spacing: 12), count: 5)
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(cells, id: \.0) { name, expression in
                VStack(spacing: 12) {
                    LashFigure(expression: expression, gaze: CGVector(dx: 0.45, dy: 0.55))
                        .frame(width: 140, height: 140)
                        .frame(width: 180, height: 200)
                        .background(RoundedRectangle(cornerRadius: 22).fill(Color.black))
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                    Text(name).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(24)
        .environment(\.islandFrozenTime, IslandDemoScene.frozenTime)
    }
}

// MARK: - Motion

/// ImageRenderer can only draw stills, so every looping animation is shown as a filmstrip: the same view frozen at
/// successive instants. Reading a row left to right shows the loop's timing, amplitude and readability.
private struct MotionStrips: View {
    static let size = CGSize(width: 1240, height: 1060)
    private static let start = IslandDemoScene.frozenTime

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            lashRow("furious · shake + steam", .mood(.furious), step: 0.1)
            lashRow("maniacal · cackle", .mood(.maniacal), step: 0.05)
            lashRow("dizzy · spinning eyes + stars", .dizzy, step: 0.1)
            lashRow("sleepy · breathing + Zzz", .mood(.sleepy), step: 0.3)
            strip("fuse · spark + embers", step: 0.04, count: 8) { _ in
                BurningFuse(progress: 0.62, lit: true).frame(width: 130).padding(.horizontal, 6)
            }
            strip("whipping island · throb + handle", step: 0.06, count: 4, width: 290) { _ in
                islandCrop(phase: .whipping, height: 100)
            }
            strip("warning island · glow heartbeat", step: 0.25, count: 4, width: 290) { _ in
                islandCrop(phase: .warning(secondsLeft: 4), height: 180)
            }
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private func lashRow(_ title: String, _ expression: LashExpression, step: TimeInterval) -> some View {
        strip(title, step: step, count: 8) { _ in
            LashFigure(expression: expression, gaze: CGVector(dx: 0.4, dy: 0.5), animated: true)
                .frame(width: 70, height: 70)
                .frame(width: 130, height: 108)
        }
    }

    private func strip<Cell: View>(_ title: String, step: TimeInterval, count: Int, width: CGFloat = 140,
                                   @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title)   Δt = \(Int(step * 1000)) ms")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
            HStack(spacing: 8) {
                ForEach(0..<count, id: \.self) { i in
                    cell(i)
                        .frame(width: width)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.16)))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .environment(\.islandFrozenTime, Self.start + Double(i) * step)
                }
            }
        }
    }

    /// The top-centre of the island panel, scaled down to fit a filmstrip cell.
    private func islandCrop(phase: IslandPhase, height: CGFloat) -> some View {
        let model = IslandModel()
        model.terminalName = "kitty"
        model.phase = phase
        let layout = IslandLayout(notchSize: NotchGeometry.demo(size: DemoDefaults.screenSize).notchRect.size)
        return IslandView(model: model, ui: IslandUIState(layout: layout), lash: LashState(model: model))
            .frame(width: layout.panelSize.width, height: layout.panelSize.height)
            .scaleEffect(0.55, anchor: .top)
            .frame(width: 290, height: height, alignment: .top)
            .clipped()
    }
}
