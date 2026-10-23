import XCTest
@testable import Whiplash

final class CoreTests: XCTestCase {
    func testQuartzCocoaRoundTrip() {
        let r = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cocoa = CoordinateSpace.cocoaFromQuartz(r, primaryHeight: 1117)
        XCTAssertEqual(cocoa, CGRect(x: 10, y: 1117 - 220, width: 300, height: 200))
        XCTAssertEqual(CoordinateSpace.quartzFromCocoa(cocoa, primaryHeight: 1117), r)
    }

    func testSceneFromCocoaOnSecondaryScreen() {
        let screen = CGRect(x: 1728, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(CoordinateSpace.scene(fromCocoa: CGPoint(x: 1800, y: 0), screenFrame: screen), CGPoint(x: 72, y: 200))
    }

    func testImagePixelsFlipsY() {
        let px = CoordinateSpace.imagePixels(fromScene: CGRect(x: 10, y: 0, width: 20, height: 10), sceneHeight: 100, scale: 2)
        XCTAssertEqual(px, CGRect(x: 20, y: 180, width: 40, height: 20))
    }

    func testLaunchOptions() {
        let o = LaunchOptions(arguments: ["Whiplash", "--threshold", "15", "--whip-now", "--demo", "fx", "--out", "/tmp/x"])
        XCTAssertEqual(o.thresholdOverride, 15)
        XCTAssertTrue(o.whipNow)
        XCTAssertEqual(o.demo, "fx")
        XCTAssertEqual(o.outDir, "/tmp/x")
    }

    func testMoodProgression() {
        XCTAssertEqual(CritterMood.forProgress(0), .happy)
        XCTAssertEqual(CritterMood.forProgress(0.95), .furious)
    }
}
