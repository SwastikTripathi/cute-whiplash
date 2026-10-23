import Foundation

/// Counts whips per calendar day, persisted as `whiplash.whipsToday` plus the day it counts
/// (`whiplash.whipsTodayDate`). A new day starts from zero without anyone having to reset it.
final class WhipTally {
    static let countKey = "whiplash.whipsToday"
    static let dayKey = "whiplash.whipsTodayDate"

    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date

    init(defaults: UserDefaults, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
    }

    /// Whips so far today.
    var today: Int {
        guard let day = defaults.object(forKey: Self.dayKey) as? Date, calendar.isDate(day, inSameDayAs: now()) else {
            return 0
        }
        return defaults.integer(forKey: Self.countKey)
    }

    /// Records one more whip today and returns the new count.
    @discardableResult
    func increment() -> Int {
        let count = today + 1
        defaults.set(count, forKey: Self.countKey)
        defaults.set(now(), forKey: Self.dayKey)
        return count
    }
}
