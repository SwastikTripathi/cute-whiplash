import SwiftUI

/// What Lash's face shows: its mood, or a short-lived reaction that overrides the mood.
enum LashExpression: Equatable {
    case mood(CritterMood)
    /// Poked too much: spiral eyes, orbiting stars.
    case dizzy
    /// Being petted: happy-closed eyes, big blush.
    case blissful

    /// Whether the face has time-based motion worth animating (steam, laughing, spinning eyes, floating Zzz).
    var hasMotion: Bool {
        switch self {
        case .mood(.furious), .mood(.maniacal), .mood(.sleepy), .dizzy: return true
        case .mood, .blissful: return false
        }
    }
}

/// Every drawable parameter of one facial expression, in Lash's 100×100 unit box.
struct LashFace {
    struct Lids {
        /// 1 = wide open, 0 = shut.
        var open: CGFloat = 1
        /// > 0 lowers the inner (nose-side) end of the top lid: angry. < 0 lowers the outer end: sad/smug.
        var slant: CGFloat = 0
        /// How far the lower lid rises, 0...1 of the eye height.
        var lower: CGFloat = 0
        var pupil: CGFloat = 1
        var leftScale: CGFloat = 1
        var rightScale: CGFloat = 1
    }

    enum Eyes {
        case open(Lids)
        /// "> <" — laughing too hard to look.
        case squeezed
        /// "‿ ‿" — asleep.
        case closed
        /// "^ ^" — bliss.
        case joyful
        /// "@ @" — dizzy.
        case spiral
    }

    enum Mouth { case smile, oh, flat, wavy, gritted, laugh, smirk, snore, wobble }

    /// One eyebrow: y of its outer and inner ends, and how much its middle arches up.
    struct Brow {
        var outer: CGFloat
        var inner: CGFloat
        var arch: CGFloat = 0
    }

    enum Motion { case still, shake, cackle, wobble, breathe }

    /// Fur colours: a top→bottom gradient for the face, the eyelids, an outline that separates Lash from the black
    /// island, the pink inside of the ears, and the big fluffy ruff around the face.
    struct Skin {
        var top: Color
        var bottom: Color
        var lid: Color
        var rim: Color
        var innerEar: Color
        var ruff: Color

        private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b) }

        /// A fluffy white Samoyed.
        static let fur = Skin(top: rgb(1.0, 0.995, 0.985), bottom: rgb(0.90, 0.90, 0.93),
                              lid: rgb(0.96, 0.96, 0.97), rim: rgb(0.62, 0.62, 0.69),
                              innerEar: rgb(0.97, 0.78, 0.81), ruff: rgb(0.93, 0.93, 0.96))
        /// Hackles up: flushed pink-red.
        static let furious = Skin(top: rgb(1.0, 0.84, 0.81), bottom: rgb(0.96, 0.60, 0.58),
                                  lid: rgb(0.99, 0.76, 0.73), rim: rgb(0.74, 0.28, 0.28),
                                  innerEar: rgb(1.0, 0.58, 0.58), ruff: rgb(0.98, 0.72, 0.70))
        /// Cackling with the whip: tinged lilac.
        static let maniacal = Skin(top: rgb(0.96, 0.91, 1.0), bottom: rgb(0.81, 0.73, 0.93),
                                   lid: rgb(0.91, 0.85, 0.98), rim: rgb(0.55, 0.42, 0.72),
                                   innerEar: rgb(0.91, 0.74, 0.95), ruff: rgb(0.87, 0.80, 0.97))
        /// Dozing: the white a little dimmer.
        static let sleepy = Skin(top: rgb(0.93, 0.93, 0.95), bottom: rgb(0.80, 0.80, 0.84),
                                 lid: rgb(0.88, 0.88, 0.91), rim: rgb(0.55, 0.55, 0.62),
                                 innerEar: rgb(0.88, 0.74, 0.78), ruff: rgb(0.84, 0.84, 0.88))
    }

    var eyes: Eyes
    var brows: (left: Brow, right: Brow)?
    var mouth: Mouth
    /// Blush opacity 0...1.
    var cheeks: CGFloat = 0
    var skin = Skin.fur
    /// Halo behind the head.
    var glow: Color?
    /// Head tilt in degrees (positive = clockwise).
    var tilt: Double = 0
    var steam = false
    var angerMark = false
    var zzz = false
    var stars = false
    var motion: Motion = .still

    init(_ expression: LashExpression) {
        switch expression {
        case .mood(let mood): self = LashFace.forMood(mood)
        case .dizzy:
            self.init(eyes: .spiral, mouth: .wobble)
            brows = (Brow(outer: 33, inner: 36.5, arch: 1), Brow(outer: 38, inner: 34, arch: 0.5))
            stars = true
            motion = .wobble
        case .blissful:
            self.init(eyes: .joyful, mouth: .smile)
            brows = (Brow(outer: 36, inner: 34, arch: 2.5), Brow(outer: 36, inner: 34, arch: 2.5))
            cheeks = 1
            tilt = -6
        }
    }

    private init(eyes: Eyes, mouth: Mouth) {
        self.eyes = eyes
        self.mouth = mouth
    }

    private static func forMood(_ mood: CritterMood) -> LashFace {
        switch mood {
        case .happy:
            var face = LashFace(eyes: .open(Lids()), mouth: .smile)
            face.brows = (Brow(outer: 36.5, inner: 35, arch: 2.5), Brow(outer: 36.5, inner: 35, arch: 2.5))
            face.cheeks = 1
            return face
        case .curious:
            var face = LashFace(eyes: .open(Lids(pupil: 1.12, leftScale: 1.1, rightScale: 0.92)), mouth: .oh)
            face.brows = (Brow(outer: 31, inner: 30.5, arch: 3), Brow(outer: 38, inner: 37.5, arch: 0.5))
            face.tilt = -11
            return face
        case .suspicious:
            var face = LashFace(eyes: .open(Lids(open: 0.46, slant: 0.12, lower: 0.2, pupil: 0.95)), mouth: .wavy)
            face.brows = (Brow(outer: 38.5, inner: 40, arch: -0.5), Brow(outer: 36, inner: 38, arch: 0))
            face.tilt = 4
            return face
        case .annoyed:
            var face = LashFace(eyes: .open(Lids(open: 0.56, slant: 0.02, lower: 0.06, pupil: 0.9)), mouth: .flat)
            face.brows = (Brow(outer: 37, inner: 39.5), Brow(outer: 37, inner: 39.5))
            return face
        case .furious:
            var face = LashFace(eyes: .open(Lids(open: 0.78, slant: 0.5, lower: 0.08, pupil: 0.72)), mouth: .gritted)
            face.brows = (Brow(outer: 32, inner: 42.5, arch: -1), Brow(outer: 32, inner: 42.5, arch: -1))
            face.skin = .furious
            face.glow = Color(.sRGB, red: 1.0, green: 0.20, blue: 0.15)
            face.steam = true
            face.angerMark = true
            face.motion = .shake
            return face
        case .maniacal:
            var face = LashFace(eyes: .squeezed, mouth: .laugh)
            face.brows = (Brow(outer: 31, inner: 40, arch: -1.5), Brow(outer: 31, inner: 40, arch: -1.5))
            face.skin = .maniacal
            face.glow = IslandPalette.mania
            face.motion = .cackle
            return face
        case .smug:
            var face = LashFace(eyes: .open(Lids(open: 0.5, slant: -0.1, lower: 0.14)), mouth: .smirk)
            face.brows = (Brow(outer: 38.5, inner: 38, arch: 0.5), Brow(outer: 31.5, inner: 34, arch: 2))
            face.cheeks = 0.45
            face.tilt = 6
            return face
        case .sleepy:
            var face = LashFace(eyes: .closed, mouth: .snore)
            face.brows = (Brow(outer: 40, inner: 38, arch: 0.8), Brow(outer: 40, inner: 38, arch: 0.8))
            face.skin = .sleepy
            // Nodding off to the left leaves the space above the right ear free for the Zzz.
            face.tilt = -9
            face.zzz = true
            face.motion = .breathe
            return face
        }
    }
}
