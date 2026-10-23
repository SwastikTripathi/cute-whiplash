import AVFoundation
import XCTest
@testable import Whiplash

final class AudioSynthTests: XCTestCase {
    private static let sampleRate = SFXSynth.sampleRate

    /// Every variant of every sound, rendered once for the whole test case.
    private static let rendered: [SFX: [[Float]]] = Dictionary(uniqueKeysWithValues: SFX.allCases.map { sfx in
        (sfx, (0..<SFXSynth.variantCount).map { SFXSynth.render(sfx, variant: $0) })
    })

    private static let expectedDuration: [SFX: ClosedRange<TimeInterval>] = [
        .whoosh: 0.28...0.45, .crack: 0.08...0.25, .glassCrack: 0.3...0.6, .shatter: 1.2...1.8, .tinkle: 0.06...0.15,
        .buzz: 1.4...1.8, .reassemble: 0.75...1.0, .boop: 0.1...0.15, .giggle: 0.45...0.75, .tick: 0.012...0.03,
        .alarm: 0.4...0.6, .pat: 0.05...0.1, .purr: 0.75...1.0, .wheee: 0.45...0.65,
    ]

    private func duration(_ samples: [Float]) -> TimeInterval { Double(samples.count) / Self.sampleRate }

    private func energy(_ samples: ArraySlice<Float>) -> Double { samples.reduce(0) { $0 + Double($1 * $1) } }

    /// Zero crossings per second over a slice: a cheap estimate of the dominant frequency × 2.
    private func crossingsPerSecond(_ samples: ArraySlice<Float>) -> Double {
        var crossings = 0
        var previous = samples.first ?? 0
        for sample in samples.dropFirst() {
            if (previous < 0) != (sample < 0) { crossings += 1 }
            previous = sample
        }
        return Double(crossings) / (Double(samples.count) / Self.sampleRate)
    }

    // MARK: - Well-formedness

    func testEverySoundAndVariantIsWellFormed() throws {
        for sfx in SFX.allCases {
            let variants = try XCTUnwrap(Self.rendered[sfx])
            XCTAssertEqual(variants.count, SFXSynth.variantCount)
            for (v, samples) in variants.enumerated() {
                let tag = "\(sfx) v\(v + 1)"
                XCTAssertFalse(samples.isEmpty, tag)
                XCTAssertTrue(samples.allSatisfy(\.isFinite), "\(tag) has NaN/inf")
                let peak = DSP.peak(samples)
                XCTAssertGreaterThan(peak, 0.05, tag)
                XCTAssertLessThanOrEqual(peak, 0.95, tag)
                let range = try XCTUnwrap(Self.expectedDuration[sfx])
                XCTAssertTrue(range.contains(duration(samples)), "\(tag) lasts \(duration(samples)) s, expected \(range)")
                XCTAssertLessThan(abs(samples.last ?? 1), 0.01, "\(tag) ends on a click")
            }
        }
    }

    func testVariantsAudiblyDiffer() throws {
        for sfx in SFX.allCases {
            let variants = try XCTUnwrap(Self.rendered[sfx])
            for a in 0..<variants.count {
                for b in (a + 1)..<variants.count {
                    let x = variants[a], y = variants[b]
                    let n = min(x.count, y.count)
                    var difference = 0.0
                    for i in 0..<n { difference += Double(abs(x[i] - y[i])) }
                    let meanDifference = difference / Double(n)
                    XCTAssertTrue(meanDifference > 0.01 || abs(x.count - y.count) > 480,
                                  "\(sfx) v\(a + 1) and v\(b + 1) are near-identical (mean |Δ| \(meanDifference))")
                }
            }
        }
    }

    func testRenderingIsDeterministic() {
        for sfx in SFX.allCases {
            XCTAssertEqual(SFXSynth.render(sfx, variant: 1), Self.rendered[sfx]?[1], "\(sfx)")
        }
        XCTAssertEqual(SFXSynth.render(.tick, variant: 4), SFXSynth.render(.tick, variant: 1), "variants wrap around")
    }

    // MARK: - Character (guards the sound design against regressions)

    func testCrackIsAnInstantTransient() throws {
        for samples in try XCTUnwrap(Self.rendered[.crack]) {
            let peakIndex = samples.indices.max { abs(samples[$0]) < abs(samples[$1]) } ?? 0
            XCTAssertLessThan(Double(peakIndex) / Self.sampleRate, 0.004, "peak within the first few ms")
            let head = energy(samples[..<Int(0.03 * Self.sampleRate)])
            XCTAssertGreaterThan(head / energy(samples[...]), 0.85, "almost all energy in the first 30 ms")
        }
    }

    func testWhooshSwellsAndSweepsUpward() throws {
        for samples in try XCTUnwrap(Self.rendered[.whoosh]) {
            let n = samples.count
            let early = samples[(n / 8)..<(n * 3 / 8)], late = samples[(n * 5 / 8)..<(n * 7 / 8)]
            XCTAssertGreaterThan(crossingsPerSecond(late), crossingsPerSecond(early) * 1.5, "rising pitch")
            XCTAssertGreaterThan(energy(samples[(n / 2)...]), energy(samples[..<(n / 2)]), "swells toward the crack")
        }
    }

    func testGlassCrackDensityRises() throws {
        for samples in try XCTUnwrap(Self.rendered[.glassCrack]) {
            // Count 2 ms frames holding a click (the faint ring stays under the bar), skipping the impact at t = 0.
            let frame = Int(0.002 * Self.sampleRate)
            func clicks(from start: Double, to end: Double) -> Int {
                stride(from: Int(start * Self.sampleRate), to: Int(end * Self.sampleRate), by: frame).filter { i in
                    samples[i..<min(samples.count, i + frame)].contains { abs($0) > 0.2 }
                }.count
            }
            let fracture = duration(samples) - 0.18
            XCTAssertGreaterThan(clicks(from: fracture / 2, to: fracture), clicks(from: 0.01, to: fracture / 2))
        }
    }

    func testShatterAndReassembleMirrorEachOther() throws {
        for (shatter, reassemble) in zip(try XCTUnwrap(Self.rendered[.shatter]), try XCTUnwrap(Self.rendered[.reassemble])) {
            let s = shatter.count, r = reassemble.count
            XCTAssertGreaterThan(energy(shatter[..<(s / 4)]), energy(shatter[(s / 4)...]), "shatter front-loaded")
            XCTAssertGreaterThan(energy(reassemble[(r * 3 / 4)...]), energy(reassemble[..<(r * 3 / 4)]), "reassemble lands at the end")
        }
    }

    func testBuzzHumsAndTinkleIsHigh() throws {
        for samples in try XCTUnwrap(Self.rendered[.buzz]) {
            // Under the thin coil whine, it's the mains hum: a few zero crossings per cycle of 100–120 Hz.
            let n = samples.count
            let window = 24 // ~2 kHz low-pass: the whine and the sparks drop out
            let hum = (n / 2..<(n * 3 / 4)).map { i in samples[(i - window)..<i].reduce(0, +) / Float(window) }
            let rate = crossingsPerSecond(hum[...])
            XCTAssertTrue((150...1_500).contains(rate), "\(rate) crossings/s")
        }
        for samples in try XCTUnwrap(Self.rendered[.tinkle]) {
            XCTAssertGreaterThan(crossingsPerSecond(samples[..<Int(0.02 * Self.sampleRate)]), 6_000)
        }
    }

    func testBoopSweepsThroughItsRange() throws {
        for samples in try XCTUnwrap(Self.rendered[.boop]) {
            let n = samples.count
            let start = crossingsPerSecond(samples[..<(n / 4)]) / 2, end = crossingsPerSecond(samples[(n * 3 / 4)...]) / 2
            XCTAssertTrue((480...760).contains(start), "starts near 550 Hz, got \(start)")
            XCTAssertTrue((780...1_050).contains(end), "ends near 900 Hz, got \(end)")
        }
    }

    func testGiggleHasFourToSixChirps() throws {
        for samples in try XCTUnwrap(Self.rendered[.giggle]) {
            let window = Int(0.005 * Self.sampleRate)
            var chirps = 0, inChirp = false
            for start in stride(from: 0, to: samples.count - window, by: window) {
                let loud = (energy(samples[start..<(start + window)]) / Double(window)).squareRoot() > 0.05
                if loud, !inChirp { chirps += 1 }
                inChirp = loud
            }
            XCTAssertTrue((4...6).contains(chirps), "counted \(chirps) chirps")
        }
    }

    func testAlarmRises() throws {
        for samples in try XCTUnwrap(Self.rendered[.alarm]) {
            let first = samples[Int(0.04 * Self.sampleRate)..<Int(0.14 * Self.sampleRate)]
            let second = samples[Int(0.25 * Self.sampleRate)..<Int(0.4 * Self.sampleRate)]
            XCTAssertGreaterThan(crossingsPerSecond(second), crossingsPerSecond(first) * 1.2)
        }
    }

    // MARK: - Encoding

    func testLibraryBuffersMatchTheRenders() throws {
        let library = SFXSynth.library()
        for sfx in SFX.allCases {
            let buffers = try XCTUnwrap(library[sfx])
            XCTAssertEqual(buffers.count, SFXSynth.variantCount)
            for (v, buffer) in buffers.enumerated() {
                XCTAssertEqual(buffer.format.channelCount, 1)
                XCTAssertEqual(buffer.format.sampleRate, SFXSynth.sampleRate)
                let samples = try XCTUnwrap(Self.rendered[sfx]?[v])
                XCTAssertEqual(Int(buffer.frameLength), samples.count)
                XCTAssertEqual(buffer.floatChannelData?[0][samples.count / 2], samples[samples.count / 2])
            }
        }
    }

    /// Writes every sound as 16-bit WAV (kept in the temp dir so a human can listen) and reads it back.
    func testEverySoundRoundTripsThroughWAV() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("whiplash-sfx", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: SFXSynth.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        for sfx in SFX.allCases {
            for (v, samples) in try XCTUnwrap(Self.rendered[sfx]).enumerated() {
                let url = directory.appendingPathComponent("\(sfx)-\(v + 1).wav")
                let buffer = try XCTUnwrap(AVAudioPCMBuffer.mono(samples, sampleRate: SFXSynth.sampleRate))
                do {
                    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                    try file.write(from: buffer)
                }
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                XCTAssertEqual(file.fileFormat.sampleRate, SFXSynth.sampleRate)
                XCTAssertEqual(file.length, AVAudioFramePosition(samples.count))
                let readBack = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: readBack)
                let channel = try XCTUnwrap(readBack.floatChannelData?[0])
                var worst: Float = 0
                for i in 0..<samples.count { worst = max(worst, abs(channel[i] - samples[i])) }
                XCTAssertLessThan(worst, 2.0 / 32_768, "\(sfx) v\(v + 1) lost precision beyond 16-bit quantization")
            }
        }
        print("SFX WAVs: \(directory.path)")
    }
}
