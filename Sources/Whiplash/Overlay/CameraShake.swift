import CoreGraphics
import Foundation

/// Trauma-based screen shake with an impact "punch" zoom.
///
/// Impacts add trauma (0...1) that decays linearly; the visible shake is trauma², so small hits barely move
/// the picture while big ones slam it. Motion comes from a sum of sines with random phases rather than per-frame
/// noise, which keeps it smooth at 120 Hz and identical at any frame rate.
struct CameraShake {
    struct Profile: Equatable {
        /// Peak camera offset in points.
        var maxOffset: CGFloat
        /// Peak camera rotation in radians.
        var maxRotation: CGFloat
        /// Peak punch zoom (0.03 = 3 % closer).
        var maxZoom: CGFloat

        /// The overlay shows a screenshot over a black bezel: the whole "screen" may shake hard.
        static func backdrop(intensity: CGFloat) -> Profile {
            let k = scale(for: intensity)
            return Profile(maxOffset: 22 * k, maxRotation: 0.012 * k, maxZoom: 0.028 * k)
        }

        /// The overlay is transparent over the live screen: only our own drawing moves, so keep it subtle and
        /// never zoom (that would slide the cracks off the pixels they belong to).
        static func glass(intensity: CGFloat) -> Profile {
            let k = scale(for: intensity)
            return Profile(maxOffset: 5 * k, maxRotation: 0.0025 * k, maxZoom: 0)
        }

        private static func scale(for intensity: CGFloat) -> CGFloat {
            0.65 + 0.35 * min(2, max(0.5, intensity))
        }
    }

    struct Pose: Equatable {
        var offset: CGVector
        var rotation: CGFloat
        /// Camera scale: < 1 zooms in.
        var scale: CGFloat

        static let rest = Pose(offset: .zero, rotation: 0, scale: 1)
    }

    let profile: Profile
    private var trauma: CGFloat = 0
    private var punch: CGFloat = 0
    private var time: Double = 0
    private let phases: [Double]

    /// Trauma lost per second.
    private static let traumaDecay: CGFloat = 1.5
    /// Punch zoom decays exponentially at this rate (1/s).
    private static let punchDecay: Double = 11
    private static let frequencies: (low: Double, high: Double) = (13, 23.7)

    init(profile: Profile, seed: UInt64) {
        self.profile = profile
        var rng = OverlayRandom(seed: seed)
        phases = (0..<6).map { _ in Double.random(in: 0..<(2 * .pi), using: &rng) }
    }

    mutating func add(trauma amount: CGFloat) {
        trauma = min(1, trauma + max(0, amount))
    }

    mutating func addPunch(_ amount: CGFloat) {
        punch = min(1, max(punch, amount))
    }

    /// Advances the shake and returns where the camera should be relative to rest.
    mutating func step(dt: TimeInterval) -> Pose {
        time += dt
        trauma = max(0, trauma - Self.traumaDecay * CGFloat(dt))
        punch *= CGFloat(exp(-Self.punchDecay * dt))
        if punch < 0.001 { punch = 0 }
        let shake = trauma * trauma
        return Pose(offset: CGVector(dx: profile.maxOffset * shake * wave(0), dy: profile.maxOffset * shake * wave(2)),
                    rotation: profile.maxRotation * shake * wave(4),
                    scale: 1 - profile.maxZoom * punch)
    }

    /// Smooth pseudo-noise in -1...1 built from two detuned sines.
    private func wave(_ channel: Int) -> CGFloat {
        let f = Self.frequencies
        let value = 0.62 * sin(2 * .pi * f.low * time + phases[channel])
            + 0.38 * sin(2 * .pi * f.high * time + phases[channel + 1])
        return CGFloat(value)
    }
}
