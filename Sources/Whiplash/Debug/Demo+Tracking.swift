import Accelerate
import SpriteKit
import SwiftUI

extension DemoRegistry {
    static var trackingDemos: [Demo] {
        [
            Demo(name: "tracking.waveforms",
                 summary: "Every procedural SFX, 3 variants each: peak (light) and RMS (solid) envelopes",
                 payload: .scene(SceneDemo(duration: 0.05, captureTimes: [0], compositeOverBackdrop: false, scale: 2,
                                           make: { SFXBoard.scene(size: $0, lanes: .envelope) }))),
            Demo(name: "tracking.spectra",
                 summary: "Spectrograms of every SFX variant (log frequency 40 Hz–20 kHz, 80 dB range)",
                 payload: .scene(SceneDemo(duration: 0.05, captureTimes: [0], compositeOverBackdrop: false, scale: 2,
                                           make: { SFXBoard.scene(size: $0, lanes: .spectrogram) }))),
        ]
    }
}

// MARK: - SFX board

/// A grid with one cell per SFX and one lane per variant, all variants of a sound sharing a time axis.
private enum SFXBoard {
    enum Lanes { case envelope, spectrogram }

    static let background = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let cellColor = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.14, alpha: 1)

    static func color(for sfx: SFX) -> NSColor {
        switch sfx {
        case .whoosh, .crack: return NSColor(srgbRed: 1.0, green: 0.62, blue: 0.25, alpha: 1)
        case .glassCrack, .shatter, .tinkle, .reassemble: return NSColor(srgbRed: 0.45, green: 0.86, blue: 1.0, alpha: 1)
        case .buzz: return NSColor(srgbRed: 0.72, green: 0.52, blue: 1.0, alpha: 1)
        case .boop, .giggle, .pat, .purr, .wheee: return NSColor(srgbRed: 1.0, green: 0.48, blue: 0.72, alpha: 1)
        case .tick, .alarm: return NSColor(srgbRed: 1.0, green: 0.86, blue: 0.35, alpha: 1)
        }
    }

    static func scene(size: CGSize, lanes: Lanes) -> SKScene {
        let scene = SKScene(size: size)
        scene.backgroundColor = background
        let started = Date()
        let rendered = SFX.allCases.map { sfx in
            (sfx, (0..<SFXSynth.variantCount).map { SFXSynth.render(sfx, variant: $0) })
        }
        let synthMs = Date().timeIntervalSince(started) * 1000
        let totalSeconds = rendered.reduce(0.0) { $0 + $1.1.reduce(0.0) { $0 + Double($1.count) / SFXSynth.sampleRate } }

        let title = lanes == .envelope ? "procedural SFX · waveform envelopes" : "procedural SFX · spectrograms"
        scene.addChild(label(title, size: 24, bold: true, color: .white, at: CGPoint(x: 24, y: size.height - 42)))
        let subtitle = String(format: "48 kHz mono · %d variants · %.1f s of audio synthesized in %.0f ms (debug build)",
                              SFXSynth.variantCount, totalSeconds, synthMs)
        scene.addChild(label(subtitle, size: 13, color: NSColor(white: 0.6, alpha: 1), at: CGPoint(x: 26, y: size.height - 62)))

        let columns = 3, rows = 4
        let margin: CGFloat = 24, header: CGFloat = 78, gutter: CGFloat = 14
        let cellSize = CGSize(width: (size.width - 2 * margin - CGFloat(columns - 1) * gutter) / CGFloat(columns),
                              height: (size.height - header - margin - CGFloat(rows - 1) * gutter) / CGFloat(rows))
        func cellFrame(_ index: Int) -> CGRect {
            let col = index % columns, row = index / columns
            return CGRect(x: margin + CGFloat(col) * (cellSize.width + gutter),
                          y: size.height - header - CGFloat(row + 1) * cellSize.height - CGFloat(row) * gutter,
                          width: cellSize.width, height: cellSize.height)
        }
        for (index, (sfx, variants)) in rendered.enumerated() {
            addCell(sfx, variants: variants, frame: cellFrame(index), lanes: lanes, to: scene)
        }
        addLegend(lanes: lanes, frame: cellFrame(rendered.count), to: scene)
        return scene
    }

    private static func addCell(_ sfx: SFX, variants: [[Float]], frame: CGRect, lanes: Lanes, to scene: SKScene) {
        let card = SKShapeNode(rect: frame, cornerRadius: 10)
        card.fillColor = cellColor
        card.strokeColor = .clear
        scene.addChild(card)

        let tint = color(for: sfx)
        let durations = variants.map { Double($0.count) / SFXSynth.sampleRate }
        let span = durations.max() ?? 1
        scene.addChild(label(String(describing: sfx), size: 17, bold: true, color: tint,
                             at: CGPoint(x: frame.minX + 12, y: frame.maxY - 24)))
        let info = durations.map { formatDuration($0) }.joined(separator: " / ")
        scene.addChild(label(info, size: 12, color: NSColor(white: 0.55, alpha: 1),
                             at: CGPoint(x: frame.maxX - 12, y: frame.maxY - 23), alignment: .right))

        let plot = CGRect(x: frame.minX + 34, y: frame.minY + 24, width: frame.width - 46, height: frame.height - 58)
        let laneGap: CGFloat = 5
        let laneHeight = (plot.height - CGFloat(variants.count - 1) * laneGap) / CGFloat(variants.count)

        let step = tickStep(for: span)
        var t = 0.0
        while t <= span + 1e-9 {
            let x = plot.minX + CGFloat(t / span) * plot.width
            let line = SKShapeNode(rect: CGRect(x: x, y: plot.minY, width: 1, height: plot.height))
            line.fillColor = NSColor(white: 1, alpha: 0.07)
            line.strokeColor = .clear
            scene.addChild(line)
            scene.addChild(label(formatDuration(t), size: 10, color: NSColor(white: 0.5, alpha: 1),
                                 at: CGPoint(x: x, y: frame.minY + 8), alignment: t == 0 ? .left : .center))
            t += step
        }

        let spectrogramScale = spectrogramDecibelReference(variants)
        for (v, samples) in variants.enumerated() {
            let lane = CGRect(x: plot.minX, y: plot.maxY - CGFloat(v + 1) * laneHeight - CGFloat(v) * laneGap,
                              width: plot.width, height: laneHeight)
            scene.addChild(label("v\(v + 1)", size: 11, color: NSColor(white: 0.5, alpha: 1),
                                 at: CGPoint(x: frame.minX + 10, y: lane.midY - 4)))
            let laneWidth = lane.width * CGFloat(Double(samples.count) / SFXSynth.sampleRate / span)
            switch lanes {
            case .envelope:
                let axis = SKShapeNode(rect: CGRect(x: lane.minX, y: lane.midY, width: lane.width, height: 0.5))
                axis.fillColor = NSColor(white: 1, alpha: 0.12)
                axis.strokeColor = .clear
                scene.addChild(axis)
                addEnvelope(samples, in: CGRect(x: lane.minX, y: lane.minY, width: laneWidth, height: lane.height), tint: tint, to: scene)
            case .spectrogram:
                let bounds = CGRect(x: lane.minX, y: lane.minY, width: max(1, laneWidth), height: lane.height)
                if let image = Spectrogram.image(samples, sampleRate: SFXSynth.sampleRate, columns: Int(bounds.width),
                                                 rows: Int(bounds.height), referenceDecibels: spectrogramScale) {
                    let sprite = SKSpriteNode(texture: SKTexture(cgImage: image), size: bounds.size)
                    sprite.position = CGPoint(x: bounds.midX, y: bounds.midY)
                    scene.addChild(sprite)
                }
            }
        }
        if lanes == .spectrogram {
            for (hz, text) in [(100.0, "100"), (1_000.0, "1k"), (10_000.0, "10k")] {
                let y = plot.maxY - laneHeight + CGFloat(Spectrogram.position(ofFrequency: hz)) * laneHeight
                scene.addChild(label(text, size: 9, color: NSColor(white: 0.45, alpha: 1),
                                     at: CGPoint(x: frame.maxX - 4, y: y - 3), alignment: .right))
            }
        }
    }

    /// Mirrored peak envelope (translucent) with the RMS envelope (solid) inside it.
    private static func addEnvelope(_ samples: [Float], in rect: CGRect, tint: NSColor, to scene: SKScene) {
        let bins = max(2, Int(rect.width))
        var peaks = [CGFloat](repeating: 0, count: bins), rms = [CGFloat](repeating: 0, count: bins)
        for b in 0..<bins {
            let lo = samples.count * b / bins, hi = max(lo + 1, samples.count * (b + 1) / bins)
            var peak: Float = 0, energy: Float = 0
            for i in lo..<min(hi, samples.count) {
                peak = max(peak, abs(samples[i]))
                energy += samples[i] * samples[i]
            }
            peaks[b] = CGFloat(peak)
            rms[b] = CGFloat(sqrt(energy / Float(hi - lo)))
        }
        let scale = rect.height / 2 / CGFloat(SFXSynth.targetPeak)
        // SpriteKit can't fill a polygon that pinches to zero width (silent gaps), so keep a hairline minimum.
        let minimumHalfHeight: CGFloat = 0.3
        for (values, alpha) in [(peaks, 0.38), (rms, 0.95)] {
            let path = CGMutablePath()
            for b in 0..<bins {
                let point = CGPoint(x: rect.minX + CGFloat(b) * rect.width / CGFloat(bins - 1),
                                    y: rect.midY + max(minimumHalfHeight, values[b] * scale))
                if b == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            for b in (0..<bins).reversed() {
                path.addLine(to: CGPoint(x: rect.minX + CGFloat(b) * rect.width / CGFloat(bins - 1),
                                         y: rect.midY - max(minimumHalfHeight, values[b] * scale)))
            }
            path.closeSubpath()
            let shape = SKShapeNode(path: path)
            shape.fillColor = tint.withAlphaComponent(alpha)
            shape.strokeColor = tint.withAlphaComponent(alpha * 0.6)
            shape.lineWidth = 0.5
            scene.addChild(shape)
        }
    }

    /// Loudest spectral bin across the variants, so all three lanes share one colour scale.
    private static func spectrogramDecibelReference(_ variants: [[Float]]) -> Float {
        variants.map { Spectrogram.maxDecibels($0) }.max() ?? 0
    }

    private static func addLegend(lanes: Lanes, frame: CGRect, to scene: SKScene) {
        let lines: [String]
        switch lanes {
        case .envelope:
            lines = ["light: peak |x| per pixel", "solid: RMS per pixel", "height: ±\(SFXSynth.targetPeak) (normalized peak)",
                     "variants of a sound share a time axis", "orange whip · cyan glass · violet buzz", "pink critter · yellow UI"]
        case .spectrogram:
            lines = ["x: time (shared per sound)", "y: 40 Hz – 20 kHz, log scale", "colour: 0 to −80 dB of the loudest bin",
                     "hann window, 75 % overlap", "look for: whoosh sweeping up,", "reassemble rushing up to the snap"]
        }
        for (i, text) in lines.enumerated() {
            scene.addChild(label(text, size: 13, color: NSColor(white: 0.62, alpha: 1),
                                 at: CGPoint(x: frame.minX + 14, y: frame.maxY - 30 - CGFloat(i) * 24)))
        }
    }

    private static func tickStep(for span: Double) -> Double {
        [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.25, 0.5, 1].first { span / $0 <= 6 } ?? 1
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds == 0 { return "0" }
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2g s", seconds)
    }
}

/// Short-time Fourier transform → false-colour image (row 0 = top = highest frequency).
private enum Spectrogram {
    static let minFrequency = 40.0, maxFrequency = 20_000.0
    static let dynamicRange: Float = 80

    /// 0 (bottom, 40 Hz) ... 1 (top, 20 kHz) on the log-frequency axis.
    static func position(ofFrequency hz: Double) -> Double {
        log(hz / minFrequency) / log(maxFrequency / minFrequency)
    }

    /// Longer windows for longer sounds: frequency detail for the buzz, time detail for the tick.
    static func fftSize(for sampleCount: Int) -> Int {
        var size = 128
        while size < 2048, size * 8 < sampleCount { size *= 2 }
        return size
    }

    /// Power spectra (dB) of hann-windowed frames, `columns` of them spread evenly over the signal.
    static func frames(_ samples: [Float], columns: Int) -> (size: Int, decibels: [[Float]]) {
        let size = fftSize(for: samples.count)
        let half = size / 2
        let log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (size, []) }
        defer { vDSP_destroy_fftsetup(setup) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        var result: [[Float]] = []
        for column in 0..<columns {
            let center = samples.count * column / max(1, columns - 1)
            var frame = [Float](repeating: 0, count: size)
            for i in 0..<size {
                let source = center - half + i
                if source >= 0, source < samples.count { frame[i] = samples[source] * window[i] }
            }
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                    frame.withUnsafeBufferPointer { framePointer in
                        framePointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            result.append(power.map { 10 * log10($0 + 1e-12) })
        }
        return (size, result)
    }

    static func maxDecibels(_ samples: [Float]) -> Float {
        frames(samples, columns: 96).decibels.map { $0.max() ?? -120 }.max() ?? 0
    }

    static func image(_ samples: [Float], sampleRate: Double, columns: Int, rows: Int, referenceDecibels: Float) -> CGImage? {
        guard columns > 0, rows > 0 else { return nil }
        let (size, spectra) = frames(samples, columns: columns)
        let binWidth = sampleRate / Double(size)
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        for row in 0..<rows {
            let position = 1 - (Double(row) + 0.5) / Double(rows)
            let lo = minFrequency * pow(maxFrequency / minFrequency, position - 0.5 / Double(rows))
            let hi = minFrequency * pow(maxFrequency / minFrequency, position + 0.5 / Double(rows))
            let first = max(1, min(size / 2 - 1, Int(lo / binWidth)))
            let last = max(first, min(size / 2 - 1, Int(hi / binWidth)))
            for column in 0..<columns {
                var db: Float = -200
                for bin in first...last { db = max(db, spectra[column][bin]) }
                let level = max(0, min(1, 1 + (db - referenceDecibels) / dynamicRange))
                let (r, g, b) = inferno(level)
                let offset = (row * columns + column) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A compact approximation of matplotlib's "inferno": black → purple → orange → pale yellow.
    private static func inferno(_ x: Float) -> (UInt8, UInt8, UInt8) {
        let stops: [(Float, Float, Float)] = [(0, 0, 0.02), (0.26, 0.04, 0.41), (0.58, 0.15, 0.40),
                                              (0.87, 0.32, 0.23), (0.99, 0.64, 0.04), (0.99, 1.0, 0.64)]
        let scaled = x * Float(stops.count - 1)
        let i = min(stops.count - 2, Int(scaled))
        let f = scaled - Float(i)
        func mix(_ a: Float, _ b: Float) -> UInt8 { UInt8(max(0, min(255, (a + (b - a) * f) * 255))) }
        return (mix(stops[i].0, stops[i + 1].0), mix(stops[i].1, stops[i + 1].1), mix(stops[i].2, stops[i + 1].2))
    }
}

// MARK: - Drawing helpers

private func label(_ text: String, size: CGFloat, bold: Bool = false, color: NSColor, at position: CGPoint,
                   alignment: SKLabelHorizontalAlignmentMode = .left) -> SKLabelNode {
    let node = SKLabelNode(text: text)
    node.fontName = bold ? "Menlo-Bold" : "Menlo-Regular"
    node.fontSize = size
    node.fontColor = color
    node.horizontalAlignmentMode = alignment
    node.verticalAlignmentMode = .baseline
    node.position = position
    return node
}

private func rule(from a: CGPoint, to b: CGPoint, color: NSColor, dashed: Bool = false) -> SKShapeNode {
    let path = CGMutablePath()
    path.move(to: a)
    path.addLine(to: b)
    let node = SKShapeNode(path: dashed ? path.copy(dashingWithPhase: 0, lengths: [8, 6]) : path)
    node.strokeColor = color
    node.lineWidth = 1.5
    return node
}
