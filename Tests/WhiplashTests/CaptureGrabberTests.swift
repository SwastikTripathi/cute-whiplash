import XCTest
@testable import Whiplash

/// ScreenGrabber itself needs Screen Recording permission, which tests don't have; its timeout race doesn't.
final class CaptureGrabberTests: XCTestCase {
    func testFirstResultReturnsAQuickValue() async {
        let value = await ScreenGrabber.firstResult(within: 1) { () async -> Int? in 42 }
        XCTAssertEqual(value, 42)
    }

    func testFirstResultGivesUpOnAStalledOperation() async {
        let started = Date()
        // Ignores cancellation, like a stuck ScreenCaptureKit call.
        let value = await ScreenGrabber.firstResult(within: 0.2) { () async -> Int? in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume(returning: 7) }
            }
        }
        XCTAssertNil(value)
        XCTAssertEqual(Date().timeIntervalSince(started), 0.2, accuracy: 0.15)
    }

    func testFirstResultPassesThroughFailure() async {
        let value = await ScreenGrabber.firstResult(within: 1) { () async -> Int? in nil }
        XCTAssertNil(value)
    }
}
