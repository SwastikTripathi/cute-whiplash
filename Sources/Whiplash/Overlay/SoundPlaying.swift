import Foundation

/// What the overlay and the coordinator need from the sound system; SoundBoard in the app, a recorder in tests.
protocol SoundPlaying: AnyObject {
    var enabled: Bool { get set }
    func prepare()
    /// `intensity` 0...1+ scales loudness/brightness; `pan` -1 (left) ... 1 (right).
    func play(_ sfx: SFX, intensity: Float, pan: Float)
}

extension SoundBoard: SoundPlaying {}
