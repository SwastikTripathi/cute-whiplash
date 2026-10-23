import SwiftUI

/// Text formatting for the island.
enum IslandFormat {
    /// "1:23", "10:00", "1:02:05".
    static func clock(_ seconds: TimeInterval) -> String {
        // Clamped before converting: Int(_:) traps on NaN, infinity and huge values.
        let total = Int(min(359_999, max(0, seconds.isFinite ? seconds : 0)).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Compact remaining time, rounded up: "1m", "42m", "3h", "2h 5m".
    static func remaining(_ seconds: TimeInterval) -> String {
        // Clamped to 99 h before converting, so `.distantFuture` or a NaN can't trap.
        let minutes = Int(min(99 * 60, max(1, seconds.isFinite ? (seconds / 60).rounded(.up) : 1)))
        guard minutes >= 60 else { return "\(minutes)m" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

/// The snooze choices offered by the dashboard.
enum SnoozeOption: CaseIterable {
    case fifteenMinutes, oneHour, restOfDay

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 min"
        case .oneHour: return "1 hour"
        case .restOfDay: return "Rest of day"
        }
    }

    /// Snooze length starting at `now`. "Rest of day" runs until the next midnight in `calendar`.
    func duration(from now: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .restOfDay:
            let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                                             matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
            return midnight.timeIntervalSince(now)
        }
    }
}

/// The time limits the dashboard's chooser offers.
enum ThresholdOption {
    static let all: [(label: String, seconds: TimeInterval)] = [
        ("25m", 1500), ("45m", 2700), ("50m", 3000), ("60m", 3600), ("90m", 5400),
    ]
}

/// Streak colours: green → amber → red as the fuse burns down.
enum ProgressPalette {
    private static let stops: [(at: Double, rgb: (Double, Double, Double))] = [
        (0.0, (0.20, 0.84, 0.42)),
        (0.55, (1.00, 0.72, 0.10)),
        (1.0, (1.00, 0.24, 0.20)),
    ]

    /// Linear interpolation between the stops, in sRGB.
    static func rgb(_ progress: Double) -> (red: Double, green: Double, blue: Double) {
        let p = min(1, max(0, progress))
        for (lower, upper) in zip(stops, stops.dropFirst()) where p <= upper.at {
            let t = (p - lower.at) / (upper.at - lower.at)
            return (lower.rgb.0 + (upper.rgb.0 - lower.rgb.0) * t,
                    lower.rgb.1 + (upper.rgb.1 - lower.rgb.1) * t,
                    lower.rgb.2 + (upper.rgb.2 - lower.rgb.2) * t)
        }
        let last = stops[stops.count - 1].rgb
        return (last.0, last.1, last.2)
    }

    static func color(_ progress: Double) -> Color {
        let c = rgb(progress)
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

/// The island's colour tokens.
enum IslandPalette {
    static let ink = Color.black
    static let text = Color.white
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.34)
    static let chip = Color.white.opacity(0.11)
    static let chipStroke = Color.white.opacity(0.08)
    static let flame = Color(.sRGB, red: 1.0, green: 0.48, blue: 0.16)
    static let danger = Color(.sRGB, red: 1.0, green: 0.27, blue: 0.23)
    static let mania = Color(.sRGB, red: 0.72, green: 0.38, blue: 1.0)
    static let gold = Color(.sRGB, red: 1.0, green: 0.80, blue: 0.30)
    static let calm = Color(.sRGB, red: 0.47, green: 0.66, blue: 1.0)
}
