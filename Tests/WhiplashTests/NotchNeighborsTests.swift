import XCTest
@testable import Whiplash

/// Sharing the notch with another island app (Sapphire, NotchNook, …).
final class NotchNeighborsTests: XCTestCase {
    /// The user's 16" MacBook Pro: 2056×1329 pt, a 220×38 pt notch.
    private let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)
    private let notch = CGRect(x: 918, y: 1291, width: 220, height: 38)

    private func window(_ owner: String, pid: Int32 = 500, layer: Int = 25, quartz: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowLayer as String: NSNumber(value: layer), kCGWindowAlpha as String: NSNumber(value: alpha),
         kCGWindowBounds as String: quartz.dictionaryRepresentation]
    }

    func testFindsAnotherAppsIslandOverTheNotch() {
        // Sapphire as measured on the user's Mac: 322×56 at y -9 (Quartz), layer 25.
        let windows = [
            window("Sapphire", pid: 656, quartz: CGRect(x: 867, y: -9, width: 322, height: 56)),
            window("Window Server", pid: 1, layer: 24, quartz: CGRect(x: 0, y: 0, width: 2056, height: 39)),
            window("Whiplash", pid: 42, layer: 27, quartz: CGRect(x: 758, y: 0, width: 540, height: 222)),
            window("Dropbox", pid: 700, layer: 25, quartz: CGRect(x: 1700, y: 0, width: 30, height: 37)), // a status item
            window("kitty", pid: 800, layer: 0, quartz: CGRect(x: 0, y: 39, width: 2056, height: 1290)),
        ]
        let islands = NotchNeighbors.islands(over: notch, screen: screen, in: windows, excluding: 42, primaryHeight: 1329)
        XCTAssertEqual(islands.map(\.owner), ["Sapphire"])
        XCTAssertEqual(islands.first?.frame, CGRect(x: 867, y: 1329 - 47, width: 322, height: 56))
    }

    func testHiddenOrHugeWindowsAreNotIslands() {
        let windows = [
            window("Ghost", quartz: CGRect(x: 867, y: 0, width: 322, height: 40), alpha: 0),
            window("Fullscreen HUD", quartz: CGRect(x: 0, y: 0, width: 2056, height: 1329)),
        ]
        XCTAssertTrue(NotchNeighbors.islands(over: notch, screen: screen, in: windows, excluding: 42, primaryHeight: 1329).isEmpty)
    }

    func testBesideSitsLeftOfTheNeighbourWithAGap() {
        let geometry = NotchGeometry(screenFrame: screen, notchRect: notch, hasPhysicalNotch: true, menuBarHeight: 38)
        let sapphire = CGRect(x: 867, y: 1282, width: 322, height: 56)
        let wings: (CGSize) -> (left: CGFloat, right: CGFloat) = { size in
            let layout = IslandLayout(notchSize: size)
            return (layout.closedLeftWing, layout.closedRightWing)
        }
        let beside = NotchNeighbors.beside(geometry, neighbour: sapphire, closedWings: wings)
        XCTAssertEqual(beside.notchRect.maxX + wings(beside.notchRect.size).right, sapphire.minX - NotchNeighbors.gap,
                       accuracy: 0.5, "the island stops just short of Sapphire's")
        XCTAssertEqual(beside.notchRect.height, notch.height)
        XCTAssertEqual(beside.notchRect.maxY, screen.maxY, "still in the menu bar, flush with the top")
        XCTAssertFalse(beside.hasPhysicalNotch)
    }

    func testTellsWhenTheNeighbourShowsSomethingLeftOfTheNotch() {
        // Sapphire's window, Cocoa global: idle, playing music, a volume HUD.
        let idle = CGRect(x: 907, y: 1282, width: 242, height: 56)
        let music = CGRect(x: 869, y: 1282, width: 318, height: 56)
        let hud = CGRect(x: 861, y: 1237, width: 334, height: 101)
        XCTAssertFalse(NotchNeighbors.showsContentLeft(of: notch, frame: idle, screen: screen, previously: false))
        XCTAssertTrue(NotchNeighbors.showsContentLeft(of: notch, frame: music, screen: screen, previously: false))
        XCTAssertTrue(NotchNeighbors.showsContentLeft(of: notch, frame: hud, screen: screen, previously: true),
                      "a HUD over the music says nothing about what's under it")
        XCTAssertFalse(NotchNeighbors.showsContentLeft(of: notch, frame: hud, screen: screen, previously: false))
        XCTAssertFalse(NotchNeighbors.showsContentLeft(of: notch, frame: nil, screen: screen, previously: true), "gone")
    }

    func testPlacementSettingPersists() {
        let suite = "WhiplashTests.placement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Settings(defaults: defaults).islandPlacement, .aroundNotch, "Lash on top by default")
        Settings(defaults: defaults).islandPlacement = .beside
        XCTAssertEqual(Settings(defaults: defaults).islandPlacement, .beside)
    }
}

/// Sharing the notch with another island: the split between Lash's face and the notch.
final class NotchSharingTests: XCTestCase {
    private let layout = IslandLayout(notchSize: CGSize(width: 184, height: 37))

    func testWithANeighbourOnlyLashTakesTheMouseAndOpensTheDashboard() {
        let notchPoint = CGPoint(x: layout.notchRect.midX, y: layout.notchRect.midY)
        let lash = layout.lashRect(for: .closed)
        let lashPoint = CGPoint(x: lash.midX, y: lash.midY)
        XCTAssertTrue(layout.takesMouse(at: notchPoint, in: .closed), "alone, the notch is Lash's")
        XCTAssertTrue(layout.hoverKeepsOpen(notchPoint, in: .closed, open: false, slack: 10))
        XCTAssertFalse(layout.takesMouse(at: notchPoint, in: .closed, sharesNotch: true), "shared: the notch is Sapphire's")
        XCTAssertFalse(layout.hoverKeepsOpen(notchPoint, in: .closed, open: false, slack: 10, sharesNotch: true))
        XCTAssertTrue(layout.takesMouse(at: lashPoint, in: .closed, sharesNotch: true), "Lash's face is still Lash's")
        XCTAssertTrue(layout.hoverKeepsOpen(lashPoint, in: .closed, open: false, slack: 10, sharesNotch: true))
    }

    // Sapphire as measured on the user's Mac, Cocoa global: idle, showing the music that's playing, showing its volume
    // HUD, and opened.
    private let sapphireRest = CGRect(x: 907, y: 1282, width: 242, height: 56)
    private let sapphireMusic = CGRect(x: 869, y: 1282, width: 318, height: 56)
    private let sapphireHUD = CGRect(x: 861, y: 1237, width: 334, height: 101)
    private let sapphireOpen = CGRect(x: 760, y: 1100, width: 540, height: 238)
    private let elsewhere = CGPoint(x: 400, y: 600)
    private let notchPoint = CGPoint(x: 1028, y: 1320)

    func testAVolumeOrBrightnessHUDDoesNotHideLash() {
        var yield = NotchNeighbors.Yield()
        XCTAssertFalse(yield.update(neighbour: sapphireRest, cursor: elsewhere))
        XCTAssertFalse(yield.update(neighbour: sapphireHUD, cursor: elsewhere))
        XCTAssertFalse(yield.update(neighbour: sapphireHUD, cursor: nil), "the cursor over Lash's own island doesn't count")
        XCTAssertFalse(yield.update(neighbour: sapphireRest, cursor: elsewhere))
    }

    func testOpeningTheNeighbourYourselfHidesLashUntilItCloses() {
        var yield = NotchNeighbors.Yield()
        XCTAssertFalse(yield.update(neighbour: sapphireRest, cursor: elsewhere))
        XCTAssertFalse(yield.update(neighbour: sapphireRest, cursor: notchPoint), "hovering, not open yet")
        XCTAssertTrue(yield.update(neighbour: sapphireOpen, cursor: notchPoint))
        XCTAssertTrue(yield.update(neighbour: sapphireOpen, cursor: elsewhere), "stays aside while it's still open")
        XCTAssertFalse(yield.update(neighbour: sapphireRest, cursor: elsewhere))
        XCTAssertFalse(yield.update(neighbour: sapphireHUD, cursor: elsewhere), "closed: the next HUD leaves Lash alone")
    }

    func testWithMusicPlayingLashComesBackWhenTheNeighbourCollapses() {
        // Collapsed, Sapphire shows the music: wider than idle. Opening it and letting it go back must bring Lash back.
        var yield = NotchNeighbors.Yield()
        XCTAssertFalse(yield.update(neighbour: sapphireRest, cursor: elsewhere))
        XCTAssertFalse(yield.update(neighbour: sapphireMusic, cursor: elsewhere), "a song starts: Lash stays")
        XCTAssertFalse(yield.update(neighbour: sapphireMusic, cursor: notchPoint), "hovering the music, not open yet")
        XCTAssertTrue(yield.update(neighbour: sapphireOpen, cursor: notchPoint))
        XCTAssertFalse(yield.update(neighbour: sapphireMusic, cursor: elsewhere), "back to the music: Lash is back")
        XCTAssertFalse(yield.update(neighbour: sapphireMusic, cursor: notchPoint), "and hovering it again isn't opening it")
    }

    func testOpeningAnimationAndSmallChangesWhileOpenKeepLashAside() {
        var yield = NotchNeighbors.Yield()
        _ = yield.update(neighbour: sapphireMusic, cursor: elsewhere)
        let halfway = CGRect(x: 815, y: 1190, width: 430, height: 148)
        XCTAssertTrue(yield.update(neighbour: halfway, cursor: notchPoint), "growing under the cursor")
        XCTAssertTrue(yield.update(neighbour: sapphireOpen, cursor: notchPoint))
        let otherTab = sapphireOpen.insetBy(dx: 20, dy: 10)
        XCTAssertTrue(yield.update(neighbour: otherTab, cursor: notchPoint), "a slightly smaller page of it is still open")
        XCTAssertFalse(yield.update(neighbour: halfway.insetBy(dx: 60, dy: 30), cursor: notchPoint), "closing")
    }

    func testMovingIntoAHUDOnlyHidesLashIfItOpensFurther() {
        var yield = NotchNeighbors.Yield()
        XCTAssertFalse(yield.update(neighbour: sapphireHUD, cursor: elsewhere))
        XCTAssertFalse(yield.update(neighbour: sapphireHUD, cursor: CGPoint(x: 1100, y: 1260)), "just pointing at it")
        XCTAssertTrue(yield.update(neighbour: sapphireOpen, cursor: CGPoint(x: 1100, y: 1260)), "it opened under the cursor")
        XCTAssertFalse(yield.update(neighbour: nil, cursor: CGPoint(x: 1100, y: 1260)), "the neighbour quit")
    }
}
