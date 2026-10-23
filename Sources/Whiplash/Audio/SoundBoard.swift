import Accelerate
import AVFoundation
import os

/// Every sound in the app. All procedurally synthesized — no audio files.
enum SFX: CaseIterable {
    case whoosh        // whip swinging through the air
    case crack         // the whip breaking the sound barrier
    case glassCrack    // screen fracturing
    case shatter       // glass bursting into shards
    case tinkle        // a single shard / letter landing
    case buzz          // the display dying: electrical buzz and sparks
    case reassemble    // reverse-shatter swoosh when everything flies back
    case boop          // critter poked
    case giggle        // critter delighted
    case tick          // countdown tick
    case alarm         // "the whip is coming" sting
    case pat           // a soft pat on Lash's head
    case purr          // Lash enjoying the head pats
    case wheee         // Lash spinning for joy
}

extension SFX {
    /// Relative loudness in the mix: the crack is the star; a letter landing is a sprinkle.
    var mixLevel: Float {
        switch self {
        case .crack, .shatter: return 1
        case .glassCrack, .reassemble: return 0.85
        case .buzz: return 0.7
        case .giggle: return 0.75
        case .whoosh, .alarm: return 0.7
        case .boop, .wheee: return 0.6
        case .purr: return 0.55
        case .tick: return 0.5
        case .tinkle: return 0.45
        case .pat: return 0.35
        }
    }
}

/// Plays the synthesized SFX through a small pool of voices. Main thread only.
///
/// The engine starts lazily on the first sound and stops again after `idleTimeout` of silence, so an idle
/// app costs no audio CPU. It survives output-device changes and silently does nothing without an output device.
final class SoundBoard {
    static let shared = SoundBoard()

    /// Master switch. Turning it off silences anything still ringing and releases the audio device.
    var enabled = true {
        didSet { if !enabled { stopEngine() } }
    }

    /// True once every buffer is synthesized; until then `play` only kicks off `prepare()`.
    var isReady: Bool { library != nil }

    /// Silence after which the engine is stopped.
    var idleTimeout: TimeInterval = 8

    static let voiceCount = 12
    /// The same SFX retriggered faster than this is dropped: a hundred letters landing at once should sound
    /// like a shower of tinkles, not a buzz.
    static let retriggerGuard: TimeInterval = 0.03

    private static let log = Logger(subsystem: "com.lightstick.whiplash", category: "audio")

    private let engine: AVAudioEngine
    private var voices: VoicePool?
    private var library: [SFX: [AVAudioPCMBuffer]]?
    private var isSynthesizing = false
    private var lastVariant: [SFX: Int] = [:]
    private var lastStart: [SFX: TimeInterval] = [:]
    /// Uptime at which the last scheduled sound finishes.
    private var silentFrom: TimeInterval = 0
    private var idleStop: DispatchWorkItem?
    private var configurationObserver: NSObjectProtocol?
    private var reportedMissingOutput = false

    /// `engine` is injectable so tests can run the real graph in manual-rendering mode, without a device.
    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.engineConfigurationChanged()
        }
    }

    deinit {
        idleStop?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    /// Pre-synthesizes every buffer on a background queue (the engine itself starts on the first `play`).
    /// Safe to call more than once.
    func prepare() {
        guard library == nil, !isSynthesizing else { return }
        isSynthesizing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rendered = SFXSynth.library()
            DispatchQueue.main.async {
                self?.library = rendered
                self?.isSynthesizing = false
            }
        }
    }

    /// Fire-and-forget. `intensity` scales loudness: 1 is the normal level, ≥ 1.25 is full blast, 0 is silent.
    /// `pan` -1 (left) ... 1 (right).
    func play(_ sfx: SFX, intensity: Float = 1, pan: Float = 0) {
        guard enabled else { return }
        guard let variants = library?[sfx], !variants.isEmpty else {
            prepare()
            return
        }
        let loudness = min(1, 0.8 * max(0, intensity))
        guard loudness > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastStart[sfx], now - last < Self.retriggerGuard { return }
        guard let voices = runningVoices() else { return }

        let buffer = variants[nextVariant(of: sfx, count: variants.count)]
        let gain = sfx.mixLevel * loudness * Float.random(in: 0.9...1)
        voices.play(buffer, gain: gain, pan: max(-1, min(1, pan)), now: now)
        lastStart[sfx] = now
        silentFrom = max(silentFrom, now + buffer.duration)
        scheduleIdleStop(now: now)
    }

    // MARK: - Engine lifecycle

    /// The voice pool on a running engine, starting it if needed. nil when there is no usable output device.
    private func runningVoices() -> VoicePool? {
        if engine.isRunning, let voices { return voices }
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount > 0 else {
            if !reportedMissingOutput { Self.log.notice("No audio output device; staying silent.") }
            reportedMissingOutput = true
            return nil
        }
        reportedMissingOutput = false
        let pool = voices ?? VoicePool(engine: engine, count: Self.voiceCount, sampleRate: SFXSynth.sampleRate)
        voices = pool
        do {
            try engine.start()
        } catch {
            Self.log.error("Audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        pool.reset()
        return pool
    }

    private func scheduleIdleStop(now: TimeInterval) {
        idleStop?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.stopEngine() }
        idleStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (silentFrom - now) + idleTimeout, execute: item)
    }

    private func stopEngine() {
        idleStop?.cancel()
        idleStop = nil
        guard engine.isRunning else { return }
        engine.stop()
        voices?.reset()
    }

    /// The hardware changed under us (headphones, AirPods, a display with speakers...) and the system stopped the
    /// engine. Restart right away if we are mid-performance; otherwise the next `play` restarts it lazily.
    private func engineConfigurationChanged() {
        voices?.reset()
        guard enabled, idleStop != nil else { return }
        _ = runningVoices()
    }

    private func nextVariant(of sfx: SFX, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var pick: Int
        if let last = lastVariant[sfx] {
            pick = Int.random(in: 0..<(count - 1))
            if pick >= last { pick += 1 }
        } else {
            pick = Int.random(in: 0..<count)
        }
        lastVariant[sfx] = pick
        return pick
    }
}

/// The playback graph: a fixed pool of stereo player voices → a summing bus → a peak limiter → the main mixer.
///
/// Voices are handed out round-robin, skipping busy ones; when all are busy, the one closest to finishing is
/// stolen. The limiter keeps a pile-up of simultaneous sounds from clipping, and the main mixer's 0.9 output
/// volume caps the final peak.
///
/// Gain and pan are baked into a per-play stereo copy rather than set through the voice's `volume`/`pan`:
/// the mixer ramps those over ~20 ms, so the attack of every sound (the whole of a crack or a tick) would
/// play at the previous sound's level and position.
final class VoicePool {
    private let players: [AVAudioPlayerNode]
    private let stereoFormat: AVAudioFormat?
    private var busyUntil: [TimeInterval]
    private var cursor = 0

    init(engine: AVAudioEngine, count: Int, sampleRate: Double) {
        players = (0..<count).map { _ in AVAudioPlayerNode() }
        busyUntil = Array(repeating: 0, count: count)
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        stereoFormat = stereo
        let bus = AVAudioMixerNode()
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        engine.attach(bus)
        engine.attach(limiter)
        for player in players {
            engine.attach(player)
            engine.connect(player, to: bus, format: stereo)
        }
        engine.connect(bus, to: limiter, format: stereo)
        engine.connect(limiter, to: engine.mainMixerNode, format: stereo)
        // Fast attack so the crack's transient is caught; the limiter's look-ahead equals the attack (2 ms).
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_AttackTime), kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(limiter.audioUnit, AudioUnitParameterID(kLimiterParam_DecayTime), kAudioUnitScope_Global, 0, 0.04, 0)
        engine.mainMixerNode.outputVolume = 0.9
    }

    /// Plays a mono `buffer` at `gain`, panned -1 (left) ... 1 (right). Requires a running engine.
    func play(_ buffer: AVAudioPCMBuffer, gain: Float, pan: Float, now: TimeInterval) {
        guard let stereo = stereoCopy(of: buffer, gain: gain, pan: pan) else { return }
        let index = freeVoice(at: now)
        let player = players[index]
        player.scheduleBuffer(stereo, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        busyUntil[index] = now + buffer.duration
        cursor = (index + 1) % players.count
    }

    /// Balance-law pan (centre = full level in both channels, like AVAudioMixerNode does for mono sources).
    private func stereoCopy(of mono: AVAudioPCMBuffer, gain: Float, pan: Float) -> AVAudioPCMBuffer? {
        guard let stereoFormat, let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: mono.frameLength),
              let source = mono.floatChannelData?[0], let channels = stereo.floatChannelData else { return nil }
        stereo.frameLength = mono.frameLength
        var left = gain * min(1, 1 - pan), right = gain * min(1, 1 + pan)
        vDSP_vsmul(source, 1, &left, channels[0], 1, vDSP_Length(mono.frameLength))
        vDSP_vsmul(source, 1, &right, channels[1], 1, vDSP_Length(mono.frameLength))
        return stereo
    }

    /// Marks every voice idle (after the engine stopped, which stops all players).
    func reset() {
        busyUntil = Array(repeating: 0, count: players.count)
    }

    private func freeVoice(at now: TimeInterval) -> Int {
        for step in 0..<players.count {
            let index = (cursor + step) % players.count
            if busyUntil[index] <= now { return index }
        }
        return busyUntil.indices.min { busyUntil[$0] < busyUntil[$1] } ?? cursor
    }
}
