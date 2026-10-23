import AppKit
import ScreenCaptureKit

/// Takes the screenshot the punishment breaks. Everything that can go wrong (no permission, display gone,
/// ScreenCaptureKit stalling) ends in nil, and the overlay falls back to transparent "glass" mode.
enum ScreenGrabber {
    /// Screen Recording is granted, as far as this process can tell. `CGPreflightScreenCaptureAccess` alone isn't
    /// enough: after a grant made in System Settings while we run it keeps answering false, although
    /// ScreenCaptureKit already works, so a grant confirmed by `probeAccess` counts too. A synchronous round trip to
    /// the privacy daemon (~10 ms on macOS 27): don't call it on a hot path. AppCoordinator reads
    /// `ScreenCaptureAccess.isGranted` instead.
    static var hasPermission: Bool { confirmedGrant.value || CGPreflightScreenCaptureAccess() }

    /// Asks macOS for Screen Recording. Its prompt shows up in a separate process; this never blocks.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Asks ScreenCaptureKit whether capture works right now and reports it on the main queue. This is the
    /// authoritative check (preflight is not); a yes is remembered for `hasPermission`. Reads only the list of
    /// displays and windows, never pixels.
    ///
    /// Call it only after Screen Recording has been requested: if macOS has no decision on record for this app, the
    /// call brings up the system prompt. Once allowed, on macOS 15+ it's also the kind of call on which macOS asks
    /// the user to confirm the app may keep "bypassing the system private window picker". Better then than in the
    /// middle of a punishment.
    static func probeAccess(completion: @escaping (Bool) -> Void) {
        Task.detached(priority: .utility) {
            let works: Bool
            do {
                works = !(try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)).displays.isEmpty
            } catch {
                // Without the permission: SCStreamError.userDeclined (-3801).
                works = false
            }
            if works { confirmedGrant.set(true) }
            DispatchQueue.main.async { completion(works) }
        }
    }

    /// ScreenCaptureKit has proven it works in this process.
    private static let confirmedGrant = LockedFlag()

    /// How long a capture may take before the punishment gives up on it and goes ahead in glass mode.
    static let timeout: TimeInterval = 1.5

    /// Captures `screen` at backing resolution, excluding this app's own windows. nil without permission.
    /// Never prompts for permission and never takes longer than `timeout`.
    static func capture(screen: NSScreen) async -> ScreenSnapshot? {
        guard hasPermission else { return nil }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            captureLog.error("Screen capture: screen has no display number")
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let frame = screen.frame
        let pixelWidth = Int((frame.width * screen.backingScaleFactor).rounded())
        let pixelHeight = Int((frame.height * screen.backingScaleFactor).rounded())
        guard frame.width > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }

        let image = await firstResult(within: timeout) {
            await grab(displayID: displayID, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }
        guard let image else { return nil }
        return ScreenSnapshot(image: image, screenFrame: frame, scale: CGFloat(image.width) / frame.width)
    }

    /// Runs `operation` and returns its result, or nil once `seconds` have passed — whichever comes first.
    /// ScreenCaptureKit calls cannot be interrupted, so a late operation is cancelled and left to finish on its
    /// own; its result is dropped.
    static func firstResult<T>(within seconds: TimeInterval, _ operation: @escaping () async -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)
            let work = Task.detached(priority: .userInitiated) { gate.resume(returning: await operation()) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                guard gate.resume(returning: nil) else { return }
                work.cancel()
                captureLog.error("Screen capture timed out after \(seconds, privacy: .public) s")
            }
        }
    }

    private static func grab(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                captureLog.error("Screen capture: display \(displayID, privacy: .public) is not shareable")
                return nil
            }
            // Our own windows (the island, a lingering overlay) must not end up in the picture. Matching on the
            // process id also works for an unbundled binary.
            let ownProcess = getpid()
            let ownApps = content.applications.filter { $0.processID == ownProcess }
            // …except our menu-bar icon: the overlay covers the menu bar, so without it in the picture the icon
            // would vanish for the whole show.
            let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
            let menuBarIcon = content.windows.filter {
                $0.owningApplication?.processID == ownProcess && $0.windowLayer == statusLayer
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: menuBarIcon)
            let configuration = SCStreamConfiguration()
            configuration.width = pixelWidth
            configuration.height = pixelHeight
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.captureResolution = .best
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            captureLog.error("Screen capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// A Bool that any thread may read and write.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

/// Resumes a continuation exactly once, from whichever thread gets there first.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?

    init(_ continuation: CheckedContinuation<T?, Never>) {
        self.continuation = continuation
    }

    /// Returns false if the continuation had already been resumed.
    @discardableResult
    func resume(returning value: T?) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}
