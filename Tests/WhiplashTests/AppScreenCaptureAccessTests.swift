import Combine
import XCTest
@testable import Whiplash

/// Real shattering switches itself on: macOS is asked once per signing identity, a grant made while Whiplash runs
/// is noticed without a click, and a relaunch is offered only when macOS won't show the grant to this process.
final class AppScreenCaptureAccessTests: XCTestCase {
    private final class Scheduler: TimerScheduling {
        var pending: [(fire: () -> Void, cancelled: () -> Bool)] = []
        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable {
            var cancelled = false
            pending.append((action, { cancelled }))
            return AnyCancellable { cancelled = true }
        }
        func fireAll() {
            let due = pending
            pending = []
            for item in due where !item.cancelled() { item.fire() }
        }
    }

    private final class FakeSystem {
        var preflight = false
        var probeWorks = false
        var identity = "identifier \"com.lightstick.whiplash\" and certificate leaf = H\"b6d1\""
        var requests = 0
        var resets = 0
        var relaunches = 0
        var settingsOpened = 0
        var settingsClosed: (() -> Void)?

        var system: ScreenCaptureAccess.System {
            ScreenCaptureAccess.System(
                preflight: { [unowned self] in preflight },
                request: { [unowned self] in requests += 1 },
                probe: { [unowned self] completion in completion(probeWorks) },
                resetDecision: { [unowned self] completion in resets += 1; completion(true) },
                openSettings: { [unowned self] in settingsOpened += 1 },
                relaunch: { [unowned self] in relaunches += 1 },
                identity: { [unowned self] in identity },
                isAppBundle: true,
                observeSettingsClosed: { [unowned self] handler in
                    settingsClosed = handler
                    return AnyCancellable { [weak self] in self?.settingsClosed = nil }
                })
        }
    }

    private var suite = ""
    private var defaults: UserDefaults!
    private let fake = FakeSystem()
    private let scheduler = Scheduler()

    override func setUp() {
        super.setUp()
        suite = "WhiplashTests.capture.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeAccess() -> ScreenCaptureAccess {
        ScreenCaptureAccess(system: fake.system, scheduler: scheduler, now: { Date() }, defaults: defaults)
    }

    func testAsksByItselfOnceForABuildIdentity() {
        let first = makeAccess()
        first.launch(wantsCapture: true)
        XCTAssertEqual(fake.requests, 1, "no click needed: macOS is asked at launch")
        XCTAssertTrue(first.isAwaitingGrant)

        let relaunched = makeAccess()
        relaunched.launch(wantsCapture: true)
        XCTAssertEqual(fake.requests, 1, "never asks twice for the same identity")
    }

    func testAlreadyGrantedNeverAsks() {
        fake.preflight = true
        let access = makeAccess()
        access.launch(wantsCapture: true)
        XCTAssertTrue(access.isGranted)
        XCTAssertEqual(fake.requests, 0)
    }

    func testCaptureSwitchedOffNeverAsks() {
        makeAccess().launch(wantsCapture: false)
        XCTAssertEqual(fake.requests, 0)
    }

    func testANewIdentityClearsTheStaleDecisionAndAsksAgain() {
        makeAccess().launch(wantsCapture: true)
        fake.identity = "cdhash H\"0000\"" // e.g. an old ad-hoc build's grant is on record
        makeAccess().launch(wantsCapture: true)
        XCTAssertEqual(fake.resets, 1, "the stale decision is reset first, so the prompt can show")
        XCTAssertEqual(fake.requests, 2)
    }

    func testAGrantMadeWhileRunningIsNoticedWithoutAClick() {
        let access = makeAccess()
        var changes = 0
        access.onChange = { changes += 1 }
        access.launch(wantsCapture: true)
        scheduler.fireAll()
        XCTAssertFalse(access.isGranted)
        fake.probeWorks = true // the user flips the switch; preflight stays stale, ScreenCaptureKit works
        scheduler.fireAll()
        XCTAssertTrue(access.isGranted)
        XCTAssertFalse(access.isAwaitingGrant)
        XCTAssertGreaterThanOrEqual(changes, 2)
        XCTAssertTrue(scheduler.pending.allSatisfy { $0.cancelled() }, "polling stops once granted")
    }

    func testRelaunchIsOfferedWhenTheGrantStaysInvisible() {
        let access = makeAccess()
        access.launch(wantsCapture: true)
        fake.settingsClosed?() // back from System Settings…
        scheduler.fireAll()     // …after the settle delay, still no grant visible
        XCTAssertTrue(access.offersRelaunch)
        access.relaunch()
        XCTAssertEqual(fake.relaunches, 1)
    }

    func testNoRelaunchMidPunishment() {
        let access = makeAccess()
        access.canRelaunch = { false }
        access.launch(wantsCapture: true)
        access.relaunch()
        XCTAssertEqual(fake.relaunches, 0)
    }
}
