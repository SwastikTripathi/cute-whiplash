import Foundation

/// Everything Lash says: the break's taunts and the quips in the island's speech bubble.
enum WhiplashLines {
    /// Shown inside the shattered screen.
    static let taunts = [
        "GO TOUCH GRASS",
        "HYDRATE, NERD",
        "BLINK. STRETCH. BREATHE.",
        "THE TERMINAL WILL STILL BE HERE",
        "sudo take-a-break",
        "STAND UP. NOW.",
        "ctrl+c YOURSELF",
        "git commit -m \"went outside\"",
        "404: SUNLIGHT NOT FOUND",
        "YOUR SPINE FILED A BUG REPORT",
        "exit 0 && go for a walk",
        "LOOK AT SOMETHING 20 FT AWAY",
        "kill -9 $SCREEN_TIME",
        ":wq YOUR SESSION",
    ]

    /// The countdown has started.
    static let warnings = [
        "oh you're gonna get it",
        "five seconds. run.",
        "step. away. from. the. shell.",
        "*cracks knuckles*",
        "I warned you. (I didn't.)",
    ]

    /// You left the terminal in time.
    static let escaped = "phew…"

    /// Enough work without a break: the gentle nudge before the whip.
    static let nudges = [
        "psst. stretch break?",
        "you've been at it a while. walk around?",
        "water. window. wiggle.",
        "look at something far away. I'll wait.",
        "your spine called. it wants a break.",
        "go touch some grass. or else.",
    ]
    /// "Spare me this once": the timer starts over, no whip.
    static let spared = "fine. just this once. 🐶"
    /// The user stepped away during the nudge or countdown: whip called off.
    static let heeded = "good human. enjoy the break 🌱"

    /// Right after a punishment.
    static let aftermath = [
        "that's what you get",
        "feel refreshed?",
        "now go stretch",
        "*wipes whip*",
        "same time tomorrow?",
    ]

    /// You grabbed the whip yourself.
    static let grabbed = [
        "careful, it's loaded",
        "fine. you whip for once",
        "flick it. hard.",
    ]

    /// You gave the whip back.
    static let returned = [
        "not bad. for a human.",
        "okay, give it back",
        "my turn next",
    ]

    /// `--whip-now` / `--grab` wait for the text recognizer to warm up (so the letters can fall).
    static let warmingUp = "sharpening the whip…"
    /// The sound button while `--mute` is on.
    static let muted = "muted by --mute"
    static let busy = "busy. whipping."
    static let snoozed = "fine. napping."
    static let resumed = "I'm baaack"
    /// Whiplash just asked macOS for Screen Recording (once per build identity).
    static let screenAsked = "psst. let me see your screen"
    /// Screen Recording arrived while Whiplash runs: the next shatter is the real thing.
    static let screenGranted = "ooh. I can see your screen now"
    static let armed = "whip: armed"
    static let holstered = "whip: holstered"

    /// A random line from `lines`, avoiding `previous` when there is a choice.
    static func pick<R: RandomNumberGenerator>(from lines: [String], avoiding previous: String? = nil, using rng: inout R) -> String {
        let fresh = lines.filter { $0 != previous }
        return (fresh.isEmpty ? lines : fresh).randomElement(using: &rng) ?? ""
    }
}
