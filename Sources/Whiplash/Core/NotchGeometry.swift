import AppKit

/// Where the notch (or, on screens without one, a virtual notch) is. All rects are Cocoa global.
struct NotchGeometry: Equatable {
    let screenFrame: CGRect
    let notchRect: CGRect
    let hasPhysicalNotch: Bool
    /// Height of the menu bar strip on this screen.
    let menuBarHeight: CGFloat

    /// Size used for screens without a notch, so the island still has something to hug.
    static let virtualNotchSize = CGSize(width: 190, height: 32)

    init(screenFrame: CGRect, notchRect: CGRect, hasPhysicalNotch: Bool, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.notchRect = notchRect
        self.hasPhysicalNotch = hasPhysicalNotch
        self.menuBarHeight = menuBarHeight
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let menuBarHeight = max(frame.maxY - screen.visibleFrame.maxY, 24)
        let topInset = screen.safeAreaInsets.top
        if topInset > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            let width = frame.width - left - right
            let rect = CGRect(x: frame.minX + left, y: frame.maxY - topInset, width: width, height: topInset)
            return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: true, menuBarHeight: max(menuBarHeight, topInset))
        }
        // macOS 27+: the screen frame may exclude the notch area (safeAreaInsets.top == 0,
        // auxiliaryTopLeftArea == nil). Detect the notch from the built-in display's full-height mode.
        if let detected = detectNotchFromDisplayModes(screen: screen, frame: frame) {
            let rect = CGRect(x: frame.minX + detected.leftArea, y: frame.maxY - detected.notchHeight,
                              width: detected.notchWidth, height: detected.notchHeight)
            return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: true,
                                 menuBarHeight: max(menuBarHeight, detected.notchHeight))
        }
        let size = virtualNotchSize
        let rect = CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height)
        return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: false, menuBarHeight: menuBarHeight)
    }

    /// On macOS 27+ the screen frame may exclude the notch area. The built-in display still has a full-height mode
    /// (including the notch rows) alongside the current shorter mode; the height difference tells us the notch area.
    /// The camera housing (the actual notch) is slightly shorter than the total hidden area because the display
    /// extends a little above the housing, so the notch height is derived from the physical display's camera housing
    /// measurement (~6.5 mm) rather than the raw mode difference.
    private static func detectNotchFromDisplayModes(screen: NSScreen, frame: CGRect) -> (notchHeight: CGFloat, notchWidth: CGFloat, leftArea: CGFloat)? {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              CGDisplayIsBuiltin(displayID) != 0,
              let modes = CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else { return nil }
        let currentPtWidth = frame.width
        let fullHeight = modes
            .filter { $0.width == Int(currentPtWidth) }
            .map(\.height)
            .max()
        guard let fullHeight, CGFloat(fullHeight) > frame.height else { return nil }
        let totalHidden = CGFloat(fullHeight) - frame.height
        guard totalHidden > 4, totalHidden < 80 else { return nil }
        let physicalMM = CGDisplayScreenSize(displayID)
        let ptPerMM = currentPtWidth / physicalMM.width
        // The total hidden area includes ~1 mm of display above the camera housing. Subtracting that gives
        // the actual notch depth — the area that other notch apps (Sapphire) treat as the notch.
        let bezelAbovePt = (1.0 * ptPerMM).rounded()
        let notchHeight = max(totalHidden - bezelAbovePt, totalHidden * 0.8)
        // Camera housing width: ~31 mm on 16" panels (≥ 340 mm wide), ~26 mm on smaller ones.
        let housingWidthMM: CGFloat = physicalMM.width >= 340 ? 31.0 : 26.0
        let notchWidth = (housingWidthMM * ptPerMM).rounded()
        let leftArea = (currentPtWidth - notchWidth) / 2
        return (notchHeight, notchWidth, leftArea)
    }

    /// The built-in notched screen if there is one, otherwise the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { isNotchedScreen($0) }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func isNotchedScreen(_ screen: NSScreen) -> Bool {
        if screen.safeAreaInsets.top > 0 { return true }
        return detectNotchFromDisplayModes(screen: screen, frame: screen.frame) != nil
    }

    /// Geometry for a demo scene of `size` (scene coords == Cocoa global with origin 0,0), mimicking a 16" MacBook Pro.
    static func demo(size: CGSize) -> NotchGeometry {
        let notch = CGRect(x: size.width / 2 - 92, y: size.height - 37, width: 184, height: 37)
        return NotchGeometry(screenFrame: CGRect(origin: .zero, size: size), notchRect: notch, hasPhysicalNotch: true, menuBarHeight: 37)
    }
}
