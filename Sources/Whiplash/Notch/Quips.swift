import Foundation

/// What Lash is talking about.
enum QuipTopic: Hashable {
    /// Poked while in this mood.
    case mood(CritterMood)
    /// Poked five times in two seconds.
    case dizzy
    /// Rubbed back and forth.
    case petted
    /// The warning was dodged by leaving the terminal.
    case relief
    /// Just got snoozed.
    case snoozed
    /// A few head pats in a row.
    case headPats
    /// Double-clicked into a happy spin.
    case spun
    /// Woken from a nap by the cursor.
    case wokeUp
}

/// Everything Lash can say.
enum QuipBook {
    static func lines(for topic: QuipTopic) -> [String] {
        switch topic {
        case .mood(let mood): return moodLines[mood] ?? []
        case .dizzy: return [
            "the notch is spinning",
            "wheee… stop… wheee",
            "I see seven cursors",
            "ok ok ok I'm dizzy",
            "who poked the puppy",
            "my ears are ringing",
        ]
        case .headPats: return [
            "pat pat pat 🥹",
            "head pats?? for ME??",
            "okay. okay. keep going.",
            "I'm still a menace. pat.",
            "…this changes nothing. more.",
            "my ears are very soft actually",
        ]
        case .spun: return [
            "wheee!",
            "again! AGAIN!",
            "dizzy in a good way",
            "360 no scope",
            "I can see my own tail",
            "spin to win",
        ]
        case .wokeUp: return [
            "…wasn't sleeping",
            "oh! you're back",
            "I was guarding the notch. with my eyes closed.",
            "5 more minutes…",
            "hi. I missed you. shut up.",
            "nap interrupted. worth it.",
        ]
        case .petted: return [
            "…okay that's nice",
            "*tail wag*. tell no one.",
            "scritches accepted, old sport",
            "still dangerous. purr.",
            "more. left. yes. there.",
            "fine. you can stay.",
        ]
        case .relief: return [
            "splendid decision, old chap",
            "coward. (smart coward)",
            "saved by the alt-tab",
            "the whip will remember this",
            "lucky. very lucky.",
            "fine. go live your life.",
        ]
        case .snoozed: return [
            "fine. nap time.",
            "whip's off duty",
            "wake me when you're bad",
            "dreaming of you. menacingly.",
            "don't do anything I'd whip",
            "zzz… (still watching)",
        ]
        }
    }

    private static let moodLines: [CritterMood: [String]] = [
        .happy: [
            "good day. I'm Lash. I bite.",
            "no terminal? proud of you.",
            "look at you, touching grass",
            "a gentleman AND violent",
            "boop me again, I dare you",
            "fresh pixels. mmm.",
            "sunlight looks good on you",
        ],
        .curious: [
            "ooh, what are we typing?",
            "is that a semicolon?",
            "sudo make me a sandwich?",
            "observing. monocle ready.",
            "what does this button do",
            "compiling feelings…",
        ],
        .suspicious: [
            "that's a lot of terminal",
            "I see you, keyboard goblin",
            "blinked yet today?",
            "hmm. still here, huh",
            "I'm counting, you know",
            "git commit -m 'help'?",
        ],
        .annoyed: [
            "your chair misses your legs",
            "hydrate or I whip",
            "one more ls. go on.",
            "I'm warming up the whip",
            "stretch. now. please.",
            "the sun called. no answer.",
        ],
        .furious: [
            "THAT'S IT. WHIP TIME.",
            "I WARNED YOU. TWICE.",
            "step AWAY from the shell",
            "RAAAH. touch grass!!",
            "my whip hand is itchy",
            "you asked for this",
        ],
        .maniacal: [
            "HAHAHAHAHA",
            "CRACK CRACK CRACK",
            "your pixels are MINE",
            "whee!! glass everywhere!",
            "this is my cardio",
            "bye bye, semicolons!",
        ],
        .smug: [
            "feel better?",
            "you're welcome.",
            "nice screen. shame about it.",
            "that's the stretch you needed",
            "same time tomorrow?",
            "10/10 crack. no notes.",
        ],
        .sleepy: [
            "zzz… five more minutes…",
            "shh. whip's asleep.",
            "dreaming of broken glass",
            "wake me if you ssh",
            "mmh… no pokes…",
            "honk shoo… honk shoo…",
        ],
    ]

    /// A calm one-liner for the dashboard when Lash has nothing to say.
    static func status(for mood: CritterMood) -> String {
        switch mood {
        case .happy: return "all clear — no terminal in sight"
        case .curious: return "watching you type…"
        case .suspicious: return "that's a lot of terminal…"
        case .annoyed: return "the whip is warming up"
        case .furious: return "about to snap"
        case .maniacal: return "CRACK!"
        case .smug: return "feeling very smug"
        case .sleepy: return "snoozing. the whip is off duty."
        }
    }

    /// The countdown line, a different threat each second.
    static func warning(secondsLeft: Int) -> String {
        switch secondsLeft {
        case ...0: return "CRACK."
        case 1: return "1. say bye to your pixels"
        case 2: return "2!! last chance, keyboard goblin"
        case 3: return "3! hands off the keys. NOW."
        case 4: return "4… I can hear the whip humming"
        case 5: return "5 seconds. you ignored me."
        default: return "\(secondsLeft) seconds. tick tock."
        }
    }

    /// The break suggestion, by how long the user has been at it.
    static func nudge(workSeconds: TimeInterval) -> String {
        let minutes = Int(workSeconds / 60)
        return minutes >= 5 ? "\(minutes) min, no break. stretch, sip water." : "break time. stretch, sip water."
    }
}

/// Picks quips like a shuffled deck: every line of a topic comes up once before any repeats,
/// and the same line never shows twice in a row.
struct QuipPicker {
    private var decks: [QuipTopic: [String]] = [:]
    private var last: [QuipTopic: String] = [:]

    mutating func next<G: RandomNumberGenerator>(for topic: QuipTopic, using rng: inout G) -> String {
        var deck = decks[topic] ?? []
        if deck.isEmpty {
            deck = QuipBook.lines(for: topic).shuffled(using: &rng)
            // Don't start the new deck with the line that ended the previous one.
            if deck.count > 1, deck.last == last[topic] { deck.swapAt(0, deck.count - 1) }
        }
        guard let line = deck.popLast() else { return "" }
        decks[topic] = deck
        last[topic] = line
        return line
    }

    mutating func next(for topic: QuipTopic) -> String {
        var rng = SystemRandomNumberGenerator()
        return next(for: topic, using: &rng)
    }
}
