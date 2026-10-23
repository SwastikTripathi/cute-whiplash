import XCTest
@testable import Whiplash

/// Lash's hands-on interactions: head pats, boops, spins and naps.
final class NotchInteractionTests: XCTestCase {
    private func makeLash() -> (LashState, IslandModel) {
        let model = IslandModel()
        model.soundEnabled = false
        return (LashState(model: model), model)
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testPatDetectorNeedsAMovingHand() {
        var pats = PatDetector()
        XCTAssertFalse(pats.feed(CGPoint(x: 0, y: 0), at: 0), "arriving on the head isn't a pat")
        XCTAssertFalse(pats.feed(CGPoint(x: 0, y: 0), at: 1), "resting isn't a pat")
        XCTAssertFalse(pats.feed(CGPoint(x: 4, y: 0), at: 1.1), "a twitch isn't a pat")
        XCTAssertTrue(pats.feed(CGPoint(x: 12, y: 0), at: 1.2), "a stroke across the head is")
        XCTAssertFalse(pats.feed(CGPoint(x: 30, y: 0), at: 1.3), "paced: at most every 0.28 s")
        XCTAssertTrue(pats.feed(CGPoint(x: 45, y: 0), at: 1.6))
        pats.reset()
        XCTAssertFalse(pats.feed(CGPoint(x: 200, y: 0), at: 3), "coming back from elsewhere isn't a pat")
    }

    func testHeadIsTheTopOfLash() {
        let lash = CGRect(x: 100, y: 10, width: 100, height: 100)
        let head = LashAnatomy.headRect(in: lash)
        XCTAssertTrue(head.contains(CGPoint(x: 150, y: 20)), "forehead")
        XCTAssertTrue(head.contains(CGPoint(x: 150, y: 5)), "top of the head, just above the frame")
        XCTAssertFalse(head.contains(CGPoint(x: 150, y: 90)), "not the mouth")
    }

    func testClickPokesAndDoubleClickSpins() {
        let (lash, model) = makeLash()
        lash.tapped()
        XCTAssertEqual(lash.squishes, 1, "a click is a poke")
        XCTAssertNotNil(model.quip)
        lash.tapped()
        XCTAssertEqual(lash.spins, 1, "a quick second click spins")
        XCTAssertEqual(lash.reaction, .blissful)
    }

    func testHeadPatsNeedAMovingHand() {
        let (lash, model) = makeLash()
        var x: CGFloat = 0
        func stroke() {
            x += 14
            lash.cursorMoved(to: CGPoint(x: x, y: 10), overLash: true, overHead: true)
        }
        lash.cursorMoved(to: CGPoint(x: x, y: 10), overLash: true, overHead: true)
        wait(1)
        XCTAssertEqual(lash.pats, 0, "a cursor resting on his head does nothing")
        XCTAssertNil(lash.reaction)

        stroke()
        XCTAssertEqual(lash.pats, 1)
        XCTAssertEqual(lash.reaction, .blissful)
        for _ in 0..<2 {
            wait(0.3)
            stroke()
        }
        XCTAssertEqual(lash.pats, 3)
        XCTAssertTrue(QuipBook.lines(for: .headPats).contains(model.quip ?? ""), "three in a row earns a line")
        wait(1)
        XCTAssertEqual(lash.pats, 3, "the hand stopped: no more pats")
    }

    func testNapsWhenQuietAndWakesOnTheCursor() {
        let (lash, model) = makeLash()
        model.phase = .idle
        model.streakAdvancing = false
        lash.napIfQuiet()
        XCTAssertEqual(lash.expression(for: model.mood), .mood(.sleepy))
        lash.cursorMoved(to: .zero, overLash: false)
        XCTAssertEqual(lash.reaction, .mood(.curious), "wakes with a start")
        XCTAssertTrue(QuipBook.lines(for: .wokeUp).contains(model.quip ?? ""))
    }

    func testNoNapWhileWorkingOrWhenSomethingIsGoingOn() {
        let (lash, model) = makeLash()
        model.streakAdvancing = true
        lash.napIfQuiet()
        XCTAssertNil(lash.reaction)
        model.streakAdvancing = false
        model.phase = .nudge(secondsLeft: 60)
        lash.napIfQuiet()
        XCTAssertNil(lash.reaction)
    }
}
