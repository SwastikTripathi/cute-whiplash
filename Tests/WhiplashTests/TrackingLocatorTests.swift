import XCTest
@testable import Whiplash

final class TrackingLocatorTests: XCTestCase {
    private let primaryHeight: CGFloat = 1117

    /// One CGWindowListCopyWindowInfo entry. Numbers are NSNumbers, as the real API returns.
    private func window(pid: pid_t, layer: Int = 0, alpha: Double = 1, bounds: CGRect) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: bounds.dictionaryRepresentation as NSDictionary,
        ]
    }

    private func locate(_ pid: pid_t, in windows: [[String: Any]]) -> CGRect? {
        TerminalWindowLocator.frontWindowFrame(pid: pid, in: windows, primaryHeight: primaryHeight)
    }

    func testPicksTheFrontmostQualifyingWindowAndFlipsToCocoa() {
        let windows = [
            window(pid: 7, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1728, height: 37)),          // menu-bar extra
            window(pid: 42, bounds: CGRect(x: 100, y: 60, width: 900, height: 600)),                 // front kitty window
            window(pid: 42, bounds: CGRect(x: 300, y: 200, width: 900, height: 600)),                // behind it
        ]
        XCTAssertEqual(locate(42, in: windows), CGRect(x: 100, y: 1117 - 660, width: 900, height: 600))
    }

    func testSkipsOtherOwnersOverlaysInvisibleAndTinyWindows() {
        let target = CGRect(x: 10, y: 20, width: 800, height: 500)
        let windows = [
            window(pid: 9, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),                    // another app
            window(pid: 42, layer: 3, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),         // floating panel
            window(pid: 42, alpha: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800)),         // fully transparent
            window(pid: 42, bounds: CGRect(x: 0, y: 0, width: 120, height: 400)),                    // too narrow
            window(pid: 42, bounds: CGRect(x: 0, y: 0, width: 400, height: 80)),                     // too short
            window(pid: 42, bounds: target),
        ]
        XCTAssertEqual(locate(42, in: windows), CoordinateSpace.cocoaFromQuartz(target, primaryHeight: primaryHeight))
    }

    func testMissingOrMalformedEntriesAreIgnored() {
        var noBounds = window(pid: 42, bounds: .zero)
        noBounds[kCGWindowBounds as String] = nil
        var noLayer = window(pid: 42, bounds: CGRect(x: 0, y: 0, width: 500, height: 500))
        noLayer[kCGWindowLayer as String] = nil
        var noAlpha = window(pid: 42, bounds: CGRect(x: 1, y: 2, width: 500, height: 400))
        noAlpha[kCGWindowAlpha as String] = nil
        XCTAssertEqual(locate(42, in: [noBounds, noLayer, noAlpha]),
                       CoordinateSpace.cocoaFromQuartz(CGRect(x: 1, y: 2, width: 500, height: 400), primaryHeight: primaryHeight),
                       "alpha defaults to visible; bounds and layer are required")
    }

    func testSwiftNumbersBridgeLikeNSNumbers() {
        let windows: [[String: Any]] = [[
            kCGWindowOwnerPID as String: pid_t(42),
            kCGWindowLayer as String: 0,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 640, height: 480).dictionaryRepresentation,
        ]]
        XCTAssertNotNil(locate(42, in: windows))
    }

    func testNoWindowMeansNil() {
        XCTAssertNil(locate(42, in: []))
        XCTAssertNil(locate(42, in: [window(pid: 43, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]))
    }

    func testLiveQueryIsSafeForAnUnknownProcess() {
        XCTAssertNil(TerminalWindowLocator.frontWindowFrame(pid: -12_345))
    }
}
