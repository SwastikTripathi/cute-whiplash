import Foundation

/// The letters one hit knocks loose: a patch around the impact, wider than tall (text runs in lines), with a ragged,
/// soft edge — near the impact everything goes, towards the edge fewer and fewer letters do, and how far the patch
/// reaches wobbles with the direction, so it never reads as a stamped-out circle.
///
/// Pure value: which letters a patch takes depends only on the patch and the letter's index, so dropping it again
/// later (text that arrives after the hit) takes exactly the letters the hit would have taken.
struct LetterPatch {
    let center: FXVec
    /// Half-width and half-height of the patch's nominal edge, points.
    let radii: FXVec
    let seed: UInt64
    /// Harmonics of the edge's wobble: (frequency, amplitude, phase).
    private let wobble: [(Double, Double, Double)]

    enum Tuning {
        /// Patch radius (geometric mean of the half-axes) for a firm hit, and for the hardest one.
        static let radius = 170.0...280.0
        /// Intensities that map onto `radius`; weaker hits (a soft flick, the glass creaking) knock out less.
        static let intensity = 0.6...1.8
        /// Half-width : half-height.
        static let aspect = 1.55
        /// Inside this share of the edge every letter goes; beyond it the odds fall to zero at the edge.
        static let solidCore = 0.5
    }

    /// Patch radius for a crack of `intensity` (DestructionLayer's scale, 0.2...2).
    static func radius(intensity: Double) -> Double {
        let lo = Tuning.intensity.lowerBound, hi = Tuning.intensity.upperBound
        if intensity < lo { return Tuning.radius.lowerBound * pow(max(intensity, 0.05) / lo, 0.8) }
        let u = FXEase.clamp01((intensity - lo) / (hi - lo))
        return FXEase.lerp(Tuning.radius.lowerBound, Tuning.radius.upperBound, u)
    }

    init(center: FXVec, intensity: Double, seed: UInt64) {
        self.center = center
        let radius = Self.radius(intensity: intensity)
        let stretch = Tuning.aspect.squareRoot()
        radii = FXVec(radius * stretch, radius / stretch)
        self.seed = seed
        var rng = FXRandom(seed: seed)
        wobble = [(3, 0.14, rng.unit() * 2 * .pi), (5, 0.09, rng.unit() * 2 * .pi), (9, 0.05, rng.unit() * 2 * .pi)]
    }

    private init(center: FXVec, radii: FXVec, seed: UInt64, wobble: [(Double, Double, Double)]) {
        self.center = center
        self.radii = radii
        self.seed = seed
        self.wobble = wobble
    }

    /// The same patch (same ragged edge, same letter lottery), `factor` times as big.
    func scaled(by factor: Double) -> LetterPatch {
        LetterPatch(center: center, radii: radii * factor, seed: seed, wobble: wobble)
    }

    /// Where `p` lies: 0 at the impact, 1 on the patch's (wobbly) edge.
    func reach(of p: FXVec) -> Double {
        let d = FXVec((p.x - center.x) / radii.x, (p.y - center.y) / radii.y)
        let angle = d.angle
        let edge = wobble.reduce(1.0) { $0 + $1.1 * sin($1.0 * angle + $1.2) }
        return d.length / edge
    }

    /// Odds that a letter centred at `p` comes loose.
    func chance(at p: FXVec) -> Double {
        1 - FXEase.smoothstep(Tuning.solidCore, 1, reach(of: p))
    }

    /// Whether the letter with this index, centred at `p`, comes loose (the same answer every time it is asked).
    func takes(_ index: Int, at p: FXVec) -> Bool {
        let odds = chance(at: p)
        guard odds > 0 else { return false }
        return odds >= 1 || Self.unit(seed ^ UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15) < odds
    }

    /// Bounding box of everything the patch can take.
    var bounds: CGRect {
        let reach = wobble.reduce(1.0) { $0 + abs($1.1) }
        return CGRect(x: center.x - radii.x * reach, y: center.y - radii.y * reach, width: 2 * radii.x * reach,
                      height: 2 * radii.y * reach)
    }

    /// A well-mixed uniform number in [0, 1) from a key.
    private static func unit(_ key: UInt64) -> Double {
        var rng = FXRandom(seed: key)
        return rng.unit()
    }
}
