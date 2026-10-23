import Combine
import Foundation

/// User preferences, persisted to UserDefaults under `whiplash.*`.
final class Settings: ObservableObject {
    static let shared = Settings()

    static let defaultTerminalBundleIDs: [String] = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "io.alacritty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
    ]

    /// Work since the last real break (seconds) before Lash nudges you to take one — and whips if you don't.
    /// (Saved under a new key: the old setting measured something else, unbroken terminal focus.)
    @Published var thresholdSeconds: TimeInterval { didSet { save("workThresholdSeconds", thresholdSeconds) } }
    /// No input for this long counts as a real break: the work clock goes back to 0.
    @Published var breakSeconds: TimeInterval { didSet { save("breakSeconds", breakSeconds) } }
    /// After a whip (or a heeded nudge) with no real break, the next reminder comes after this much more work.
    @Published var repeatSeconds: TimeInterval { didSet { save("repeatSeconds", repeatSeconds) } }
    /// How long Lash nudges ("stretch break?") before the whip comes out.
    @Published var nudgeSeconds: TimeInterval { didSet { save("nudgeSeconds", nudgeSeconds) } }
    /// Stepping away (no input) this long during the nudge calls the whip off.
    @Published var stepAwaySeconds: TimeInterval { didSet { save("stepAwaySeconds", stepAwaySeconds) } }
    /// Work in other apps counts while a terminal was in use within this long (reading docs between commands).
    @Published var terminalRecencySeconds: TimeInterval { didSet { save("terminalRecencySeconds", terminalRecencySeconds) } }
    /// No keyboard/mouse input for this long pauses the work clock (you're reading, or watching a build).
    @Published var idlePauseSeconds: TimeInterval { didSet { save("idlePauseSeconds", idlePauseSeconds) } }
    /// Master switch for automatic whipping.
    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var soundEnabled: Bool { didSet { save("soundEnabled", soundEnabled) } }
    /// Use a real screenshot so the actual screen shatters (needs Screen Recording permission).
    @Published var useScreenCapture: Bool { didSet { save("useScreenCapture", useScreenCapture) } }
    /// Chaos multiplier, 0.5 (gentle) ... 2.0 (unhinged).
    @Published var intensity: Double { didSet { save("intensity", intensity) } }
    /// Each repeat whip in the same unbroken streak gets harsher.
    @Published var escalate: Bool { didSet { save("escalate", escalate) } }
    @Published var terminalBundleIDs: [String] { didSet { save("terminalBundleIDs", terminalBundleIDs) } }
    /// Where the island sits (see `IslandPlacement`).
    @Published var islandPlacement: IslandPlacement { didSet { save("islandPlacement", islandPlacement.rawValue) } }
    @Published var snoozedUntil: Date? { didSet { save("snoozedUntil", snoozedUntil) } }
    /// Lifetime stats.
    @Published var totalWhips: Int { didSet { save("totalWhips", totalWhips) } }
    @Published var longestStreakSeconds: TimeInterval { didSet { save("longestStreakSeconds", longestStreakSeconds) } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func get<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "whiplash." + key) as? T ?? fallback }
        thresholdSeconds = get("workThresholdSeconds", 50 * 60)
        breakSeconds = get("breakSeconds", 5 * 60)
        repeatSeconds = get("repeatSeconds", 20 * 60)
        nudgeSeconds = get("nudgeSeconds", 2 * 60)
        stepAwaySeconds = get("stepAwaySeconds", 45)
        terminalRecencySeconds = get("terminalRecencySeconds", 10 * 60)
        idlePauseSeconds = get("idlePauseSeconds", 60)
        enabled = get("enabled", true)
        soundEnabled = get("soundEnabled", true)
        useScreenCapture = get("useScreenCapture", true)
        intensity = get("intensity", 1.0)
        escalate = get("escalate", true)
        terminalBundleIDs = get("terminalBundleIDs", Settings.defaultTerminalBundleIDs)
        islandPlacement = IslandPlacement(rawValue: get("islandPlacement", IslandPlacement.aroundNotch.rawValue)) ?? .aroundNotch
        snoozedUntil = get("snoozedUntil", nil as Date?)
        totalWhips = get("totalWhips", 0)
        longestStreakSeconds = get("longestStreakSeconds", 0)
    }

    var isSnoozed: Bool {
        guard let until = snoozedUntil else { return false }
        return until > Date()
    }

    private func save(_ key: String, _ value: Any?) {
        if let value { defaults.set(value, forKey: "whiplash." + key) } else { defaults.removeObject(forKey: "whiplash." + key) }
    }
}
