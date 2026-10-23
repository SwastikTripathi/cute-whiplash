import AVFoundation
import XCTest
@testable import Whiplash

/// Runs the real SoundBoard graph (voices → bus → limiter → main mixer) in manual-rendering mode, so playback is
/// verified without an audio device and without making a sound.
///
/// Realtime (not offline) manual rendering on purpose: it applies per-voice volume/pan exactly like a live device.
/// Offline manual rendering stops applying mixer parameter changes after its first render call.
final class AudioPlaybackTests: XCTestCase {
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let chunkFrames: AVAudioFrameCount = 512

    private func makeBoard() throws -> (SoundBoard, AVAudioEngine) {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.realtime, format: outputFormat, maximumFrameCount: 4_096)
        return (SoundBoard(engine: engine), engine)
    }

    private func waitUntilReady(_ board: SoundBoard, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(30)
        while !board.isReady, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(board.isReady, "synthesis did not finish", file: file, line: line)
    }

    /// Pulls `seconds` of stereo audio out of the engine: (left, right).
    private func render(_ engine: AVAudioEngine, seconds: Double) throws -> ([Float], [Float]) {
        guard engine.isRunning else { return ([], []) }
        let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunkFrames))
        var left: [Float] = [], right: [Float] = []
        let total = Int(seconds * outputFormat.sampleRate)
        var error: OSStatus = noErr
        while left.count < total {
            chunk.frameLength = chunkFrames
            let status = engine.manualRenderingBlock(chunkFrames, chunk.mutableAudioBufferList, &error)
            XCTAssertEqual(status, .success)
            XCTAssertEqual(error, noErr)
            let channels = try XCTUnwrap(chunk.floatChannelData)
            left += UnsafeBufferPointer(start: channels[0], count: Int(chunkFrames))
            right += UnsafeBufferPointer(start: channels[1], count: Int(chunkFrames))
        }
        return (left, right)
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    func testPlayBeforeReadyStartsSynthesisAndDropsTheSound() throws {
        let (board, engine) = try makeBoard()
        XCTAssertFalse(board.isReady)
        board.play(.crack)
        XCTAssertFalse(engine.isRunning, "nothing to play yet, so the engine stays off")
        waitUntilReady(board)
        board.prepare() // idempotent once ready
        XCTAssertTrue(board.isReady)
    }

    func testAPileUpOfLoudSoundsStaysUnderTheCeiling() throws {
        let (board, engine) = try makeBoard()
        board.prepare()
        waitUntilReady(board)
        for sfx: SFX in [.crack, .shatter, .glassCrack, .whoosh, .buzz, .alarm, .giggle] {
            board.play(sfx, intensity: 2, pan: 0)
        }
        XCTAssertTrue(engine.isRunning, "started lazily by the first play")
        let (left, right) = try render(engine, seconds: 1.5)
        let peak = (left + right).reduce(0) { max($0, abs($1)) }
        XCTAssertGreaterThan(peak, 0.3, "it's actually loud")
        XCTAssertLessThanOrEqual(peak, 0.93, "limiter + 0.9 master keep the sum from clipping")
        XCTAssertGreaterThan(rms(left[...]), 0.02)
    }

    func testPanAndIntensity() throws {
        let (board, engine) = try makeBoard()
        board.prepare()
        waitUntilReady(board)

        board.play(.boop, intensity: 1, pan: -1)
        let (left, right) = try render(engine, seconds: 0.2)
        XCTAssertGreaterThan(rms(left[...]), 0.05)
        XCTAssertLessThan(rms(right[...]), rms(left[...]) * 0.05, "hard left")

        board.play(.tick, intensity: 0, pan: 0)
        let (silentLeft, silentRight) = try render(engine, seconds: 0.1)
        XCTAssertEqual(rms(silentLeft[...]) + rms(silentRight[...]), 0, accuracy: 1e-6, "intensity 0 is silent")
    }

    /// Regression: the mixer ramps a voice's volume/pan over ~20 ms, which used to let every attack through at
    /// full level and centred. Gain and pan must be right from the very first sample of a fresh voice.
    func testAttackIsAlreadyAtTargetGainAndPan() throws {
        let (board, engine) = try makeBoard()
        board.prepare()
        waitUntilReady(board)
        board.play(.crack, intensity: 0.5, pan: 1)
        let (left, right) = try render(engine, seconds: 0.05)
        let expected = SFXSynth.targetPeak * SFX.crack.mixLevel * 0.4 * 0.9 // peak · mix · loudness · master
        XCTAssertEqual(left.reduce(0) { max($0, abs($1)) }, 0, accuracy: 1e-6, "nothing leaks left")
        let peak = right.reduce(0) { max($0, abs($1)) }
        XCTAssertLessThanOrEqual(peak, expected * 1.01)
        XCTAssertGreaterThan(peak, expected * 0.85, "gain jitter is at most -1 dB")
    }

    func testDisabledBoardIsANoOp() throws {
        let (board, engine) = try makeBoard()
        board.enabled = false
        board.play(.crack)
        XCTAssertFalse(board.isReady, "a disabled board doesn't even synthesize")
        XCTAssertFalse(engine.isRunning)
    }

    func testDisablingSilencesAndReleasesTheEngine() throws {
        let (board, engine) = try makeBoard()
        board.prepare()
        waitUntilReady(board)
        board.play(.buzz)
        XCTAssertTrue(engine.isRunning)
        board.enabled = false
        XCTAssertFalse(engine.isRunning)
    }

    func testEngineStopsAfterSilenceAndRestartsOnDemand() throws {
        let (board, engine) = try makeBoard()
        board.idleTimeout = 0.1
        board.prepare()
        waitUntilReady(board)
        board.play(.tick)
        XCTAssertTrue(engine.isRunning)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertFalse(engine.isRunning, "idle engine released")

        board.play(.tick)
        XCTAssertTrue(engine.isRunning)
        let (left, _) = try render(engine, seconds: 0.05)
        XCTAssertGreaterThan(rms(left[...]), 0.01, "voices play again after a restart")
    }

    func testConfigurationChangeRestartsAnActiveEngine() throws {
        let (board, engine) = try makeBoard()
        board.prepare()
        waitUntilReady(board)
        board.play(.shatter)
        // What the system does when the output device changes: stop the engine, then notify.
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(engine.isRunning)
        board.play(.crack)
        let (left, _) = try render(engine, seconds: 0.05)
        XCTAssertGreaterThan(rms(left[...]), 0.01)
    }

    func testRapidRetriggersOfOneSoundAreThinnedOut() throws {
        let (board, engine) = try makeBoard()
        board.prepare()
        waitUntilReady(board)
        for _ in 0..<50 { board.play(.tinkle, pan: 0) }
        let (left, _) = try render(engine, seconds: 0.12)
        let peak = left.reduce(0) { max($0, abs($1)) }
        XCTAssertLessThan(peak, 0.6, "fifty simultaneous tinkles collapse into one")
        XCTAssertGreaterThan(peak, 0.05)
    }
}
