import CoreGraphics

/// Pulling the whip out of the island's right end: press there and drag. Once the cursor is `distance` from the press,
/// the whip is out; letting go sooner (a click) does nothing.
struct WhipPull {
    /// How far the cursor must travel from the press before the whip comes out, points.
    static let distance: CGFloat = 8

    private var start: CGPoint?

    /// The button is down on the whip and it isn't out yet.
    var isHolding: Bool { start != nil }

    /// A press at `point`; true when it grabs the whip, i.e. lands on `zone` (nil: there's no whip to grab now).
    mutating func press(at point: CGPoint, in zone: CGRect?) -> Bool {
        start = zone?.contains(point) == true ? point : nil
        return start != nil
    }

    /// The cursor dragged to `point`. True once, when it has pulled far enough: the whip is out.
    mutating func drag(to point: CGPoint) -> Bool {
        guard let start, hypot(point.x - start.x, point.y - start.y) >= Self.distance else { return false }
        self.start = nil
        return true
    }

    /// Let go before the whip came out.
    mutating func release() {
        start = nil
    }
}
