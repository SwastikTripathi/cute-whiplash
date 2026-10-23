import AppKit

/// Conversions between the coordinate spaces described in Types.swift.
enum CoordinateSpace {
    /// Height of the primary display (the one whose Cocoa frame origin is 0,0) — the pivot for y-flips.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    static func cocoaFromQuartz(_ rect: CGRect, primaryHeight: CGFloat = primaryScreenHeight) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func quartzFromCocoa(_ rect: CGRect, primaryHeight: CGFloat = primaryScreenHeight) -> CGRect {
        // The flip is its own inverse.
        cocoaFromQuartz(rect, primaryHeight: primaryHeight)
    }

    static func cocoaFromQuartz(_ point: CGPoint, primaryHeight: CGFloat = primaryScreenHeight) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Cocoa global → scene coordinates of the screen whose Cocoa frame is `screenFrame`.
    static func scene(fromCocoa rect: CGRect, screenFrame: CGRect) -> CGRect {
        rect.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    static func scene(fromCocoa point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
    }

    static func cocoa(fromScene point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x + screenFrame.minX, y: point.y + screenFrame.minY)
    }

    /// Scene rect → pixel rect inside a ScreenSnapshot image (row 0 = top), for cropping.
    static func imagePixels(fromScene rect: CGRect, sceneHeight: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(x: rect.minX * scale,
               y: (sceneHeight - rect.maxY) * scale,
               width: rect.width * scale,
               height: rect.height * scale).integral
    }
}
