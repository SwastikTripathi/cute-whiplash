import Foundation

/// Command-line switches. Parsed once in main.swift and handed to whoever needs them.
struct LaunchOptions {
    /// `--demo <name|prefix|all|list>`: render headless demo frames and exit.
    var demo: String?
    /// `--out <dir>`: where demo PNGs go (default `demo-out`).
    var outDir: String = "demo-out"
    /// `--threshold <seconds>`: session-only override of the terminal time limit.
    var thresholdOverride: TimeInterval?
    /// `--whip-now`: run a punishment ~2 s after launch.
    var whipNow = false
    /// `--grab`: start manual whip mode ~2 s after launch.
    var grabNow = false
    /// `--mute`: no sound this session.
    var mute = false
    /// `--no-capture`: never screenshot; use transparent "glass" mode with synthetic text.
    var noCapture = false
    /// `--selftest`: build every subsystem headlessly, exercise it, print a report, exit 0/1.
    var selfTest = false

    init(arguments: [String] = CommandLine.arguments) {
        var it = arguments.dropFirst().makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--demo": demo = it.next() ?? "list"
            case "--out": if let v = it.next() { outDir = v }
            case "--threshold": if let v = it.next(), let s = TimeInterval(v) { thresholdOverride = s }
            case "--whip-now": whipNow = true
            case "--grab": grabNow = true
            case "--mute": mute = true
            case "--no-capture": noCapture = true
            case "--selftest": selfTest = true
            default: break // ignore unknown flags (e.g. -NSDocumentRevisionsDebugMode from Xcode)
            }
        }
    }
}
