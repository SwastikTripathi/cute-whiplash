import AppKit
import SwiftUI
import XCTest
@testable import Whiplash

final class NotchLayoutTests: XCTestCase {
    private let screen = CGSize(width: 1728, height: 1117)
    private var geometry: NotchGeometry { NotchGeometry.demo(size: screen) }
    private var layout: IslandLayout { IslandLayout(geometry: geometry) }

    func testClosedPillIsCentredWithAWingEachSide() {
        let closed = layout.islandRect(for: .closed)
        XCTAssertEqual(closed.height, geometry.notchRect.height, "closed pill is exactly as tall as the notch")
        XCTAssertEqual(closed.midX, layout.notchRect.midX, "centred on the notch")
        let wing = closed.maxX - layout.notchRect.maxX
        XCTAssertTrue((36...44).contains(wing), "wing \(wing) pt: just Lash and the timer")
        XCTAssertEqual(layout.notchRect.minX - closed.minX, wing, "as long a strip on the left")
        let radius = layout.bottomRadius(for: .closed)
        XCTAssertTrue((10...12).contains(radius))
    }

    func testExpandedIsRoughly420By180() {
        let expanded = layout.islandSize(for: .expanded)
        XCTAssertEqual(expanded.width, 440, accuracy: 30)
        XCTAssertEqual(expanded.height, 180, accuracy: 10)
    }

    func testPanelIsTopCentredOnTheNotch() {
        let frame = layout.panelFrame(in: geometry)
        XCTAssertEqual(frame.maxY, geometry.screenFrame.maxY)
        XCTAssertEqual(frame.midX, geometry.notchRect.midX)
        XCTAssertEqual(frame.size, layout.panelSize)
    }

    func testEveryPresentationCoversTheNotchAndFitsThePanel() {
        for sharesLeft in [false, true] {
            let layout = IslandLayout(geometry: geometry, sharesLeft: sharesLeft)
            let panel = CGRect(origin: .zero, size: layout.panelSize)
            for presentation in IslandPresentation.allCases {
                let island = layout.islandRect(for: presentation)
                XCTAssertEqual(island.minY, 0, "\(presentation) is flush with the screen top")
                XCTAssertTrue(island.contains(layout.notchRect), "\(presentation) covers the notch")
                if !(sharesLeft && presentation.isCompact) {
                    XCTAssertEqual(island.midX, layout.notchRect.midX, "\(presentation) is centred on the notch")
                }
                XCTAssertTrue(panel.contains(island.insetBy(dx: -IslandLayout.topFlare, dy: 0)), "\(presentation) fits")
                let lash = layout.lashRect(for: presentation)
                XCTAssertTrue(island.contains(CGPoint(x: lash.midX, y: lash.midY)), "Lash sits on the island")
                XCTAssertGreaterThan(lash.midX, layout.notchRect.midX, "\(presentation): Lash is on the right")
            }
        }
    }

    func testNextToAnotherIslandsContentTheLeftIsLeftToIt() {
        let shared = IslandLayout(geometry: geometry, sharesLeft: true)
        let closed = shared.islandRect(for: .closed)
        XCTAssertEqual(closed.minX, shared.notchRect.minX, "nothing left of the notch: the album art shows there")
        XCTAssertEqual(closed.maxX - shared.notchRect.maxX, IslandLayout.sharedWing, "about as far right as Sapphire's music")
        XCTAssertEqual(shared.islandRect(for: .peek).minX, shared.notchRect.minX - IslandLayout.peekLeft,
                       "the peek reaches only a little left, for the quip")
        XCTAssertFalse(shared.contains(CGPoint(x: shared.notchRect.minX - 20, y: 10), in: .closed))
        XCTAssertEqual(layout.panelSize.width.truncatingRemainder(dividingBy: 2), 0, "even width keeps the centre on a whole point")
    }

    func testClosedLashSitsBetweenTheNotchAndTheTimer() {
        let lash = layout.lashRect(for: .closed)
        XCTAssertGreaterThanOrEqual(lash.minX, layout.notchRect.maxX, "Lash must not hide behind the camera housing")
        XCTAssertLessThanOrEqual(lash.minX - layout.notchRect.maxX, 4, "snug against the notch")
        XCTAssertLessThan(lash.maxX, try XCTUnwrap(layout.fuseRect(for: .closed)).minX, "clear of the timer's bar")
        XCTAssertEqual(lash.height, 22, "about the size of Sapphire's album art (20 pt)")
        XCTAssertEqual(lash.midY, geometry.notchRect.height / 2, accuracy: 1, "centred in the pill")
    }

    func testTheTimerRunsDownTheCompactIslandsEnd() throws {
        for presentation in [IslandPresentation.closed, .peek] {
            let island = layout.islandRect(for: presentation)
            let fuse = try XCTUnwrap(layout.fuseRect(for: presentation))
            XCTAssertEqual(fuse.maxX, island.maxX - IslandLayout.fuseInset)
            XCTAssertEqual(fuse.width, IslandLayout.fuseWidth)
            XCTAssertEqual(fuse.height, 20, "\(presentation): as long as a music app's album art is tall")
            XCTAssertEqual(fuse.midY, layout.lashRect(for: presentation).midY, accuracy: 0.01, "level with Lash")
            for corner in [CGPoint(x: fuse.minX, y: fuse.minY), CGPoint(x: fuse.maxX, y: fuse.maxY)] {
                XCTAssertTrue(layout.contains(corner, in: presentation), "\(presentation): inside the rounded corner")
            }
        }
        for presentation in [IslandPresentation.expanded, .warning, .whipping] {
            XCTAssertNil(layout.fuseRect(for: presentation), "\(presentation) has its own timer")
        }
    }

    func testTheTimerBarShortensAsTheSessionRunsOut() {
        let fresh = FuseBar.state(phase: .idle, streakSeconds: 60, progress: 0.02)
        let half = FuseBar.state(phase: .idle, streakSeconds: 1500, progress: 0.5)
        let over = FuseBar.state(phase: .aftermath, streakSeconds: 3100, progress: 1)
        XCTAssertEqual(fresh.left, 0.98, accuracy: 1e-9)
        XCTAssertEqual(half.left, 0.5, accuracy: 1e-9)
        XCTAssertEqual(over.left, 0, "used up")
        XCTAssertEqual(FuseBar.state(phase: .idle, streakSeconds: 0, progress: 0).left, 1, "no session yet: all the time left")
        XCTAssertEqual(FuseBar.state(phase: .idle, streakSeconds: 0, progress: 0).color, ProgressPalette.color(0),
                       "and green, like a fresh session — never a grey line that reads as nothing")
        XCTAssertEqual(FuseBar.state(phase: .snoozed(until: .distantFuture), streakSeconds: 900, progress: 0.3).left, 1)
    }

    func testHitTestingFollowsTheShape() {
        let closed = layout.islandRect(for: .closed)
        XCTAssertTrue(layout.contains(CGPoint(x: closed.midX, y: closed.midY), in: .closed))
        XCTAssertTrue(layout.contains(CGPoint(x: closed.minX + 20, y: 4), in: .closed), "left wing")
        XCTAssertFalse(layout.contains(CGPoint(x: closed.minX - 3, y: 10), in: .closed), "menu bar left of the pill")
        XCTAssertFalse(layout.contains(CGPoint(x: closed.midX, y: closed.maxY + 3), in: .closed), "below the pill")
        XCTAssertFalse(layout.contains(CGPoint(x: closed.minX + 1, y: closed.maxY - 1), in: .closed), "outside the rounded corner")
        XCTAssertTrue(layout.contains(CGPoint(x: closed.minX + 1, y: closed.maxY - 1), in: .closed, tolerance: 10), "slack grows the shape")
        XCTAssertTrue(layout.contains(CGPoint(x: closed.midX, y: closed.maxY + 30), in: .expanded), "the dashboard hangs lower")
    }

    func testExpandedCoversTheClosedPill() {
        let closed = layout.islandRect(for: .closed).insetBy(dx: 12, dy: 1)
        for corner in [CGPoint(x: closed.minX, y: closed.minY), CGPoint(x: closed.maxX, y: closed.minY),
                       CGPoint(x: closed.minX, y: closed.maxY), CGPoint(x: closed.maxX, y: closed.maxY)] {
            XCTAssertTrue(layout.contains(corner, in: .expanded), "hovering the pill keeps the expanded island open")
        }
    }

    func testPanelPointRoundTrip() {
        let frame = layout.panelFrame(in: geometry)
        let cocoa = CGPoint(x: 900, y: 1100)
        let panel = IslandLayout.panelPoint(fromCocoa: cocoa, panelFrame: frame)
        XCTAssertEqual(panel.y, 17, accuracy: 0.001, "17 pt below the top of the screen")
        XCTAssertEqual(IslandLayout.cocoaPoint(fromPanel: panel, panelFrame: frame), cocoa)
    }

    func testWhipIsHeldJustInsideTheWhippingIslandsLip() {
        let grip = layout.whipGrip(in: geometry)
        XCTAssertEqual(grip.x, geometry.notchRect.midX)
        let lip = geometry.screenFrame.maxY - layout.islandSize(for: .whipping).height
        XCTAssertEqual(grip.y, lip + IslandLayout.whipGripInset, accuracy: 0.001)
        XCTAssertLessThan(grip.y, geometry.notchRect.minY, "below the notch, inside the pill")
        // The whip's pommel rests 4 pt below the grip and dips at most `handDip` below it: always inside the pill.
        let tuning = WhipTuning()
        XCTAssertGreaterThan(grip.y - max(tuning.handDip, tuning.windUpDip), lip, "the pommel never leaves the island")
        // Lash's paw (drawn by the whip) shows just below the edge.
        let firstFinger = grip.y - 4 - WhipSkin.fingers[0].along
        XCTAssertLessThan(firstFinger, lip)
        XCTAssertGreaterThan(firstFinger, lip - 8)
        XCTAssertEqual(IslandLayout.whipGrip(for: geometry), grip)
    }

    func testWhipAnchorOnAScreenWithoutTheIslandReachesInFromAboveIt() {
        let external = CGRect(x: 1728, y: -200, width: 2560, height: 1440)
        let anchor = NotchController.whipAnchor(on: external, island: geometry)
        XCTAssertEqual(anchor.x, external.midX)
        XCTAssertEqual(anchor.y, external.maxY + NotchController.offscreenGripHeight)
        XCTAssertEqual(NotchController.whipAnchor(on: geometry.screenFrame, island: geometry), layout.whipGrip(in: geometry))
        XCTAssertEqual(NotchController.whipAnchor(on: external, island: nil).x, external.midX)
    }

    func testCompactPillOnlyTakesTheMouseOverTheNotchLashAndTheWhip() {
        for presentation in [IslandPresentation.closed, .peek] {
            let island = layout.islandRect(for: presentation)
            let lash = layout.lashRect(for: presentation)
            XCTAssertTrue(layout.takesMouse(at: CGPoint(x: layout.notchRect.midX, y: 10), in: presentation))
            XCTAssertTrue(layout.takesMouse(at: CGPoint(x: lash.midX, y: lash.midY), in: presentation), "poke Lash")
            XCTAssertTrue(layout.takesMouse(at: CGPoint(x: island.maxX - 8, y: 10), in: presentation), "grab the whip")
        }
        XCTAssertFalse(layout.takesMouse(at: CGPoint(x: layout.notchRect.minX - 20, y: 10), in: .closed),
                       "the left wing lets clicks through to the menu bar")
        let peek = layout.islandRect(for: .peek)
        XCTAssertFalse(layout.takesMouse(at: CGPoint(x: layout.notchRect.midX, y: peek.maxY - 4), in: .peek),
                       "the peek lip lets clicks through to the window below")
        let expanded = layout.islandRect(for: .expanded)
        XCTAssertTrue(layout.takesMouse(at: CGPoint(x: expanded.maxX - 12, y: expanded.maxY - 30), in: .expanded))
    }

    func testOnlyTheNotchOpensTheDashboard() {
        let closed = layout.islandRect(for: .closed)
        let wing = CGPoint(x: closed.maxX - 10, y: 12)
        XCTAssertFalse(layout.hoverKeepsOpen(wing, in: .closed, open: false, slack: 10), "aiming at a menu item beside it")
        XCTAssertTrue(layout.hoverKeepsOpen(CGPoint(x: layout.notchRect.midX, y: 12), in: .closed, open: false, slack: 10))
        let expanded = layout.islandRect(for: .expanded)
        XCTAssertTrue(layout.hoverKeepsOpen(CGPoint(x: expanded.minX - 5, y: 60), in: .expanded, open: true, slack: 10),
                      "once open, the whole dashboard plus slack keeps it open")
    }

    func testVirtualNotchOnAnExternalDisplay() {
        let external = NotchGeometry(screenFrame: CGRect(x: 1728, y: -200, width: 2560, height: 1440),
                                     notchRect: CGRect(x: 1728 + 1280 - 95, y: 1240 - 32, width: 190, height: 32),
                                     hasPhysicalNotch: false, menuBarHeight: 25)
        let layout = IslandLayout(geometry: external)
        let frame = layout.panelFrame(in: external)
        XCTAssertEqual(frame.maxY, external.screenFrame.maxY)
        XCTAssertEqual(frame.midX, external.notchRect.midX)
        XCTAssertEqual(layout.islandSize(for: .closed).height, 32)
    }

    func testPresentationResolution() {
        XCTAssertEqual(IslandPresentation.resolve(phase: .idle, hovering: false, hasQuip: false), .closed)
        XCTAssertEqual(IslandPresentation.resolve(phase: .idle, hovering: false, hasQuip: true), .peek)
        XCTAssertEqual(IslandPresentation.resolve(phase: .idle, hovering: true, hasQuip: true), .expanded)
        XCTAssertEqual(IslandPresentation.resolve(phase: .warning(secondsLeft: 3), hovering: false, hasQuip: false), .warning,
                       "warning expands by itself")
        XCTAssertEqual(IslandPresentation.resolve(phase: .warning(secondsLeft: 3), hovering: true, hasQuip: true), .warning)
        XCTAssertEqual(IslandPresentation.resolve(phase: .whipping, hovering: true, hasQuip: false), .whipping)
        XCTAssertEqual(IslandPresentation.resolve(phase: .manual, hovering: false, hasQuip: true), .whipping)
        XCTAssertEqual(IslandPresentation.resolve(phase: .snoozed(until: .distantFuture), hovering: true, hasQuip: false), .expanded)
        XCTAssertEqual(IslandPresentation.resolve(phase: .aftermath, hovering: false, hasQuip: true), .peek)
    }
}

final class NotchPanelTests: XCTestCase {
    func testPanelNeverStealsFocus() {
        _ = NSApplication.shared
        let panel = NotchPanel(frame: CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.styleMask.contains(.titled), "borderless")
        XCTAssertEqual(panel.level, WindowLevels.island)
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle])
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertTrue(panel.ignoresMouseEvents, "click-through until the cursor is on the island")
        let menuBarFrame = CGRect(x: 10, y: 5000, width: 100, height: 50)
        XCTAssertEqual(panel.constrainFrameRect(menuBarFrame, to: nil), menuBarFrame, "may sit in the menu bar")
    }

    func testHostingViewTakesTheFirstClick() {
        let view = IslandHostingView(rootView: Color.clear)
        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testHostingViewHearsTheCursorWhileTheAppIsInactive() {
        let view = IslandHostingView(rootView: Color.clear)
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        let cursor = view.trackingAreas.filter { $0.owner === view && $0.options.contains(.mouseMoved) }
        XCTAssertEqual(cursor.count, 1, "exactly one cursor tracking area, however often AppKit asks")
        XCTAssertTrue(cursor.first?.options.contains(.activeAlways) ?? false,
                      "mouse-moved events must reach the island although the app is never active")
    }
}

/// Renders the real island and checks pixels: the closed pill is solid black and flush with the top,
/// and everything around it is transparent (so the menu bar shows through).
final class NotchRenderTests: XCTestCase {
    private func render(_ phase: IslandPhase, hovering: Bool = false, quip: String? = nil) -> (CGImage, IslandLayout)? {
        MainActor.assumeIsolated {
            let model = IslandModel()
            model.phase = phase
            model.quip = quip
            let layout = IslandLayout(notchSize: CGSize(width: 184, height: 37))
            let view = IslandView(model: model, ui: IslandUIState(layout: layout, isHovering: hovering), lash: LashState(model: model))
                .environment(\.islandFrozenTime, 1)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            return renderer.cgImage.map { ($0, layout) }
        }
    }

    private func alphaAndLuma(_ image: CGImage, at point: CGPoint) -> (alpha: Double, luma: Double) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that `point` (top-left origin) lands on the single pixel.
        ctx.draw(image, in: CGRect(x: -point.x, y: point.y - CGFloat(image.height) + 1, width: CGFloat(image.width), height: CGFloat(image.height)))
        let alpha = Double(pixel[3]) / 255
        let luma = alpha > 0 ? (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255 * alpha) : 0
        return (alpha, luma)
    }

    func testClosedPillIsBlackAndTheRestIsClear() throws {
        let (image, layout) = try XCTUnwrap(render(.idle))
        XCTAssertEqual(image.width, Int(layout.panelSize.width))
        let island = layout.islandRect(for: .closed)
        let insidePill = alphaAndLuma(image, at: CGPoint(x: layout.notchRect.maxX + 3, y: 2))
        XCTAssertEqual(insidePill.alpha, 1, accuracy: 0.01)
        XCTAssertLessThan(insidePill.luma, 0.05)
        XCTAssertEqual(alphaAndLuma(image, at: CGPoint(x: island.minX - 12, y: 5)).alpha, 0, accuracy: 0.01, "menu bar shows through")
        XCTAssertEqual(alphaAndLuma(image, at: CGPoint(x: island.midX, y: island.maxY + 8)).alpha, 0, accuracy: 0.01, "nothing hangs below")
    }

    func testWarningGrowsAndGlows() throws {
        let (image, layout) = try XCTUnwrap(render(.warning(secondsLeft: 4)))
        let island = layout.islandRect(for: .warning)
        XCTAssertEqual(alphaAndLuma(image, at: CGPoint(x: island.midX, y: island.maxY - 4)).alpha, 1, accuracy: 0.01)
        XCTAssertGreaterThan(alphaAndLuma(image, at: CGPoint(x: island.midX, y: island.maxY + 6)).alpha, 0.1, "red glow around the island")
    }

    func testTheIslandDrawsNoWhipHandleOfItsOwn() throws {
        // The overlay's whip — handle and Lash's paw included — is the only one: a second handle drawn by the island
        // would hang there with nothing attached while the real one swings.
        for phase in [IslandPhase.whipping, .manual] {
            let (image, layout) = try XCTUnwrap(render(phase))
            let island = layout.islandRect(for: .whipping)
            XCTAssertLessThan(alphaAndLuma(image, at: CGPoint(x: island.midX, y: island.maxY + 20)).alpha, 0.9,
                              "only the glow below the pill (\(phase))")
        }
    }
}

/// Pulling the whip out of the island's right end.
extension NotchLayoutTests {

    func testTheWhipIsGrabbedAtTheIslandsRightEnd() {
        for presentation in [IslandPresentation.closed, .peek, .expanded] {
            let island = layout.islandRect(for: presentation)
            guard let pull = layout.whipPullRect(for: presentation) else { return XCTFail("\(presentation)") }
            XCTAssertEqual(pull.maxX, island.maxX, "\(presentation): the island's very end")
            XCTAssertEqual(pull.minY, 0)
            XCTAssertEqual(pull.height, geometry.notchRect.height, "in the row beside the notch")
            XCTAssertFalse(pull.intersects(layout.notchRect))
            XCTAssertFalse(pull.intersects(layout.lashRect(for: presentation)))
            let grab = CGPoint(x: pull.midX, y: pull.midY)
            XCTAssertTrue(layout.contains(grab, in: presentation))
            for sharesNotch in [false, true] {
                XCTAssertTrue(layout.takesMouse(at: grab, in: presentation, sharesNotch: sharesNotch),
                              "\(presentation): the whip is Lash's island's, even over another app's")
            }
        }
        let closedPull = layout.whipPullRect(for: .closed)!
        XCTAssertFalse(layout.hoverKeepsOpen(CGPoint(x: closedPull.midX, y: closedPull.midY), in: .closed, open: false, slack: 10),
                       "reaching for the whip doesn't pop the dashboard open")
        XCTAssertLessThanOrEqual(layout.whipPullRect(for: .expanded)!.width, 18, "clear of the dashboard's toggles")
    }

    func testNoWhipToGrabWhileLashHasIt() {
        XCTAssertNil(layout.whipPullRect(for: .warning))
        XCTAssertNil(layout.whipPullRect(for: .whipping))
    }

    func testThePulledWhipHangsInTheIslandsRightEnd() {
        let grip = layout.whipPullGrip(in: geometry)
        let whipping = layout.islandRect(for: .whipping)
        let rightEnd = IslandLayout.cocoaPoint(fromPanel: CGPoint(x: whipping.maxX, y: 0), panelFrame: layout.panelFrame(in: geometry)).x
        XCTAssertGreaterThan(grip.x, geometry.notchRect.maxX, "right of the notch")
        XCTAssertLessThan(grip.x, rightEnd - layout.bottomRadius(for: .whipping), "under the flat part of the bottom edge")
        XCTAssertGreaterThan(grip.x, rightEnd - 30, "at the very end")
        XCTAssertEqual(grip.y, layout.whipGrip(in: geometry).y, "as far inside the edge as Lash's grip")
        XCTAssertEqual(IslandLayout.whipPullGrip(for: geometry), grip)
        XCTAssertEqual(NotchController.whipAnchor(on: geometry.screenFrame, island: geometry, manual: true), grip)
        let external = CGRect(x: 1728, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(NotchController.whipAnchor(on: external, island: geometry, manual: true),
                       NotchController.whipAnchor(on: external, island: geometry), "no island there: from above the screen")
    }
}
