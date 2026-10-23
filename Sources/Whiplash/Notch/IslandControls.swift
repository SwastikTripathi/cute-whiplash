import SwiftUI

/// Capsule buttons for the island: a translucent chip, or filled with `fill` for the primary action.
struct IslandPillStyle: ButtonStyle {
    var fill: Color?
    var height: CGFloat = 26
    /// Smaller type and padding, for secondary buttons that share a row.
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold, design: .rounded))
            .foregroundColor(fill == nil ? IslandPalette.text : .black)
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: height)
            .background(Capsule().fill(fill ?? IslandPalette.chip))
            .overlay(Capsule().strokeBorder(fill == nil ? IslandPalette.chipStroke : .clear, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// An SF Symbol plus a title, tightly spaced.
struct IconLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
            Text(title)
        }
    }
}

/// A round icon toggle for the top-right ear (sound, auto-whip). Off shows the slashed symbol, dimmed.
struct EarToggle: View {
    let isOn: Bool
    let onSymbol: String
    let offSymbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? onSymbol : offSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isOn ? IslandPalette.text : IslandPalette.tertiary)
                .frame(width: 26, height: 24)
                .background(Capsule().fill(isOn ? IslandPalette.chip : Color.white.opacity(0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The time-limit chooser: 30s · 1m · 2m · 5m · 10m.
struct ThresholdChooser: View {
    let seconds: TimeInterval
    let onSelect: (TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ThresholdOption.all, id: \.seconds) { option in
                let selected = abs(option.seconds - seconds) < 0.5
                Button {
                    onSelect(option.seconds)
                } label: {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: selected ? .heavy : .semibold, design: .rounded))
                        .foregroundColor(selected ? .black : IslandPalette.secondary)
                        .frame(width: 30, height: 19)
                        .background(Capsule().fill(selected ? Color.white : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(IslandPalette.chip))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: seconds)
        .help("Terminal time before the whip comes out")
    }
}

/// A colour-coded chip naming Lash's mood, or the reaction that's overriding it right now ("dizzy", "blissful").
struct MoodChip: View {
    let expression: LashExpression

    var body: some View {
        HStack(spacing: 5) {
            Text("LASH")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1.4)
                .foregroundColor(IslandPalette.secondary)
            Text(Self.name(for: expression))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Self.color(for: expression))
                .contentTransition(.opacity)
        }
        .animation(.easeInOut(duration: 0.2), value: expression)
    }

    static func name(for expression: LashExpression) -> String {
        switch expression {
        case .mood(let mood): return mood.rawValue
        case .dizzy: return "dizzy"
        case .blissful: return "blissful"
        }
    }

    static func color(for expression: LashExpression) -> Color {
        switch expression {
        case .mood(let mood): return color(for: mood)
        case .dizzy: return IslandPalette.gold
        case .blissful: return Color(.sRGB, red: 1, green: 0.5, blue: 0.72)
        }
    }

    static func color(for mood: CritterMood) -> Color {
        switch mood {
        case .happy: return ProgressPalette.color(0)
        case .curious: return IslandPalette.calm
        case .suspicious: return Color(.sRGB, red: 1, green: 0.86, blue: 0.3)
        case .annoyed: return IslandPalette.flame
        case .furious: return IslandPalette.danger
        case .maniacal: return IslandPalette.mania
        case .smug: return Color(.sRGB, red: 1, green: 0.5, blue: 0.72)
        case .sleepy: return Color(.sRGB, red: 0.62, green: 0.7, blue: 1)
        }
    }
}

/// The mood chip, following Lash's live reactions.
struct LiveMoodChip: View {
    @ObservedObject var lash: LashState
    let mood: CritterMood

    var body: some View {
        MoodChip(expression: lash.expression(for: mood))
    }
}

/// The strip beside the notch at the top of a big presentation. Each ear has a fixed width so nothing can slide
/// under the physical notch, where the camera housing would hide it; content that is too wide shrinks instead.
struct EarRow<Leading: View, Trailing: View>: View {
    let layout: IslandLayout
    let islandWidth: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let ear = (islandWidth - layout.notchSize.width) / 2
        HStack(spacing: 0) {
            leading
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: max(0, ear - 24), alignment: .leading)
                .padding(.leading, 18)
                .padding(.trailing, 6)
            Color.clear.frame(width: layout.notchSize.width)
            trailing
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: max(0, ear - 24), alignment: .trailing)
                .padding(.leading, 6)
                .padding(.trailing, 18)
        }
        .frame(height: layout.notchSize.height)
    }
}
