import AppKit
import QuartzCore

/// `--selftest`: builds every subsystem headlessly, exercises it, prints a report and exits 0 (all good) or 1.
/// Modules that are obviously not implemented yet are reported as "stub?" instead of failing.
enum SelfTest {
    private struct Report {
        private(set) var failures = 0

        mutating func pass(_ name: String, _ detail: String) { line("✓", name, detail) }
        mutating func fail(_ name: String, _ detail: String) {
            failures += 1
            line("✗", name, detail)
        }
        /// Not a failure: the module looks like a stub.
        mutating func stub(_ name: String, _ detail: String) { line("~", name, "stub? " + detail) }
        mutating func info(_ name: String, _ detail: String) { line("·", name, detail) }

        private func line(_ mark: String, _ name: String, _ detail: String) {
            print("\(mark) \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(detail)")
        }
    }

    static func run(options: LaunchOptions) -> Never {
        print("Whiplash self-test")
        var report = Report()
        checkSettings(&report)
        checkPlanner(&report)
        warmUpTextRecognition(&report)
        checkScene(&report)
        checkHarvester(&report)
        checkSound(&report)
        checkEnvironment(&report)
        print(report.failures == 0 ? "All good." : "\(report.failures) check(s) failed.")
        exit(report.failures == 0 ? 0 : 1)
    }

    // MARK: - Checks

    private static func checkSettings(_ report: inout Report) {
        let suite = "whiplash.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            report.fail("settings", "could not create an in-memory defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = Settings(defaults: defaults)
        guard fresh.thresholdSeconds == 50 * 60, fresh.enabled, fresh.intensity == 1, fresh.snoozedUntil == nil else {
            report.fail("settings", "unexpected defaults (threshold \(fresh.thresholdSeconds), intensity \(fresh.intensity))")
            return
        }
        fresh.thresholdSeconds = 42
        fresh.snoozedUntil = Date(timeIntervalSinceNow: 60)
        let reloaded = Settings(defaults: defaults)
        guard reloaded.thresholdSeconds == 42, reloaded.isSnoozed else {
            report.fail("settings", "values did not survive a reload")
            return
        }
        reloaded.snoozedUntil = nil
        guard Settings(defaults: defaults).snoozedUntil == nil else {
            report.fail("settings", "clearing snoozedUntil did not persist")
            return
        }
        report.pass("settings", "defaults, persistence and clearing work")
    }

    private static func checkPlanner(_ report: inout Report) {
        let normal = (0...4).map { PunishmentPlanner.strikeCount(escalationLevel: $0, intensity: 1) }
        let gentle = PunishmentPlanner.strikeCount(escalationLevel: 0, intensity: 0.5)
        let unhinged = PunishmentPlanner.strikeCount(escalationLevel: 0, intensity: 2)
        guard normal == [2, 3, 4, 5, 6], gentle == 1, unhinged == 4 else {
            report.fail("planner", "strikes \(normal), gentle \(gentle), unhinged \(unhinged)")
            return
        }
        report.pass("planner", "strikes by escalation \(normal), gentle \(gentle), unhinged \(unhinged)")
    }

    /// What the app does at launch (see `TextHarvester.prewarm`): the first text request of a new binary can take
    /// tens of seconds while macOS compiles Vision's model, which would starve the scene check of its letters.
    private static func warmUpTextRecognition(_ report: inout Report) {
        let started = CACurrentMediaTime()
        var warm = false
        TextHarvester.prewarm { warm = true }
        let deadline = Date().addingTimeInterval(120)
        while !warm, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let elapsed = CACurrentMediaTime() - started
        if warm {
            report.info("ocr warm-up", String(format: "%.1f s%@", elapsed, elapsed > 5 ? " (Vision compiled its text model)" : ""))
        } else {
            report.fail("ocr warm-up", "Vision's text recognizer did not warm up within 120 s")
        }
    }

    /// A full 3-strike punishment over the fake desktop, stepped at 60 fps for at most 20 simulated seconds.
    private static func checkScene(_ report: inout Report) {
        let size = DemoDefaults.screenSize
        var plan = PunishmentPlan()
        plan.strikes = 3
        plan.targetRect = FakeBackdrop.terminalRect(for: size)
        plan.backdrop = FakeBackdrop.snapshot(size: size)
        plan.message = "SELF-TEST"
        let scene = PunishmentScene(plan: plan, screenFrame: CGRect(origin: .zero, size: size),
                                    anchor: IslandLayout.whipGrip(for: NotchGeometry.demo(size: size)), seed: 7)
        let sound = CountingSound()
        scene.sound = sound
        guard let renderer = OffscreenRenderer(scene: scene, pointSize: size) else {
            report.fail("scene", "Metal unavailable")
            return
        }
        let fps = 60.0
        // SKRenderer treats a first update at time 0 as "now" and then ignores every later (smaller) time,
        // so the clock starts at 1 s.
        let timeBase = 1.0
        var updateTimes: [Double] = []
        var renderTimes: [Double] = []
        var finishedAt: Double?
        for frame in 0...Int(20 * fps) {
            let time = Double(frame) / fps
            let started = CACurrentMediaTime()
            renderer.update(atTime: timeBase + time)
            updateTimes.append((CACurrentMediaTime() - started) * 1000)
            if frame == 0 { scene.waitForGlyphs(timeout: 15) }
            if frame % 30 == 0 {
                let renderStarted = CACurrentMediaTime()
                _ = renderer.snapshot()
                renderTimes.append((CACurrentMediaTime() - renderStarted) * 1000)
            }
            if scene.isFinished {
                finishedAt = time
                break
            }
        }
        let sequencer = scene.sequencer
        let average = updateTimes.reduce(0, +) / Double(max(1, updateTimes.count))
        let worst = updateTimes.max() ?? 0
        let worstRender = renderTimes.max() ?? 0
        let timing = String(format: "update avg %.2f ms, max %.1f ms; render+readback max %.1f ms", average, worst, worstRender)
        guard let finishedAt else {
            report.fail("scene", "did not finish within 20 s (stuck in \(sequencer.phase)); \(timing)")
            return
        }
        guard sequencer.crackCount >= 3, sequencer.didShatter else {
            report.fail("scene", "cracks \(sequencer.crackCount)/3, shattered: \(sequencer.didShatter)")
            return
        }
        guard average < 16, worst < 500 else {
            report.fail("scene", "frame times out of budget: \(timing)")
            return
        }
        report.pass("scene", String(format: "3 strikes → %d cracks → shatter → finished at %.1f s; %@",
                                    sequencer.crackCount, finishedAt, timing))
        report.info("sounds", sound.summary)
        if scene.stats.whipCracks == 0 {
            report.stub("whip", "WhipNode never reported a crack (\(sequencer.fallbackCrackCount) fallback cracks)")
        } else {
            report.pass("whip", "\(scene.stats.whipCracks) cracks reported by the whip itself")
        }
        if scene.stats.glyphsDelivered == 0 {
            report.stub("glyphs", "no text reached the DestructionLayer")
        } else {
            report.pass("glyphs", "\(scene.stats.glyphsDelivered) harvested glyphs fell off the screen")
        }
    }

    private static func checkHarvester(_ report: inout Report) {
        let size = DemoDefaults.screenSize
        let snapshot = FakeBackdrop.snapshot(size: size)
        let terminal = FakeBackdrop.terminalRect(for: size)
        let truth = FakeBackdrop.groundTruthGlyphs(size: size).count
        let started = CACurrentMediaTime()
        guard let glyphs = awaitResult(timeout: 20, {
            await TextHarvester.harvest(from: snapshot, focus: terminal, maxGlyphs: 900)
        }) else {
            report.fail("harvest", "OCR did not finish within 20 s")
            return
        }
        let elapsed = (CACurrentMediaTime() - started) * 1000
        if glyphs.isEmpty {
            report.stub("harvest", "OCR returned no glyphs")
        } else {
            report.pass("harvest", String(format: "%d glyphs in %.0f ms (terminal ground truth: %d)", glyphs.count, elapsed, truth))
        }
        let synthetic = TextHarvester.synthetic(in: terminal, maxGlyphs: 500)
        if synthetic.isEmpty {
            report.stub("synthetic", "no synthetic glyphs")
        } else if synthetic.count > 500 || synthetic.contains(where: { !terminal.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }) {
            report.fail("synthetic", "\(synthetic.count) glyphs, some outside the region or over the cap")
        } else {
            report.pass("synthetic", "\(synthetic.count) glyphs inside the terminal")
        }
    }

    private static func checkSound(_ report: inout Report) {
        let started = CACurrentMediaTime()
        SoundBoard.shared.prepare()
        report.pass("sound", String(format: "prepared in %.0f ms", (CACurrentMediaTime() - started) * 1000))
    }

    private static func checkEnvironment(_ report: inout Report) {
        let screens = NSScreen.screens.map { screen -> String in
            let notch = NotchGeometry.forScreen(screen).hasPhysicalNotch ? ", notch" : ""
            return "\(screen.localizedName) \(Int(screen.frame.width))×\(Int(screen.frame.height))\(notch)"
        }
        report.info("screens", screens.isEmpty ? "none" : screens.joined(separator: "; "))
        report.info("capture", ScreenGrabber.hasPermission ? "Screen Recording granted" : "Screen Recording not granted (glass mode)")
    }

    // MARK: - Helpers

    /// Runs async work from this synchronous, main-thread context, spinning the run loop so work that hops to
    /// the main queue can still finish. nil on timeout.
    private static func awaitResult<T>(timeout: TimeInterval, _ work: @escaping () async -> T) -> T? {
        let box = ResultBox<T>()
        Task.detached { box.set(await work()) }
        let deadline = Date().addingTimeInterval(timeout)
        while box.value == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?

        var value: T? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func set(_ value: T) {
            lock.lock()
            stored = value
            lock.unlock()
        }
    }

    /// Counts what would have been played, so the self-test stays silent.
    private final class CountingSound: SoundPlaying {
        var enabled = true
        private var counts: [SFX: Int] = [:]

        func prepare() {}

        func play(_ sfx: SFX, intensity: Float, pan: Float) {
            counts[sfx, default: 0] += 1
        }

        var summary: String {
            SFX.allCases.compactMap { sfx in counts[sfx].map { "\(sfx)×\($0)" } }.joined(separator: " ")
        }
    }
}
