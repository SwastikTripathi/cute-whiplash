import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private var coordinator: AppCoordinator?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = AppCoordinator(options: options)
        self.coordinator = coordinator
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
