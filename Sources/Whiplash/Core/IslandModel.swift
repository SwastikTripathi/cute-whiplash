import Combine
import Foundation

/// The contract between AppCoordinator (which fills in state and wires the actions)
/// and the notch island UI (which only reads state and calls actions).
final class IslandModel: ObservableObject {
    // MARK: State (written by AppCoordinator on the main thread)
    @Published var phase: IslandPhase = .idle
    /// Name of the terminal app currently frontmost ("kitty"), nil when not in a terminal.
    @Published var terminalName: String?
    /// Current unbroken terminal streak, seconds.
    @Published var streakSeconds: TimeInterval = 0
    /// The streak is growing right now (a terminal is frontmost and the user is active). While it is not — the user
    /// went idle, left, or locked the screen — the closed island holds a furious Lash still, so it costs nothing.
    @Published var streakAdvancing = false
    @Published var thresholdSeconds: TimeInterval = 50 * 60
    /// How many times the user has been whipped today / ever.
    @Published var whipsToday: Int = 0
    @Published var totalWhips: Int = 0
    @Published var longestStreakSeconds: TimeInterval = 0
    /// 0 for the first punishment of a streak, +1 for each repeat.
    @Published var escalationLevel: Int = 0
    @Published var screenCaptureGranted = false
    /// Screen Recording was asked for, the user has been to System Settings, and the grant still isn't visible.
    /// macOS may only apply it to a fresh process, so the island offers a relaunch instead of "Enable".
    @Published var screenCaptureRelaunchOffered = false
    @Published var soundEnabled = true
    @Published var autoWhipEnabled = true
    /// A transient speech-bubble line from the critter. Coordinator or UI may set it; UI clears it after a few seconds.
    @Published var quip: String?
    /// The glass just shattered: the whipping island laughs its hardest for a moment ("BWAHAHA").
    @Published var laughingHard = false
    /// The break after the shatter: seconds until the screen comes back (nil when there's no break on), and what Lash
    /// has to say about it. The whipping island shows both.
    @Published var breakSecondsLeft: Int?
    @Published var breakTaunt: String?

    /// 0...1 progress of the streak toward the threshold.
    var progress: Double {
        guard thresholdSeconds > 0 else { return 0 }
        return min(1, max(0, streakSeconds / thresholdSeconds))
    }

    var secondsRemaining: TimeInterval { max(0, thresholdSeconds - streakSeconds) }

    var mood: CritterMood {
        switch phase {
        case .whipping, .manual: return .maniacal
        case .aftermath: return .smug
        case .snoozed, .disabled: return .sleepy
        case .warning: return .furious
        case .nudge: return .suspicious
        case .idle: return streakSeconds < 1 ? .happy : CritterMood.forProgress(progress)
        }
    }

    // MARK: Actions (wired by AppCoordinator; UI calls them)
    var onWhipNow: () -> Void = {}
    var onGrabWhip: () -> Void = {}
    var onSnooze: (TimeInterval) -> Void = { _ in }
    var onResume: () -> Void = {}
    /// Reset the work timer and call off any nudge or countdown ("Spare me this once").
    var onSpareOnce: () -> Void = {}
    var onToggleSound: () -> Void = {}
    var onToggleAutoWhip: () -> Void = {}
    var onRequestScreenCapture: () -> Void = {}
    /// Quit and reopen, so macOS applies a Screen Recording grant (see `screenCaptureRelaunchOffered`).
    var onRelaunch: () -> Void = {}
    var onSetThreshold: (TimeInterval) -> Void = { _ in }
    var onQuit: () -> Void = {}
}
