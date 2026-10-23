import Combine
import Foundation

/// One-shot main-thread timers behind a seam, so the coordinator's countdowns can run on a fake clock in tests.
protocol TimerScheduling {
    /// Runs `action` once on the main thread after `delay` seconds — unless the returned token is cancelled or
    /// released first.
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable
}

/// Real timers on the main run loop, in common modes so they keep firing while a menu is open.
struct MainRunLoopScheduler: TimerScheduling {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable {
        let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in action() }
        timer.tolerance = min(0.1, max(0, delay) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        return AnyCancellable { timer.invalidate() }
    }
}
