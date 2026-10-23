import CoreGraphics
import Foundation

/// 2-D vector used by the FX geometry. A module-owned type (rather than operators on CGPoint or extensions
/// on SIMD2) so nothing here can collide with helpers other modules add to the same target.
struct FXVec: Hashable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    init(_ point: CGPoint) { x = Double(point.x); y = Double(point.y) }

    static let zero = FXVec(0, 0)

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    var length: Double { (x * x + y * y).squareRoot() }
    var normalized: FXVec { let l = length; return l > 1e-12 ? self / l : .zero }
    /// Rotated 90° counter-clockwise.
    var perpendicular: FXVec { FXVec(-y, x) }
    var angle: Double { atan2(y, x) }
    static func polar(_ angle: Double, _ radius: Double = 1) -> FXVec { FXVec(cos(angle) * radius, sin(angle) * radius) }
    func distance(to other: FXVec) -> Double { (self - other).length }
    func dot(_ other: FXVec) -> Double { x * other.x + y * other.y }
    func cross(_ other: FXVec) -> Double { x * other.y - y * other.x }

    static func + (a: FXVec, b: FXVec) -> FXVec { FXVec(a.x + b.x, a.y + b.y) }
    static func - (a: FXVec, b: FXVec) -> FXVec { FXVec(a.x - b.x, a.y - b.y) }
    static func * (a: FXVec, k: Double) -> FXVec { FXVec(a.x * k, a.y * k) }
    static func / (a: FXVec, k: Double) -> FXVec { FXVec(a.x / k, a.y / k) }
    static func += (a: inout FXVec, b: FXVec) { a = a + b }

    static func min(_ a: FXVec, _ b: FXVec) -> FXVec { FXVec(Swift.min(a.x, b.x), Swift.min(a.y, b.y)) }
    static func max(_ a: FXVec, _ b: FXVec) -> FXVec { FXVec(Swift.max(a.x, b.x), Swift.max(a.y, b.y)) }
}

/// Deterministic, seedable generator (SplitMix64): demos and tests replay exactly.
struct FXRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed ^ 0x2545_F491_4F6C_DD1D }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func range(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * unit() }
    /// Uniform in [-1, 1).
    mutating func signed() -> Double { unit() * 2 - 1 }
    mutating func chance(_ p: Double) -> Bool { unit() < p }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    /// A random sign, ±1.
    mutating func sign() -> Double { next() & 1 == 0 ? 1 : -1 }
}

/// Easing curves on a 0...1 parameter.
enum FXEase {
    static func clamp01(_ t: Double) -> Double { min(max(t, 0), 1) }
    static func outCubic(_ t: Double) -> Double { let u = 1 - clamp01(t); return 1 - u * u * u }
    static func inQuad(_ t: Double) -> Double { let u = clamp01(t); return u * u }
    static func inOutCubic(_ t: Double) -> Double {
        let u = clamp01(t)
        return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }
    /// Ease-in-out that overshoots the target by a few percent before settling (the rewind's springy landing).
    static func inOutBack(_ t: Double, overshoot: Double = 0.9) -> Double {
        let u = clamp01(t)
        let c = overshoot * 1.525
        return u < 0.5
            ? (pow(2 * u, 2) * ((c + 1) * 2 * u - c)) / 2
            : (pow(2 * u - 2, 2) * ((c + 1) * (u * 2 - 2) + c) + 2) / 2
    }
    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// Everything about a moving piece that the rewind has to restore.
struct FXPose {
    var position: FXVec
    var rotation: Double = 0
    var scale: Double = 1
    /// Squash along the local y axis: |cos| of a flip around the piece's own x axis (fake 3-D tumble).
    var flip: Double = 1
    var alpha: Double = 1
    /// 0 = original colours, 1 = black (deep in the screen, or a piece showing its back).
    var darkness: Double = 0

    /// Interpolates with separate curves for motion (may overshoot) and for colour/alpha (must not).
    static func blend(_ a: FXPose, _ b: FXPose, motion t: Double, fade f: Double) -> FXPose {
        FXPose(position: a.position + (b.position - a.position) * t,
               rotation: FXEase.lerp(a.rotation, b.rotation, t),
               scale: FXEase.lerp(a.scale, b.scale, t),
               flip: FXEase.lerp(a.flip, b.flip, FXEase.clamp01(t)),
               alpha: FXEase.lerp(a.alpha, b.alpha, f),
               darkness: FXEase.lerp(a.darkness, b.darkness, f))
    }
}

/// How pieces recede "into" the screen: perspective scale for a fall of normalized time u (0...1).
/// Depth grows like gravity, and apparent size is focal/(focal + depth); tuned so u = 1 lands at ~3 %.
enum FXDepth {
    static let finalScale = 0.03

    static func scale(_ u: Double) -> Double {
        let depth = pow(FXEase.clamp01(u), 2.4)
        return 1 / (1 + (1 / finalScale - 1) * depth)
    }

    /// Brightness left at a given perspective scale: far away things sink into darkness.
    static func brightness(atScale s: Double) -> Double { pow(max(s, 0), 0.42) }
}

/// Polygon helpers (arrays of points; convex ones are counter-clockwise).
enum FXPolygon {
    /// Signed area (positive = counter-clockwise).
    static func signedArea(_ p: [FXVec]) -> Double {
        guard p.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<p.count { a += p[i].cross(p[(i + 1) % p.count]) }
        return a / 2
    }

    static func centroid(_ p: [FXVec]) -> FXVec {
        let a = signedArea(p)
        guard abs(a) > 1e-9 else { return p.reduce(FXVec.zero, +) / Double(max(p.count, 1)) }
        var c = FXVec.zero
        for i in 0..<p.count {
            let q = p[i], r = p[(i + 1) % p.count]
            c += (q + r) * q.cross(r)
        }
        return c / (6 * a)
    }

    static func bounds(_ p: [FXVec]) -> CGRect {
        guard let first = p.first else { return .null }
        var lo = first, hi = first
        for q in p { lo = .min(lo, q); hi = .max(hi, q) }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    /// Point-in-polygon for convex CCW polygons.
    static func convexContains(_ p: [FXVec], _ q: FXVec) -> Bool {
        guard p.count >= 3 else { return false }
        for i in 0..<p.count where (p[(i + 1) % p.count] - p[i]).cross(q - p[i]) < -1e-9 { return false }
        return true
    }

    static func path(_ p: [FXVec], offset: FXVec = .zero) -> CGPath {
        let path = CGMutablePath()
        guard let first = p.first else { return path }
        path.move(to: (first - offset).cgPoint)
        for q in p.dropFirst() { path.addLine(to: (q - offset).cgPoint) }
        path.closeSubpath()
        return path
    }
}

/// Segment helpers for the crack random walks.
enum FXSegment {
    /// Intersection parameter t along a→b where it crosses c→d (both segments proper), or nil.
    static func intersection(_ a: FXVec, _ b: FXVec, _ c: FXVec, _ d: FXVec) -> Double? {
        let r = b - a, s = d - c
        let denom = r.cross(s)
        guard abs(denom) > 1e-12 else { return nil }
        let t = (c - a).cross(s) / denom
        let u = (c - a).cross(r) / denom
        guard t > 1e-6, t <= 1, u >= 0, u <= 1 else { return nil }
        return t
    }

    /// Clips the segment a→b to `rect`; returns the parameter where it leaves, or nil if b is inside.
    static func exitParameter(_ a: FXVec, _ b: FXVec, rect: CGRect) -> Double? {
        let inside = { (p: FXVec) in p.x >= rect.minX && p.x <= rect.maxX && p.y >= rect.minY && p.y <= rect.maxY }
        guard !inside(b) else { return nil }
        var t = 1.0
        let d = b - a
        if d.x > 0, b.x > rect.maxX { t = min(t, (rect.maxX - a.x) / d.x) }
        if d.x < 0, b.x < rect.minX { t = min(t, (rect.minX - a.x) / d.x) }
        if d.y > 0, b.y > rect.maxY { t = min(t, (rect.maxY - a.y) / d.y) }
        if d.y < 0, b.y < rect.minY { t = min(t, (rect.minY - a.y) / d.y) }
        return max(0, t)
    }
}

/// Work started on a background queue whose result the frame loop collects later, blocking only if it is late.
/// A group and a lock rather than `DispatchQueue.main.async`, because a headless render loop never drains the main
/// queue — and so demos stay deterministic: the frame that collects the result is fixed by the scene's clock.
final class FXBackground<Value> {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var value: Value?

    init(_ work: @escaping () -> Value) {
        group.enter()
        DispatchQueue.global(qos: .userInteractive).async {
            let result = work()
            self.lock.lock()
            self.value = result
            self.lock.unlock()
            self.group.leave()
        }
    }

    /// Finished (never blocks).
    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != nil
    }

    /// The result, waiting for it if needed.
    func wait() -> Value {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        guard let value else { preconditionFailure("background work finished without a result") }
        return value
    }
}
