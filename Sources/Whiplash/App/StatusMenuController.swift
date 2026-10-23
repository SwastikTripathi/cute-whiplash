import AppKit
import ServiceManagement

/// The menu-bar item: a tiny whip glyph whose menu mirrors the island and holds the preferences.
/// State is re-read as the menu opens (and live while it is open), never polled.
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let thresholdPresets: [(title: String, seconds: TimeInterval)] = [
        ("25 Minutes", 1500), ("30 Minutes", 1800), ("45 Minutes", 2700), ("50 Minutes", 3000),
        ("60 Minutes", 3600), ("90 Minutes", 5400),
    ]
    static let intensityPresets: [(title: String, value: Double)] = [
        ("Gentle", 0.5), ("Normal", 1), ("Unhinged", 2),
    ]

    private static let overrideTag = -1

    private unowned let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var isOpen = false

    private let headerItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let whipNowItem = NSMenuItem(title: "Whip Me Now", action: #selector(whipNow), keyEquivalent: "")
    private let grabItem = NSMenuItem(title: "Grab the Whip", action: #selector(grabWhip), keyEquivalent: "")
    private let spareItem = NSMenuItem(title: "Spare Me This Once", action: #selector(spareOnce), keyEquivalent: "")
    private let snoozeItem = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: "")
    private let thresholdMenu = NSMenu()
    private let intensityMenu = NSMenu()
    private let placementMenu = NSMenu()
    static let placementPresets: [(title: String, placement: IslandPlacement)] = [
        ("Around the Notch", .aroundNotch), ("Beside the Notch", .beside),
    ]
    private let soundItem = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
    private let autoWhipItem = NSMenuItem(title: "Auto-Whip", action: #selector(toggleAutoWhip), keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "Real Screen Shattering…", action: #selector(toggleCapture), keyEquivalent: "")
    private let relaunchItem = NSMenuItem(title: "Relaunch to Finish Enabling", action: #selector(relaunch), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = StatusBarIcon.image
        statusItem.button?.toolTip = "Whiplash"
        buildMenu()
        statusItem.menu = menu
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Refreshes the menu if it is open right now (the streak ticks live in the header).
    func refreshIfOpen() {
        if isOpen { refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = true
        coordinator.refreshForDisplay()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        isOpen = false
    }

    // MARK: - Building

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        headerItem.isEnabled = false
        detailItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        menu.addItem(target(whipNowItem))
        menu.addItem(target(grabItem))
        spareItem.toolTip = "Reset the work timer: no whip this time"
        menu.addItem(target(spareItem))
        menu.addItem(.separator())

        let snoozeMenu = NSMenu()
        snoozeMenu.addItem(target(NSMenuItem(title: "15 Minutes", action: #selector(snoozeFor(_:)), keyEquivalent: ""), tag: 15 * 60))
        snoozeMenu.addItem(target(NSMenuItem(title: "1 Hour", action: #selector(snoozeFor(_:)), keyEquivalent: ""), tag: 60 * 60))
        snoozeMenu.addItem(target(NSMenuItem(title: "Rest of Day", action: #selector(snoozeRestOfDay), keyEquivalent: "")))
        snoozeItem.submenu = snoozeMenu
        menu.addItem(snoozeItem)
        menu.addItem(target(resumeItem))

        for preset in Self.thresholdPresets {
            let item = NSMenuItem(title: preset.title, action: #selector(pickThreshold(_:)), keyEquivalent: "")
            thresholdMenu.addItem(target(item, tag: Int(preset.seconds)))
        }
        let thresholdItem = NSMenuItem(title: "Break Reminder After", action: nil, keyEquivalent: "")
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        for (index, preset) in Self.intensityPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(pickIntensity(_:)), keyEquivalent: "")
            intensityMenu.addItem(target(item, tag: index))
        }
        let intensityItem = NSMenuItem(title: "Intensity", action: nil, keyEquivalent: "")
        intensityItem.submenu = intensityMenu
        menu.addItem(intensityItem)

        for (index, preset) in Self.placementPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(pickPlacement(_:)), keyEquivalent: "")
            placementMenu.addItem(target(item, tag: index))
        }
        let placementItem = NSMenuItem(title: "Island Position", action: nil, keyEquivalent: "")
        placementItem.submenu = placementMenu
        menu.addItem(placementItem)
        menu.addItem(.separator())

        menu.addItem(target(soundItem))
        menu.addItem(target(autoWhipItem))
        menu.addItem(target(captureItem))
        relaunchItem.toolTip = "Switched Whiplash on in System Settings but it still can't see the screen? macOS may "
            + "only apply the permission to a fresh copy."
        menu.addItem(target(relaunchItem))
        menu.addItem(target(loginItem))
        menu.addItem(.separator())
        menu.addItem(target(NSMenuItem(title: "About Whiplash", action: #selector(showAbout), keyEquivalent: "")))
        menu.addItem(target(NSMenuItem(title: "Quit Whiplash", action: #selector(quit), keyEquivalent: "q")))
    }

    private func target(_ item: NSMenuItem, tag: Int = 0) -> NSMenuItem {
        item.target = self
        item.tag = tag
        return item
    }

    // MARK: - Refreshing

    private func refresh() {
        let model = coordinator.model
        let settings = coordinator.settings
        headerItem.attributedTitle = NSAttributedString(
            string: Self.workLine(work: model.streakSeconds, threshold: model.thresholdSeconds),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
        detailItem.title = Self.detailLine(phase: model.phase, whipsToday: model.whipsToday, totalWhips: model.totalWhips)

        whipNowItem.isEnabled = !coordinator.isPunishing
        spareItem.isEnabled = !coordinator.isPunishing && (model.streakSeconds >= 1 || coordinator.nudgeSecondsLeft != nil
                                                           || coordinator.countdownSecondsLeft != nil)
        grabItem.isEnabled = !coordinator.isBusy
        resumeItem.isHidden = !coordinator.isSnoozed

        // A --threshold override shows as an extra checked "(this session)" entry below the presets.
        let threshold = coordinator.tracker.effectiveThreshold
        let overridden = coordinator.tracker.thresholdOverride != nil
        if let custom = thresholdMenu.item(withTag: Self.overrideTag) { thresholdMenu.removeItem(custom) }
        for item in thresholdMenu.items {
            item.state = !overridden && TimeInterval(item.tag) == threshold ? .on : .off
        }
        if overridden {
            let custom = NSMenuItem(title: "\(Self.clock(threshold)) (this session)", action: nil, keyEquivalent: "")
            custom.tag = Self.overrideTag
            custom.state = .on
            custom.isEnabled = false
            thresholdMenu.addItem(custom)
        }

        for item in placementMenu.items {
            item.state = Self.placementPresets[item.tag].placement == settings.islandPlacement ? .on : .off
        }
        for item in intensityMenu.items {
            item.state = abs(Self.intensityPresets[item.tag].value - settings.intensity) < 0.01 ? .on : .off
        }

        soundItem.state = settings.soundEnabled && !coordinator.options.mute ? .on : .off
        soundItem.isEnabled = !coordinator.options.mute
        soundItem.title = coordinator.options.mute ? "Sound (muted by --mute)" : "Sound"
        autoWhipItem.state = settings.enabled ? .on : .off

        let granted = model.screenCaptureGranted
        captureItem.title = granted ? "Real Screen Shattering" : "Real Screen Shattering… (needs Screen Recording)"
        captureItem.state = granted && settings.useScreenCapture && !coordinator.options.noCapture ? .on : .off
        captureItem.isEnabled = !coordinator.options.noCapture
        relaunchItem.isHidden = granted || !model.screenCaptureRelaunchOffered
        relaunchItem.isEnabled = !coordinator.isBusy

        let bundled = Self.isRunningFromAppBundle
        loginItem.isEnabled = bundled
        loginItem.title = bundled ? "Launch at Login" : "Launch at Login (needs Whiplash.app)"
        loginItem.state = bundled && SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// "Working 34:12 / 50:00" — the live header: work since the last real break.
    static func workLine(work: TimeInterval, threshold: TimeInterval) -> String {
        work >= 1 ? "Working \(clock(work)) / \(clock(threshold))" : "Rested · break reminder after \(clock(threshold)) of work"
    }

    static func detailLine(phase: IslandPhase, whipsToday: Int, totalWhips: Int) -> String {
        switch phase {
        case .nudge(let secondsLeft): return "Break time! Step away, or the whip comes out in \(clock(TimeInterval(secondsLeft)))"
        case .warning(let secondsLeft): return "The whip comes out in \(secondsLeft)…"
        case .whipping: return "CRACK!"
        case .manual: return "You have the whip. Esc to give it back."
        case .aftermath: return "Punished. Go stretch."
        case .snoozed(let until): return "Snoozed until \(until.formatted(date: .omitted, time: .shortened))"
        case .disabled: return "Auto-whip is off"
        case .idle: return "Whipped \(whipsToday)× today · \(totalWhips) all-time"
        }
    }

    /// "1:23", or "1:02:03" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total / 60 % 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    private static var isRunningFromAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: - Actions

    @objc private func whipNow() { coordinator.punish() }
    @objc private func spareOnce() { coordinator.spareOnce() }
    @objc private func grabWhip() { coordinator.grabWhip() }
    @objc private func snoozeFor(_ sender: NSMenuItem) { coordinator.snooze(for: TimeInterval(sender.tag)) }
    @objc private func snoozeRestOfDay() { coordinator.snoozeRestOfDay() }
    @objc private func resume() { coordinator.resume() }
    @objc private func pickThreshold(_ sender: NSMenuItem) { coordinator.setThreshold(TimeInterval(sender.tag)) }
    @objc private func pickIntensity(_ sender: NSMenuItem) { coordinator.setIntensity(Self.intensityPresets[sender.tag].value) }
    @objc private func pickPlacement(_ sender: NSMenuItem) { coordinator.settings.islandPlacement = Self.placementPresets[sender.tag].placement }
    @objc private func toggleSound() { coordinator.toggleSound() }
    @objc private func toggleAutoWhip() { coordinator.toggleAutoWhip() }
    @objc private func toggleCapture() { coordinator.toggleRealShattering() }
    @objc private func relaunch() { coordinator.relaunchForScreenCapture() }
    @objc private func quit() { coordinator.quit() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            coordinator.say("macOS said no: \(error.localizedDescription)")
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "Lash lives in your notch and has opinions about your screen time.\n"
                + "Everything you see and hear is drawn and synthesized in code.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Whiplash", .credits: credits])
    }
}

/// The menu-bar glyph: a whip handle, its lash tapering through an S-curve and a spark where it cracks.
/// A template image drawn in code on an 18-point grid.
enum StatusBarIcon {
    static let image = makeImage(pointSize: 18)

    /// The glyph at any size (the grid scales), e.g. for crisp previews.
    static func makeImage(pointSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: false) { _ in
            let scale = pointSize / 18
            NSColor.black.setStroke()
            func stroke(_ path: NSBezierPath, width: CGFloat) {
                path.transform(using: AffineTransform(scale: scale))
                path.lineWidth = width * scale
                path.lineCapStyle = .round
                path.stroke()
            }
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 2.2, y: 2.2))
            handle.line(to: NSPoint(x: 5.8, y: 5.8))
            stroke(handle, width: 3.2)

            let thick = NSBezierPath()
            thick.move(to: NSPoint(x: 5.8, y: 5.8))
            thick.curve(to: NSPoint(x: 8.2, y: 12.8), controlPoint1: NSPoint(x: 10.5, y: 7.2), controlPoint2: NSPoint(x: 4.6, y: 10.6))
            stroke(thick, width: 1.7)

            let thin = NSBezierPath()
            thin.move(to: NSPoint(x: 8.2, y: 12.8))
            thin.curve(to: NSPoint(x: 14.2, y: 12.6), controlPoint1: NSPoint(x: 11.2, y: 14.8), controlPoint2: NSPoint(x: 12.2, y: 10.6))
            stroke(thin, width: 1.2)

            let tip = NSPoint(x: 14.2, y: 12.6)
            let spark = NSBezierPath()
            for (dx, dy) in [(0.15, 1.0), (0.85, 0.55), (1.0, -0.35)] as [(CGFloat, CGFloat)] {
                spark.move(to: NSPoint(x: tip.x + dx * 1.5, y: tip.y + dy * 1.5))
                spark.line(to: NSPoint(x: tip.x + dx * 3.1, y: tip.y + dy * 3.1))
            }
            stroke(spark, width: 1.1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Whiplash"
        return image
    }
}
