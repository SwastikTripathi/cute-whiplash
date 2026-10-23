import Foundation

/// Deterministic PRNG (SplitMix64) so every SFX variant renders the same samples on every launch.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// One sample of uniform white noise in -1..<1.
    mutating func noise() -> Float {
        Float(next() >> 40) / Float(1 << 23) - 1
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    /// Log-uniform pick, so e.g. 2–9 kHz tinkles spread evenly across octaves rather than bunching up high.
    mutating func logUniform(_ range: ClosedRange<Double>) -> Double {
        exp(uniform(log(range.lowerBound)...log(range.upperBound)))
    }
}

/// RBJ-cookbook biquad in transposed direct form II. Retuning keeps the filter state, so sweeps are click-free.
struct Biquad {
    enum Kind { case lowPass, highPass, bandPass }

    private var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    init(_ kind: Kind, frequency: Double, q: Double = 0.7071, sampleRate: Double) {
        retune(kind, frequency: frequency, q: q, sampleRate: sampleRate)
    }

    /// `bandPass` has a constant 0 dB peak gain.
    mutating func retune(_ kind: Kind, frequency: Double, q: Double = 0.7071, sampleRate: Double) {
        let f = min(max(frequency, 10), sampleRate * 0.45)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let (n0, n1, n2): (Double, Double, Double)
        switch kind {
        case .lowPass: (n0, n1, n2) = ((1 - cosW) / 2, 1 - cosW, (1 - cosW) / 2)
        case .highPass: (n0, n1, n2) = ((1 + cosW) / 2, -(1 + cosW), (1 + cosW) / 2)
        case .bandPass: (n0, n1, n2) = (alpha, 0, -alpha)
        }
        b0 = Float(n0 / a0)
        b1 = Float(n1 / a0)
        b2 = Float(n2 / a0)
        a1 = Float(-2 * cosW / a0)
        a2 = Float((1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Sample-buffer helpers shared by the SFX recipes.
enum DSP {
    static func samples(_ seconds: Double, _ sampleRate: Double) -> Int {
        max(0, Int((seconds * sampleRate).rounded()))
    }

    static func peak(_ x: [Float]) -> Float {
        x.reduce(0) { max($0, abs($1)) }
    }

    /// Scales `x` so its loudest sample is exactly `target` (no-op on silence).
    static func normalize(_ x: inout [Float], to target: Float) {
        let p = peak(x)
        guard p > 0 else { return }
        let gain = target / p
        for i in x.indices { x[i] *= gain }
    }

    /// Raised-cosine fade to zero over the last `seconds`, so buffers never end on a click.
    static func fadeOut(_ x: inout [Float], seconds: Double, sampleRate: Double) {
        let n = min(x.count, samples(seconds, sampleRate))
        guard n > 1 else { return }
        for i in 0..<n {
            let g = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n - 1))
            x[x.count - 1 - i] *= Float(g)
        }
    }

    /// Smooth 0→1→0 envelope: sin² rise to `peakAt` (0...1 of the length), cos² fall after it.
    static func swell(_ x: Double, peakAt: Double) -> Double {
        if x <= 0 || x >= 1 { return 0 }
        if x < peakAt { return pow(sin(Double.pi / 2 * x / peakAt), 2) }
        return pow(cos(Double.pi / 2 * (x - peakAt) / (1 - peakAt)), 2)
    }

    /// Adds an exponentially decaying sine (a ping, a mode of a struck object) starting at sample `start`.
    static func addPing(_ x: inout [Float], at start: Int, frequency: Double, amplitude: Float, decay tau: Double,
                        attack: Double = 0.0003, sampleRate: Double) {
        guard start >= 0, start < x.count, frequency < sampleRate * 0.45 else { return }
        let length = min(x.count - start, samples(tau * 7, sampleRate))
        let w = 2 * Double.pi * frequency / sampleRate
        let fall = exp(-1 / (tau * sampleRate))
        let attackSamples = max(1, attack * sampleRate)
        var env = 1.0
        for i in 0..<length {
            let rise = min(1, Double(i) / attackSamples)
            x[start + i] += amplitude * Float(env * rise * sin(w * Double(i)))
            env *= fall
        }
    }

    /// Low-passed copies of the signal at short delays: a hint of room, so dry clicks feel like they happen *somewhere*.
    static func addReflections(_ x: inout [Float], taps: [(delay: Double, gain: Float)], lowPass: Double, sampleRate: Double) {
        let dry = x
        for tap in taps {
            let d = samples(tap.delay, sampleRate)
            guard d < x.count else { continue }
            var filter = Biquad(.lowPass, frequency: lowPass, sampleRate: sampleRate)
            for i in 0..<(x.count - d) { x[i + d] += tap.gain * filter.process(dry[i]) }
        }
    }
}
