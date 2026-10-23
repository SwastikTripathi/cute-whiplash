import AppKit

let launchOptions = LaunchOptions(arguments: CommandLine.arguments)

if launchOptions.demo != nil {
    // Top-level code is nonisolated in Swift 5 mode, but we are on the main thread.
    MainActor.assumeIsolated { DemoRunner.run(options: launchOptions) } // renders PNGs headlessly, then exits
}

if launchOptions.selfTest {
    SelfTest.run(options: launchOptions) // exercises subsystems headlessly, then exits
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appDelegate = AppDelegate(options: launchOptions)
app.delegate = appDelegate
app.run()
