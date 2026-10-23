import AppKit

/// Other apps' islands over the notch (Sapphire, NotchNook, boring.notch, …), found by where their windows sit —
/// no names to keep up to date, and no permission needed (window bounds are public).
enum NotchNeighbors {
    /// Another app's window over the notch, Cocoa global.
    struct Island: Equatable {
        let owner: String
        let pid: pid_t
        let frame: CGRect
    }

    /// System windows that live in the menu bar and are never someone's island.
    static let systemOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Spotlight", "Notification Center",
        "loginwindow", "WindowManager", "TextInputMenuAgent",
    ]

    /// kCGMainMenuWindowLevel: islands float at or above the menu bar…
    private static let menuBarLayer = 24
    /// …but below screen savers, the cursor and friends.
    private static let maxLayer = 1000

    /// The islands among `windows` (CGWindowListCopyWindowInfo output, front to back): another app's window at menu-bar
    /// level or above, covering the middle of the notch, no bigger than an island gets. Status items never qualify —
    /// macOS keeps them clear of the notch.
    static func islands(over notch: CGRect, screen: CGRect, in windows: [[String: Any]], excluding ownPID: pid_t,
                        primaryHeight: CGFloat) -> [Island] {
        let core = notch.insetBy(dx: notch.width * 0.3, dy: 0)
        return windows.compactMap { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, !systemOwners.contains(owner),
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer >= menuBarLayer, layer < maxLayer,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let quartz = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let frame = CoordinateSpace.cocoaFromQuartz(quartz, primaryHeight: primaryHeight)
            guard frame.intersects(core), frame.width <= screen.width * 0.8, frame.height <= screen.height * 0.6 else { return nil }
            return Island(owner: owner, pid: pid, frame: frame)
        }
    }

    /// The islands over `notch` right now.
    static func current(over notch: CGRect, screen: CGRect) -> [Island] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return islands(over: notch, screen: screen, in: windows, excluding: getpid(),
                       primaryHeight: CoordinateSpace.primaryScreenHeight)
    }

    /// A collapsed island is at most this much taller than the notch (open, or showing a HUD, it's taller).
    static let collapsedExtraHeight: CGFloat = 24
    /// A collapsed island whose window reaches this far left of the notch is showing something there (on the user's
    /// Mac, round a 220 pt notch, Sapphire's window reaches 49 pt playing music and 11 pt idle).
    static let leftContentReach: CGFloat = 30

    /// Whether the neighbour island in `frame` (Cocoa global), collapsed, shows its own content left of `notch`. While
    /// it's open or showing a HUD (taller than collapsed) that can't be told, so the answer stays `previously`.
    static func showsContentLeft(of notch: CGRect, frame: CGRect?, screen: CGRect, previously: Bool) -> Bool {
        guard let frame else { return false }
        guard screen.maxY - frame.minY <= notch.height + collapsedExtraHeight else { return previously }
        return notch.minX - frame.minX > leftContentReach
    }

    /// Room between Lash's island and the neighbour's.
    static let gap: CGFloat = 8
    /// The little stand-in notch Lash's island wraps when it moves aside: just a sliver of black between its wings.
    static let besideNotchWidth: CGFloat = 20

    /// `geometry` with the notch moved beside `neighbour` (to its left, clear of it by `gap`), so the closed island
    /// laid out round it sits in the menu bar next to the other island instead of on top of it. `closedWings`: how far
    /// the closed island reaches past a notch of that size, left and right. Without a neighbour: beside the real
    /// notch. Never off the screen.
    static func beside(_ geometry: NotchGeometry, neighbour: CGRect?,
                       closedWings: (CGSize) -> (left: CGFloat, right: CGFloat)) -> NotchGeometry {
        let size = CGSize(width: besideNotchWidth, height: geometry.notchRect.height)
        let wings = closedWings(size)
        let rightEdge = (neighbour?.minX ?? geometry.notchRect.minX) - gap
        let minX = max(geometry.screenFrame.minX + gap + wings.left, rightEdge - wings.right - size.width)
        let notch = CGRect(x: minX, y: geometry.notchRect.minY, width: size.width, height: size.height)
        return NotchGeometry(screenFrame: geometry.screenFrame, notchRect: notch, hasPhysicalNotch: false,
                             menuBarHeight: geometry.menuBarHeight)
    }

    /// Whether Lash's island should step aside for the neighbour's: only while you've opened the neighbour yourself —
    /// it grew with the cursor in it — and until it shrinks back. Whatever size it sits at without you (idle, showing
    /// the music that's playing, a volume or brightness HUD) is its baseline: growing by itself leaves Lash where he
    /// is, and shrinking back to any of those brings him back.
    struct Yield {
        /// Grown this much past its baseline, either way, with the cursor in it: you opened it.
        static let openGrowth: CGFloat = 6
        /// Shrunk below this share of the biggest it got while open (by area): it's closing.
        static let closingShare: CGFloat = 0.6

        /// Its frame while the cursor wasn't in it (or the smallest since the cursor went in).
        private(set) var baseline: CGRect?
        /// The biggest it got since you opened it; nil while it isn't open.
        private(set) var peak: CGRect?

        /// Updates for the neighbour's frame and the cursor (nil while it's on Lash's own island), both Cocoa global;
        /// true when Lash should step aside.
        mutating func update(neighbour: CGRect?, cursor: CGPoint?) -> Bool {
            guard let frame = neighbour else {
                baseline = nil
                peak = nil
                return false
            }
            if let open = peak {
                if Self.area(frame) < Self.area(open) * Self.closingShare {
                    peak = nil
                    baseline = frame
                    return false
                }
                if Self.area(frame) > Self.area(open) { peak = frame }
                return true
            }
            guard let cursor, frame.contains(cursor), let base = baseline else {
                baseline = frame
                return false
            }
            if frame.width > base.width + Self.openGrowth || frame.height > base.height + Self.openGrowth {
                peak = frame
                return true
            }
            if Self.area(frame) < Self.area(base) { baseline = frame }
            return false
        }

        private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
    }
}
