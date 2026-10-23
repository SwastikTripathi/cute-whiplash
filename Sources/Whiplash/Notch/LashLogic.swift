import CoreGraphics
import Foundation

/// Counts pokes; enough of them in a short window makes Lash dizzy.
struct PokeCounter {
    /// Pokes needed inside `window` seconds.
    private let threshold = 5
    private let window: TimeInterval = 2
    private var times: [TimeInterval] = []

    /// Records a poke at `time` (seconds, any monotonic clock). Returns true when this poke tips Lash into
    /// dizziness; the count then starts over.
    mutating func poke(at time: TimeInterval) -> Bool {
        times.removeAll { time - $0 > window }
        times.append(time)
        guard times.count >= threshold else { return false }
        times.removeAll()
        return true
    }
}

/// Detects petting: the cursor rubbing quickly back and forth over Lash.
///
/// Feed it the horizontal cursor position while the cursor is over Lash. A "stroke" is a run of movement in one
/// direction at least `minStroke` long; `strokesNeeded` direction reversals within `window` seconds count as petting.
struct PetDetector {
    private let minStroke: CGFloat = 7
    private let strokesNeeded = 4
    private let window: TimeInterval = 1.4
    /// After a detection, stay quiet this long so one rub doesn't fire repeatedly.
    private let cooldown: TimeInterval = 1.2

    private var anchorX: CGFloat?
    private var lastX: CGFloat = 0
    private var direction: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var quietUntil: TimeInterval = -.infinity

    /// Returns true when this sample completes a petting gesture.
    mutating func feed(x: CGFloat, at time: TimeInterval) -> Bool {
        guard let anchor = anchorX else {
            anchorX = x
            lastX = x
            return false
        }
        let step = x - lastX
        lastX = x
        if step == 0 { return false }
        let heading: CGFloat = step > 0 ? 1 : -1
        if direction == 0 {
            if abs(x - anchor) >= minStroke { direction = heading; anchorX = x }
            return false
        }
        if heading == direction {
            // The stroke keeps going: remember its far end.
            anchorX = direction > 0 ? max(anchor, x) : min(anchor, x)
            return false
        }
        // Moving against the current stroke: it only counts once it is a real stroke, not jitter.
        guard abs(x - anchor) >= minStroke else { return false }
        direction = heading
        anchorX = x
        reversals.removeAll { time - $0 > window }
        reversals.append(time)
        guard time >= quietUntil, reversals.count >= strokesNeeded else { return false }
        reversals.removeAll()
        quietUntil = time + cooldown
        return true
    }

    /// The cursor left Lash: forget the current rub.
    mutating func reset() {
        anchorX = nil
        direction = 0
        reversals.removeAll()
    }
}

/// Where Lash's pupils point.
enum Gaze {
    /// Beyond this distance (points) the pupils sit at the edge of the eye; closer, they ease toward the centre so
    /// Lash looks *at* a cursor hovering right over it.
    static let fullDeflectionDistance: CGFloat = 90

    /// Pupil deflection for eyes at `eye` looking at `target` (same coordinate space, y down).
    /// The result has length ≤ 1; (0, 0) means straight ahead.
    static func vector(from eye: CGPoint, to target: CGPoint) -> CGVector {
        let dx = target.x - eye.x, dy = target.y - eye.y
        let distance = hypot(dx, dy)
        guard distance > 0.5 else { return .zero }
        let reach = min(1, distance / fullDeflectionDistance)
        return CGVector(dx: dx / distance * reach, dy: dy / distance * reach)
    }

    /// Snaps a gaze to a coarse grid so tiny cursor moves don't redraw Lash.
    static func quantized(_ v: CGVector, step: CGFloat = 0.05) -> CGVector {
        CGVector(dx: (v.dx / step).rounded() * step, dy: (v.dy / step).rounded() * step)
    }
}

/// Head pats: a hand moving across Lash's head. A pat lands for every `travel` points the cursor moves over the
/// head, at most every `interval` seconds. A cursor resting on the head (or just arriving there) doesn't pat.
struct PatDetector {
    let travel: CGFloat = 10
    let interval: TimeInterval = 0.28
    private var lastPoint: CGPoint?
    private var moved: CGFloat = 0
    private var lastPat: TimeInterval = -.infinity

    /// The cursor is at `point`, on the head. Returns true when a pat lands.
    mutating func feed(_ point: CGPoint, at time: TimeInterval) -> Bool {
        defer { lastPoint = point }
        guard let lastPoint else { return false }
        moved += hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        guard moved >= travel, time - lastPat >= interval else { return false }
        moved = 0
        lastPat = time
        return true
    }

    /// The cursor left the head.
    mutating func reset() {
        lastPoint = nil
        moved = 0
    }
}

/// Where the parts of Lash are, for the interactions that care.
enum LashAnatomy {
    /// The top of the head, ears included, inside the figure's frame `lash` (panel space, y down): the spot to pat.
    static func headRect(in lash: CGRect) -> CGRect {
        CGRect(x: lash.minX + lash.width * 0.14, y: lash.minY - lash.height * 0.08,
               width: lash.width * 0.72, height: lash.height * 0.5)
    }
}
