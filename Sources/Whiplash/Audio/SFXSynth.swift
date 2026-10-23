import AVFoundation

/// Procedural recipes for every `SFX`. Pure and deterministic: the same (sfx, variant, rate) always renders
/// the same samples. Output is mono, normalized to `targetPeak`, and fades out cleanly.
///
/// Each sound has `variantCount` variants (different seeds and tuning) so rapid repeats don't sound robotic.
enum SFXSynth {
    static let sampleRate: Double = 48_000
    static let variantCount = 3
    /// Loudest sample of every rendered sound; leaves headroom so a single voice never clips.
    static let targetPeak: Float = 0.89

    static func render(_ sfx: SFX, variant: Int, sampleRate sr: Double = sampleRate) -> [Float] {
        let v = ((variant % variantCount) + variantCount) % variantCount
        let index = UInt64(SFX.allCases.firstIndex(of: sfx) ?? 0)
        var rng = SplitMix64(seed: 0x5F3_7A11 &+ index &* 7_919 &+ UInt64(v) &* 104_729)
        var samples: [Float]
        switch sfx {
        case .whoosh: samples = whoosh(v, sr, &rng)
        case .crack: samples = crack(v, sr, &rng)
        case .glassCrack: samples = glassCrack(v, sr, &rng)
        case .shatter: samples = shatter(v, sr, &rng)
        case .tinkle: samples = tinkle(v, sr)
        case .buzz: samples = buzz(v, sr, &rng)
        case .reassemble: samples = reassemble(v, sr, &rng)
        case .boop: samples = boop(v, sr)
        case .giggle: samples = giggle(v, sr, &rng)
        case .tick: samples = tick(v, sr, &rng)
        case .alarm: samples = alarm(v, sr)
        case .pat: samples = pat(v, sr, &rng)
        case .purr: samples = purr(v, sr, &rng)
        case .wheee: samples = wheee(v, sr)
        }
        DSP.normalize(&samples, to: targetPeak)
        // Reassemble ends on the (reversed) impact: keep that final snap crisp.
        DSP.fadeOut(&samples, seconds: sfx == .reassemble ? 0.0015 : 0.005, sampleRate: sr)
        return samples
    }

    /// Every variant of every sound as ready-to-schedule mono buffers.
    static func library(sampleRate: Double = sampleRate) -> [SFX: [AVAudioPCMBuffer]] {
        var library: [SFX: [AVAudioPCMBuffer]] = [:]
        for sfx in SFX.allCases {
            library[sfx] = (0..<variantCount).compactMap { .mono(render(sfx, variant: $0, sampleRate: sampleRate), sampleRate: sampleRate) }
        }
        return library
    }

    // MARK: - Whip

    /// Band-passed noise sweeping upward as the tip accelerates, swelling to a peak just before the crack.
    private static func whoosh(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let p = [(dur: 0.36, from: 320.0, to: 2_600.0, q: 1.5, peakAt: 0.66, flutter: 31.0),
                 (dur: 0.40, from: 260.0, to: 2_100.0, q: 1.2, peakAt: 0.70, flutter: 26.0),
                 (dur: 0.32, from: 380.0, to: 3_100.0, q: 1.9, peakAt: 0.62, flutter: 37.0)][v]
        let n = DSP.samples(p.dur, sr)
        var out = [Float](repeating: 0, count: n)
        // Two cascaded band-passes per layer: a single one lets white noise hiss through its gentle skirts and
        // the sweep disappears; 4th order keeps a clear "whooo" band that audibly rises.
        var body = [Biquad](repeating: Biquad(.bandPass, frequency: p.from, q: p.q, sampleRate: sr), count: 2)
        var air = [Biquad](repeating: Biquad(.bandPass, frequency: p.from * 2.2, q: p.q * 1.6, sampleRate: sr), count: 2)
        for i in 0..<n {
            let x = Double(i) / Double(n)
            if i % 32 == 0 {
                let f = p.from * pow(p.to / p.from, pow(x, 1.4))
                for k in 0..<2 {
                    body[k].retune(.bandPass, frequency: f, q: p.q, sampleRate: sr)
                    air[k].retune(.bandPass, frequency: f * 2.2, q: p.q * 1.6, sampleRate: sr)
                }
            }
            // A light flutter, like a rope spinning through the air.
            let flutter = 1 + 0.12 * sin(2 * Double.pi * p.flutter * Double(i) / sr)
            let gain = Float(DSP.swell(x, peakAt: p.peakAt) * flutter)
            let low = body[1].process(body[0].process(rng.noise()))
            let high = air[1].process(air[0].process(rng.noise()))
            out[i] = gain * (low + 0.4 * high)
        }
        return out
    }

    /// A bullwhip crack: the tip's sonic boom (an N-wave a couple of ms long), a burst of torn air that dies
    /// almost instantly, a faint low thump, and two quick room reflections. Gently saturated for cartoon punch.
    private static func crack(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let p = [(click: 0.0024, burst: 0.045, tau: 0.0085, highPass: 2_200.0, thump: 82.0),
                 (click: 0.0019, burst: 0.036, tau: 0.0065, highPass: 2_800.0, thump: 76.0),
                 (click: 0.0029, burst: 0.058, tau: 0.0110, highPass: 1_800.0, thump: 88.0)][v]
        var out = [Float](repeating: 0, count: DSP.samples(0.16, sr))

        let clickLength = DSP.samples(p.click, sr)
        for i in 0..<clickLength {
            let x = Float(i) / Float(clickLength)
            out[i] += (1 - 2 * x) + 0.3 * rng.noise()
        }

        var hp1 = Biquad(.highPass, frequency: p.highPass, sampleRate: sr)
        var hp2 = Biquad(.highPass, frequency: p.highPass, sampleRate: sr)
        var tame = Biquad(.lowPass, frequency: 12_000, sampleRate: sr)
        for i in 0..<DSP.samples(p.burst, sr) {
            let t = Double(i) / sr
            let env = Float(exp(-t / p.tau) * min(1, t / 0.0003))
            out[i] += 0.85 * env * tame.process(hp2.process(hp1.process(rng.noise())))
        }

        // Level the boom + burst first so the thump and the saturation drive are the same for every variant.
        DSP.normalize(&out, to: 1)

        var phase = 0.0
        for i in 0..<DSP.samples(0.11, sr) {
            let t = Double(i) / sr
            phase += 2 * Double.pi * p.thump * (1 + 0.5 * exp(-t / 0.012)) / sr
            out[i] += Float(0.12 * exp(-t / 0.022) * min(1, t / 0.001) * sin(phase))
        }

        DSP.addReflections(&out, taps: [(0.011, 0.2), (0.023, 0.11)], lowPass: 4_500, sampleRate: sr)
        for i in out.indices { out[i] = tanh(1.6 * out[i]) }
        return out
    }

    // MARK: - Glass

    /// Crunchy ice: a sharp impact tick, then micro-clicks whose density rises as the fracture races outward,
    /// each with a tiny glassy resonance, over a faint high ring of stressed glass.
    private static func glassCrack(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let p = [(dur: 0.26, clicks: 28, ring: 6_300.0),
                 (dur: 0.24, clicks: 36, ring: 7_100.0),
                 (dur: 0.30, clicks: 20, ring: 5_600.0)][v]
        let n = DSP.samples(p.dur + 0.18, sr)
        var out = [Float](repeating: 0, count: n)

        // Crackle source: bright, with a little mid crunch underneath.
        var bright = Biquad(.highPass, frequency: 2_400, sampleRate: sr)
        var crunch = Biquad(.bandPass, frequency: 1_300, q: 1.1, sampleRate: sr)
        var crackle = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let w = rng.noise()
            crackle[i] = bright.process(w) + 0.5 * crunch.process(w)
        }

        // Onset CDF (t/T)²  →  t = T·√u: density rises toward the end.
        var onsets = [0.0]
        for _ in 1..<p.clicks { onsets.append(p.dur * sqrt(rng.uniform(0...1))) }
        for (k, onset) in onsets.enumerated() {
            let start = DSP.samples(onset, sr)
            let amp: Float = k == 0 ? 1 : Float(rng.uniform(0.25...0.85))
            let tau = rng.uniform(0.0004...0.0016) / 3
            for i in 0..<DSP.samples(tau * 7, sr) where start + i < n {
                out[start + i] += amp * Float(exp(-Double(i) / sr / tau)) * crackle[start + i]
            }
            DSP.addPing(&out, at: start, frequency: rng.uniform(2_500...7_500), amplitude: amp * 0.35,
                        decay: rng.uniform(0.0015...0.004), sampleRate: sr)
        }

        for (ratio, amp) in [(1.0, Float(0.07)), (1.37, 0.045), (1.83, 0.03)] {
            DSP.addPing(&out, at: DSP.samples(0.004, sr), frequency: p.ring * ratio, amplitude: amp, decay: 0.11,
                        attack: 0.01, sampleRate: sr)
        }
        return out
    }

    /// The glass gives way: a bright crash with a glassy sizzle and a low thud, then 40–60 shards tinkling at
    /// 2–9 kHz, dense at first and thinning out. `spread`/`tinkles` let `reassemble` render a tighter version.
    private static func shatter(_ v: Int, _ sr: Double, _ rng: inout SplitMix64,
                                spread: Double = 1.3, tinkles: Int? = nil) -> [Float] {
        let count = tinkles ?? [50, 58, 44][v]
        let n = DSP.samples(spread + 0.25, sr)
        var out = [Float](repeating: 0, count: n)

        var crash = Biquad(.highPass, frequency: 700, sampleRate: sr)
        var sizzle = Biquad(.bandPass, frequency: [2_600.0, 3_100.0, 2_200.0][v], q: 0.9, sampleRate: sr)
        var phase = 0.0
        for i in 0..<min(n, DSP.samples(0.6, sr)) {
            let t = Double(i) / sr
            let attack = min(1, t / 0.0015)
            let w = rng.noise()
            out[i] += Float(attack * exp(-t / 0.06)) * 0.9 * crash.process(w)
            out[i] += Float(attack * exp(-t / 0.16)) * 0.8 * sizzle.process(w)
            phase += 2 * Double.pi * 70 / sr
            out[i] += Float(0.45 * attack * exp(-t / 0.05) * sin(phase))
        }

        for _ in 0..<count {
            let onset = 0.012 + spread * pow(rng.uniform(0...1), 1.7)
            let frequency = rng.logUniform(2_000...9_000)
            let amp = Float(rng.uniform(0.12...0.42) * (1 - 0.5 * onset / spread))
            let tau = rng.uniform(0.012...0.05)
            let start = DSP.samples(onset, sr)
            DSP.addPing(&out, at: start, frequency: frequency, amplitude: amp, decay: tau, sampleRate: sr)
            // Inharmonic upper partial: what makes a sine sound like glass instead of a synth.
            DSP.addPing(&out, at: start, frequency: frequency * 2.76, amplitude: amp * 0.3, decay: tau * 0.6, sampleRate: sr)
        }
        return out
    }

    /// One or two short high pings — a shard or letter landing.
    private static func tinkle(_ v: Int, _ sr: Double) -> [Float] {
        let pings: [(at: Double, frequency: Double, amp: Float)] = [
            [(0, 4_200, 1)],
            [(0, 3_600, 1), (0.032, 4_540, 0.55)],
            [(0, 5_100, 1), (0.041, 4_280, 0.6)],
        ][v]
        var out = [Float](repeating: 0, count: DSP.samples(0.11, sr))
        for ping in pings {
            let start = DSP.samples(ping.at, sr)
            DSP.addPing(&out, at: start, frequency: ping.frequency, amplitude: ping.amp, decay: 0.02, sampleRate: sr)
            DSP.addPing(&out, at: start, frequency: ping.frequency * 2.76, amplitude: ping.amp * 0.3, decay: 0.011, sampleRate: sr)
            DSP.addPing(&out, at: start, frequency: ping.frequency * 0.5, amplitude: ping.amp * 0.15, decay: 0.025, sampleRate: sr)
        }
        return out
    }

    /// Everything flies back: a tight shatter played backwards (tinkles gather into the final snap) over a
    /// rising "shwoop" that lands exactly on that snap.
    private static func reassemble(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        var out = Array(shatter(v, sr, &rng, spread: 0.62, tinkles: 34).reversed())
        DSP.normalize(&out, to: 1)
        let n = out.count
        let (from, to) = [(170.0, 1_300.0), (150.0, 1_100.0), (200.0, 1_500.0)][v]
        var band = Biquad(.bandPass, frequency: from * 2, q: 1.4, sampleRate: sr)
        var phase = 0.0
        for i in 0..<n {
            let x = Double(i) / Double(n)
            let f = from * pow(to / from, x * x)
            if i % 32 == 0 { band.retune(.bandPass, frequency: f * 2, q: 1.4, sampleRate: sr) }
            phase += 2 * Double.pi * f / sr
            let env = pow(x, 2.2)
            let tone = Float(env * (sin(phase) + 0.25 * sin(2 * phase)))
            out[i] += 0.28 * tone + 0.35 * Float(env) * band.process(rng.noise())
        }
        return out
    }

    // MARK: - Dead display

    /// The display dying: a buzzy, clipped mains hum that sputters out a few times as it fades, crackling with sparks
    /// at first, over a thin coil whine.
    private static func buzz(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let p = [(dur: 1.6, hz: 120.0, whine: 9_200.0), (dur: 1.5, hz: 100.0, whine: 8_400.0), (dur: 1.7, hz: 120.0, whine: 10_100.0)][v]
        let n = DSP.samples(p.dur, sr)
        var out = [Float](repeating: 0, count: n)
        var sparkBand = Biquad(.highPass, frequency: 2_500, q: 0.7, sampleRate: sr)
        func unit(_ rng: inout SplitMix64) -> Double { Double(rng.next() >> 11) * 0x1.0p-53 }
        // Where it cuts out for a moment (fraction of the sound, length).
        let dropouts = (0..<3).map { _ in (at: 0.12 + 0.6 * unit(&rng), length: 0.02 + 0.05 * unit(&rng)) }
        let sparkDecay = exp(-1 / (0.004 * sr))
        var spark = 0.0
        var phase = 0.0, whinePhase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let x = t / p.dur
            phase += 2 * Double.pi * p.hz / sr
            let raw = sin(phase) + 0.6 * sin(2 * phase) + 0.45 * sin(3 * phase) + 0.3 * sin(5 * phase) + 0.2 * sin(7 * phase)
            let hum = max(-1.1, min(1.1, raw * 1.3))
            let envelope = min(1, t / 0.01) * pow(1 - x, 1.6)
            let gate = dropouts.contains { x >= $0.at && x < $0.at + $0.length } ? 0.12 : 1
            // Sparks: random short crackles, thick at first.
            if unit(&rng) < 40 * (1 - x) * (1 - x) / sr { spark = 1 }
            spark *= sparkDecay
            whinePhase += 2 * Double.pi * p.whine / sr
            let whine = 0.05 * sin(whinePhase) * pow(1 - x, 0.8)
            out[i] = Float(envelope * gate * 0.55 * hum + whine) + 0.8 * Float(spark) * sparkBand.process(rng.noise())
        }
        return out
    }

    // MARK: - Critter

    /// A soft, round upward "boop" (~550 → 900 Hz) for poking Lash.
    private static func boop(_ v: Int, _ sr: Double) -> [Float] {
        let (from, to, dur) = [(550.0, 900.0, 0.12), (520.0, 860.0, 0.13), (590.0, 960.0, 0.11)][v]
        let n = DSP.samples(dur, sr)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let x = Double(i) / Double(n)
            let easeOut = 1 - (1 - x) * (1 - x)
            phase += 2 * Double.pi * from * pow(to / from, easeOut) / sr
            let attack = sin(Double.pi / 2 * min(1, Double(i) / sr / 0.006))
            let env = attack * pow(1 - x, 1.4)
            out[i] = Float(env * (sin(phase) + 0.12 * sin(2 * phase) + 0.04 * sin(3 * phase)))
        }
        return out
    }

    /// A soft, padded "pff" of a hand on a fuzzy head: low-passed noise with a gentle body thump.
    private static func pat(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let (dur, cutoff, body) = [(0.07, 1_400.0, 150.0), (0.08, 1_200.0, 135.0), (0.065, 1_600.0, 170.0)][v]
        let n = DSP.samples(dur, sr)
        var out = [Float](repeating: 0, count: n)
        var soft = Biquad(.lowPass, frequency: cutoff, sampleRate: sr)
        for i in 0..<n {
            let t = Double(i) / sr
            let env = sin(Double.pi / 2 * min(1, t / 0.004)) * exp(-t / (dur * 0.28))
            let thump = sin(2 * Double.pi * body * t) * exp(-t / 0.018)
            out[i] = Float(env) * soft.process(rng.noise()) * 0.8 + Float(0.6 * thump * env)
        }
        return out
    }

    /// A contented purr: a low buzzy tone fluttering ~24 times a second, swelling in and trailing off.
    private static func purr(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let (dur, pitch, flutter) = [(0.85, 118.0, 24.0), (0.95, 108.0, 21.0), (0.8, 126.0, 26.0)][v]
        let n = DSP.samples(dur, sr)
        var out = [Float](repeating: 0, count: n)
        var rasp = Biquad(.bandPass, frequency: 900, q: 0.8, sampleRate: sr)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let x = t / dur
            // Two breaths: in (louder) and out.
            let breath = pow(sin(Double.pi * min(1, x * 1.9)), 2) * (x < 0.53 ? 1 : 0.7)
                + (x >= 0.53 ? 0.7 * pow(sin(Double.pi * (x - 0.53) / 0.47), 2) : 0)
            let flutterGain = 0.55 + 0.45 * sin(2 * Double.pi * flutter * t)
            phase += 2 * Double.pi * pitch * (1 + 0.02 * sin(2 * Double.pi * 3 * t)) / sr
            let tone = sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)
            let air = Double(rasp.process(rng.noise())) * 0.6
            out[i] = Float(breath * flutterGain * (tone * 0.5 + air))
        }
        return out
    }

    /// "Wheee!": a slide whistle rising, with a little flourish at the top.
    private static func wheee(_ v: Int, _ sr: Double) -> [Float] {
        let (dur, from, to) = [(0.55, 700.0, 1_900.0), (0.6, 650.0, 1_750.0), (0.5, 760.0, 2_050.0)][v]
        let n = DSP.samples(dur, sr)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let x = t / dur
            let rise = 1 - pow(1 - min(1, x / 0.8), 2)
            let vibrato = 1 + 0.03 * sin(2 * Double.pi * 7 * t) * x
            phase += 2 * Double.pi * from * pow(to / from, rise) * vibrato / sr
            let env = sin(Double.pi / 2 * min(1, t / 0.02)) * (x < 0.8 ? 1 : pow((1 - x) / 0.2, 1.5))
            out[i] = Float(env * (sin(phase) + 0.08 * sin(2 * phase)))
        }
        return out
    }

    /// "Hehehe": 4–6 voiced chirps descending in pitch, each with a breathy "h" onset, a little upward
    /// inflection and a fast cackling vibrato; the last one sags like a satisfied sigh.
    private static func giggle(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let p = [(count: 5, length: 0.072, gap: 0.046, pitch: 980.0, fall: 0.91),
                 (count: 4, length: 0.088, gap: 0.058, pitch: 900.0, fall: 0.89),
                 (count: 6, length: 0.060, gap: 0.036, pitch: 1_060.0, fall: 0.925)][v]
        let lastLength = p.length * 1.6
        let total = Double(p.count - 1) * (p.length + p.gap) + lastLength + 0.02
        let n = DSP.samples(total, sr)
        var out = [Float](repeating: 0, count: n)
        var breath = Biquad(.highPass, frequency: 3_000, sampleRate: sr)
        // A small creature's "eh": strong low harmonics, quickly thinning out.
        let harmonics: [Double] = [1, 0.55, 0.32, 0.2, 0.11, 0.06]

        for k in 0..<p.count {
            let isLast = k == p.count - 1
            let length = isLast ? lastLength : p.length
            let start = DSP.samples(Double(k) * (p.length + p.gap), sr)
            let pitch = p.pitch * pow(p.fall, Double(k)) * rng.uniform(0.97...1.03)
            var phase = rng.uniform(0...(2 * Double.pi))
            for i in 0..<DSP.samples(length, sr) where start + i < n {
                let t = Double(i) / sr
                let x = t / length
                let contour = 1 + 0.07 * sin(Double.pi * min(1, x * 1.6)) - (isLast ? 0.22 : 0.1) * x
                let vibrato = 1 + 0.035 * sin(2 * Double.pi * 23 * t)
                phase += 2 * Double.pi * pitch * contour * vibrato / sr
                var voice = 0.0
                for (h, amp) in harmonics.enumerated() { voice += amp * sin(Double(h + 1) * phase) }
                let attack = pow(sin(Double.pi / 2 * min(1, t / 0.008)), 2)
                let release = pow(sin(Double.pi / 2 * min(1, (length - t) / 0.025)), 2)
                let h = Float(0.35 * exp(-t / 0.01))
                out[start + i] += Float(0.5 * attack * release * voice) + h * breath.process(rng.noise())
            }
        }
        return out
    }

    // MARK: - UI

    /// A 15–20 ms woodblock: two inharmonic modes, a hollow sub-mode and a tiny noise click on the strike.
    private static func tick(_ v: Int, _ sr: Double, _ rng: inout SplitMix64) -> [Float] {
        let f = [1_850.0, 1_700.0, 2_000.0][v]
        var out = [Float](repeating: 0, count: DSP.samples(0.018, sr))
        DSP.addPing(&out, at: 0, frequency: f, amplitude: 1, decay: 0.0045, attack: 0.0002, sampleRate: sr)
        DSP.addPing(&out, at: 0, frequency: f * 2.57, amplitude: 0.45, decay: 0.0022, attack: 0.0002, sampleRate: sr)
        DSP.addPing(&out, at: 0, frequency: f * 0.5, amplitude: 0.25, decay: 0.006, attack: 0.0005, sampleRate: sr)
        var click = Biquad(.highPass, frequency: 4_000, sampleRate: sr)
        for i in 0..<DSP.samples(0.0012, sr) {
            out[i] += Float(0.5 * exp(-Double(i) / sr / 0.0004)) * click.process(rng.noise())
        }
        return out
    }

    /// "Da-DAAA!": two brassy notes rising (a fifth, a fourth or a minor sixth), each scooping up into pitch,
    /// the second held with vibrato. Band-limited squares softened by a low-pass.
    private static func alarm(_ v: Int, _ sr: Double) -> [Float] {
        let (base, interval) = [(587.33, 1.4983), (523.25, 1.3348), (659.26, 1.5874)][v]
        let notes: [(start: Double, length: Double, frequency: Double, release: Double)] = [
            (0, 0.15, base, 0.02),
            (0.17, 0.33, base * interval, 0.09),
        ]
        let n = DSP.samples(0.5, sr)
        var out = [Float](repeating: 0, count: n)
        for (index, note) in notes.enumerated() {
            let start = DSP.samples(note.start, sr)
            var phase = 0.0
            for i in 0..<DSP.samples(note.length, sr) where start + i < n {
                let t = Double(i) / sr
                let scoop = pow(2, -exp(-t / 0.018) / 12)
                let vibratoDepth = index == 1 ? 0.012 * min(1, max(0, (t - 0.08) / 0.1)) : 0
                phase += 2 * Double.pi * note.frequency * scoop * (1 + vibratoDepth * sin(2 * Double.pi * 6.5 * t)) / sr
                var s = 0.0
                for h in stride(from: 1, through: 9, by: 2) { s += sin(Double(h) * phase) / Double(h) }
                let attack = min(1, t / 0.005)
                let release = min(1, (note.length - t) / note.release)
                out[start + i] += Float(0.5 * attack * release * (1 - 0.3 * t / note.length) * s)
            }
        }
        var soften = Biquad(.lowPass, frequency: 5_500, sampleRate: sr)
        for i in out.indices { out[i] = soften.process(out[i]) }
        return out
    }
}

extension AVAudioPCMBuffer {
    /// A mono Float32 buffer holding `samples`.
    static func mono(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    var duration: TimeInterval { Double(frameLength) / format.sampleRate }
}
