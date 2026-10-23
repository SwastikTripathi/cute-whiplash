import AppKit

enum TerminalWindowLocator {
    /// Windows this small are palettes, badges or quick-terminal slivers, not something worth whipping.
    static let minimumSize = CGSize(width: 120, height: 80)

    /// Frame of the frontmost normal (layer 0) on-screen window owned by `pid`, Cocoa global coordinates.
    /// Works without Screen Recording permission (bounds are public; titles are not).
    static func frontWindowFrame(pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return frontWindowFrame(pid: pid, in: windows, primaryHeight: CoordinateSpace.primaryScreenHeight)
    }

    /// Pure core of `frontWindowFrame(pid:)`. `windows` is CGWindowListCopyWindowInfo output, which is ordered
    /// front to back; `primaryHeight` is the primary display's height for the Quartz → Cocoa flip.
    static func frontWindowFrame(pid: pid_t, in windows: [[String: Any]], primaryHeight: CGFloat) -> CGRect? {
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let boundsInfo = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width > minimumSize.width, bounds.height > minimumSize.height
            else { continue }
            return CoordinateSpace.cocoaFromQuartz(bounds, primaryHeight: primaryHeight)
        }
        return nil
    }
}
