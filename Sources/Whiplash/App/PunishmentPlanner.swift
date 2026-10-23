import CoreGraphics
import Foundation

/// Turns the user's settings and track record into a PunishmentPlan.
enum PunishmentPlanner {
    /// The enforced break: how long the screen stays broken once the shards have fallen, counting down in the island.
    static let holdSeconds: TimeInterval = 10
    static let maxStrikes = 6

    /// `min(6, 2 + level)` strikes, scaled by the chaos multiplier: gentle (0.5) halves them, unhinged (2) doubles.
    static func strikeCount(escalationLevel: Int, intensity: Double) -> Int {
        let base = min(maxStrikes, 2 + max(0, escalationLevel))
        let scaled = Int((Double(base) * min(2, max(0.5, intensity))).rounded())
        return min(maxStrikes, max(1, scaled))
    }

    /// - Parameters:
    ///   - targetRect: what to aim at, Cocoa global (usually the frontmost terminal window).
    ///   - backdrop: screenshot of the punished screen, nil for glass mode.
    static func plan(escalationLevel: Int, settings: Settings, targetRect: CGRect?, backdrop: ScreenSnapshot?,
                     message: String, isManual: Bool = false) -> PunishmentPlan {
        var plan = PunishmentPlan()
        plan.strikes = strikeCount(escalationLevel: settings.escalate ? escalationLevel : 0, intensity: settings.intensity)
        plan.shatter = true
        plan.targetRect = targetRect
        plan.backdrop = backdrop
        plan.holdSeconds = holdSeconds
        plan.message = message
        plan.isManual = isManual
        plan.intensity = CGFloat(min(2, max(0.5, settings.intensity)))
        return plan
    }
}
