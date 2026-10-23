import CoreGraphics

/// What shape the island takes right now. Derived from `IslandPhase` + hover + quip, never stored.
enum IslandPresentation: Equatable, CaseIterable {
    /// Black pill round the notch: Lash and the work timer's bar on its right, a plain wing on its left — or, while
    /// another app's island shows something left of the notch, no left wing at all.
    case closed
    /// Closed, a little wider, plus a lip under the notch where Lash says something (a quip is showing).
    case peek
    /// Full dashboard, shown while the cursor hovers the island.
    case expanded
    /// The whip is coming: auto-expanded countdown, regardless of hover.
    case warning
    /// Lash is whipping the screen: a slightly taller pill. The overlay's whip (handle and Lash's paw included) hangs
    /// from just inside its bottom edge, so it comes out from under the island.
    case whipping

    static func resolve(phase: IslandPhase, hovering: Bool, hasQuip: Bool) -> IslandPresentation {
        switch phase {
        case .nudge, .warning: return .warning
        case .whipping, .manual: return .whipping
        case .idle, .aftermath, .snoozed, .disabled:
            if hovering { return .expanded }
            return hasQuip ? .peek : .closed
        }
    }

    /// Presentations that share the compact "wings beside the notch" layout.
    var isCompact: Bool { self == .closed || self == .peek || self == .whipping }
}

/// Pure layout math for the island panel.
///
/// Unless stated otherwise, rects are in **panel space**: points relative to the panel's top-left corner, y down
/// (the SwiftUI coordinate space of the hosting view). The panel itself has a fixed size big enough for every
/// presentation plus glow, and sits top-centred on the notch.
struct IslandLayout: Equatable {
    /// The (physical or virtual) notch the island hugs.
    let notchSize: CGSize
    /// Another app's island shows its own content left of the notch (Sapphire, the song that's playing): the closed
    /// island leaves that side to it and reaches about as far right as it does, so the two read as one island. Without
    /// one, the closed island is centred on the notch.
    let sharesLeft: Bool

    // MARK: Tuning

    /// The closed island's wings: on the right Lash and the timer's bar, snug against the notch; the same length of
    /// plain black on the left.
    static let closedWing: CGFloat = 40
    /// Its right wing next to another island's content on the left (as far as Sapphire's music island reaches).
    static let sharedWing: CGFloat = 50
    static let peekWing: CGFloat = 74
    /// Next to another island's content, the peek reaches only this far left of the notch, for the quip's sake.
    static let peekLeft: CGFloat = 40
    static let peekLip: CGFloat = 34
    static let whipWing: CGFloat = 64
    static let whipLip: CGFloat = 12
    static let expandedMinWidth: CGFloat = 440
    static let expandedBody: CGFloat = 148
    static let warningBody: CGFloat = 122
    /// Concave fillet where the island meets the top edge of the screen, like the physical notch's.
    static let topFlare: CGFloat = 6
    /// How far above the whipping island's bottom edge the overlay's whip is held: its pommel hides under the island
    /// and Lash's paw shows just below the edge, even while the cackling island throbs.
    static let whipGripInset: CGFloat = 10
    /// Transparent room around the island for the warning / whipping glow.
    static let glowMargin: CGFloat = 36
    /// The whip you pull out yourself lives in the island's right end: you grab it past Lash (on the dashboard, at the
    /// free end of the row beside the notch, this wide, clear of its toggles)…
    static let expandedWhipPullWidth: CGFloat = 18
    /// …and it hangs this far in from the whipping island's right edge.
    static let whipPullInset: CGFloat = 20
    /// Closed, Lash is about the size of the album art another notch app shows on its side of the notch (Sapphire's
    /// is 20 pt), and the work timer's bar beside him is as long, set in from the island's end like the art is.
    static let closedLashSide: CGFloat = 22
    static let fuseLength: CGFloat = 20
    static let fuseWidth: CGFloat = 4
    static let fuseInset: CGFloat = 7
    /// Between Lash and the bar.
    static let fuseGap: CGFloat = 4

    init(notchSize: CGSize, sharesLeft: Bool = false) {
        self.notchSize = notchSize
        self.sharesLeft = sharesLeft
    }

    init(geometry: NotchGeometry, sharesLeft: Bool = false) {
        self.init(notchSize: geometry.notchRect.size, sharesLeft: sharesLeft)
    }

    // MARK: Island

    /// How far the closed island reaches past the notch on either side.
    var closedLeftWing: CGFloat { sharesLeft ? 0 : Self.closedWing }
    var closedRightWing: CGFloat { sharesLeft ? Self.sharedWing : Self.closedWing }
    /// How far the peek reaches left of the notch (right: `peekWing`).
    var peekLeftWing: CGFloat { sharesLeft ? Self.peekLeft : Self.peekWing }

    func islandSize(for presentation: IslandPresentation) -> CGSize {
        let w = notchSize.width, h = notchSize.height
        let wide = max(Self.expandedMinWidth, w + 2 * 118)
        switch presentation {
        case .closed: return CGSize(width: closedLeftWing + w + closedRightWing, height: h)
        case .peek: return CGSize(width: peekLeftWing + w + Self.peekWing, height: h + Self.peekLip)
        case .whipping: return CGSize(width: w + 2 * Self.whipWing, height: h + Self.whipLip)
        case .expanded: return CGSize(width: wide, height: h + Self.expandedBody)
        case .warning: return CGSize(width: wide, height: h + Self.warningBody)
        }
    }

    /// Radius of the island's two bottom corners (its top corners are square, flush with the screen edge).
    func bottomRadius(for presentation: IslandPresentation) -> CGFloat {
        switch presentation {
        case .closed: return 11
        case .peek: return 20
        case .whipping: return 16
        case .expanded: return 34
        case .warning: return 32
        }
    }

    /// How far left of the notch's centre the island reaches (the rest of it is to the right).
    private func leftReach(for presentation: IslandPresentation) -> CGFloat {
        switch presentation {
        case .closed: return notchSize.width / 2 + closedLeftWing
        case .peek: return notchSize.width / 2 + peekLeftWing
        case .whipping, .expanded, .warning: return islandSize(for: presentation).width / 2
        }
    }

    /// Fixed panel size: room for every presentation either side of the notch, plus flare and glow room.
    var panelSize: CGSize {
        let halfSpan = IslandPresentation.allCases.map { p in
            max(leftReach(for: p), islandSize(for: p).width - leftReach(for: p))
        }.max() ?? 0
        let width = 2 * (halfSpan + Self.topFlare + Self.glowMargin)
        let height = (IslandPresentation.allCases.map { islandSize(for: $0).height }.max() ?? 0) + Self.glowMargin
        // Even width keeps the island exactly centred on the notch in whole points.
        return CGSize(width: (width / 2).rounded(.up) * 2, height: height.rounded(.up))
    }

    /// The island body (without the top flares), panel space. Centred on the notch — except the compact pills next to
    /// another island's content on the left, which start at the notch's left edge (a little before it, to fit a quip).
    func islandRect(for presentation: IslandPresentation) -> CGRect {
        let size = islandSize(for: presentation)
        return CGRect(x: panelSize.width / 2 - leftReach(for: presentation), y: 0, width: size.width, height: size.height)
    }

    /// The physical notch, panel space.
    var notchRect: CGRect {
        CGRect(x: (panelSize.width - notchSize.width) / 2, y: 0, width: notchSize.width, height: notchSize.height)
    }

    /// Whether the island takes the mouse at `point` (panel space). The compact pill only takes it over the notch
    /// itself (nothing else can be there), over Lash (to poke it) and at its end (to pull the whip out): the rest of
    /// its wing and its lip let clicks through to the menu bar items and the window underneath. The dashboard and the
    /// countdown take it anywhere on their shape.
    ///
    /// `sharesNotch`: another app's island (Sapphire, …) lies under this one. The notch is then that app's to hover
    /// and click; the closed island only takes the mouse over Lash.
    func takesMouse(at point: CGPoint, in presentation: IslandPresentation, sharesNotch: Bool = false) -> Bool {
        switch presentation {
        case .closed, .peek:
            return (!sharesNotch && notchRect.contains(point)) || lashRect(for: presentation).contains(point)
                || whipPullRect(for: presentation)?.contains(point) == true
        case .expanded, .warning, .whipping:
            return contains(point, in: presentation)
        }
    }

    /// Where you grab the whip to pull it out, panel space: the island's right end, past Lash, in the row beside the
    /// notch. Nil while Lash has it (the countdown, the whip).
    func whipPullRect(for presentation: IslandPresentation) -> CGRect? {
        let island = islandRect(for: presentation)
        switch presentation {
        case .closed, .peek:
            let start = lashRect(for: presentation).maxX + 1
            return CGRect(x: start, y: 0, width: island.maxX - start, height: notchSize.height)
        case .expanded:
            return CGRect(x: island.maxX - Self.expandedWhipPullWidth, y: 0, width: Self.expandedWhipPullWidth,
                          height: notchSize.height)
        case .warning, .whipping:
            return nil
        }
    }

    /// The work timer's bar at the compact island's right end, at full length, panel space (nil elsewhere): upright,
    /// level with Lash.
    func fuseRect(for presentation: IslandPresentation) -> CGRect? {
        guard presentation == .closed || presentation == .peek else { return nil }
        let island = islandRect(for: presentation)
        let middle = lashRect(for: presentation).midY
        return CGRect(x: island.maxX - Self.fuseInset - Self.fuseWidth, y: middle - Self.fuseLength / 2,
                      width: Self.fuseWidth, height: Self.fuseLength)
    }

    /// Whether the cursor at `point` (panel space) opens the dashboard or, while it is `open`, keeps it open: only over
    /// the notch itself (aiming at a menu-bar item beside it never pops it open), then anywhere on it plus `slack`.
    /// `sharesNotch`: the notch belongs to another app's island, so only hovering Lash opens the dashboard.
    func hoverKeepsOpen(_ point: CGPoint, in presentation: IslandPresentation, open: Bool, slack: CGFloat,
                        sharesNotch: Bool = false) -> Bool {
        if open { return contains(point, in: presentation, tolerance: slack) }
        return sharesNotch ? lashRect(for: presentation).contains(point) : notchRect.contains(point)
    }

    /// Whether `point` (panel space) is on the island's visible shape, bottom corners included.
    /// `tolerance` grows the shape outward on the sides and bottom (used as hover hysteresis).
    func contains(_ point: CGPoint, in presentation: IslandPresentation, tolerance: CGFloat = 0) -> Bool {
        let rect = islandRect(for: presentation)
        let hit = CGRect(x: rect.minX - tolerance, y: rect.minY - tolerance,
                         width: rect.width + 2 * tolerance, height: rect.height + 2 * tolerance)
        guard hit.contains(point) else { return false }
        // Outside the rounded bottom corners?
        let r = bottomRadius(for: presentation) + tolerance
        guard point.y > hit.maxY - r else { return true }
        let cx: CGFloat
        if point.x < hit.minX + r { cx = hit.minX + r } else if point.x > hit.maxX - r { cx = hit.maxX - r } else { return true }
        let cy = hit.maxY - r
        return hypot(point.x - cx, point.y - cy) <= r
    }

    // MARK: Lash

    /// Where Lash sits, panel space: always on the right, so he never has to cross the notch. Lash lives outside the
    /// per-presentation content so it can glide and grow between presentations with the island's spring.
    func lashRect(for presentation: IslandPresentation) -> CGRect {
        let island = islandRect(for: presentation)
        let h = notchSize.height
        let side: CGFloat, center: CGPoint
        switch presentation {
        case .closed:
            // Just left of the timer's bar.
            side = min(h - 6, Self.closedLashSide)
            let right = island.maxX - Self.fuseInset - Self.fuseWidth - Self.fuseGap
            center = CGPoint(x: right - side / 2, y: h / 2 + 0.5)
        case .peek:
            side = 50
            center = CGPoint(x: island.maxX - 40, y: island.height / 2 + 1)
        case .whipping:
            side = max(30, h + 4)
            center = CGPoint(x: island.maxX - Self.whipWing / 2 - 4, y: island.height / 2 + 1)
        case .expanded:
            side = 98
            center = CGPoint(x: island.maxX - 70, y: h + 54)
        case .warning:
            side = 100
            center = CGPoint(x: island.maxX - 70, y: h + Self.warningBody / 2 - 2)
        }
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Where Lash's eyes are, panel space (a little above the middle of Lash's box).
    func eyeCenter(for presentation: IslandPresentation) -> CGPoint {
        let rect = lashRect(for: presentation)
        return CGPoint(x: rect.midX, y: rect.minY + rect.height * LashFigure.eyeLine)
    }

    // MARK: Screen placement

    /// The panel's frame, Cocoa global: top edge flush with the screen top, centred on the notch.
    func panelFrame(in geometry: NotchGeometry) -> CGRect {
        let size = panelSize
        return CGRect(x: geometry.notchRect.midX - size.width / 2,
                      y: geometry.screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Cocoa global point → panel space of a panel whose Cocoa frame is `panelFrame`.
    static func panelPoint(fromCocoa point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: panelFrame.maxY - point.y)
    }

    /// Panel space → Cocoa global.
    static func cocoaPoint(fromPanel point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x + panelFrame.minX, y: panelFrame.maxY - point.y)
    }

    /// Where the overlay holds the whip on the island's screen, Cocoa global: centred under the notch, `whipGripInset`
    /// inside the whipping island's bottom edge.
    func whipGrip(in geometry: NotchGeometry) -> CGPoint {
        CGPoint(x: geometry.notchRect.midX,
                y: geometry.screenFrame.maxY - islandSize(for: .whipping).height + Self.whipGripInset)
    }

    /// `whipGrip(in:)` for the island laid out on `geometry`.
    static func whipGrip(for geometry: NotchGeometry) -> CGPoint {
        IslandLayout(geometry: geometry).whipGrip(in: geometry)
    }

    /// Where the whip you pull out yourself hangs, Cocoa global: in the whipping island's right end, as far inside
    /// its bottom edge as Lash's grip. It slides out from under that end, and reels back into it.
    func whipPullGrip(in geometry: NotchGeometry) -> CGPoint {
        let grip = whipGrip(in: geometry)
        return CGPoint(x: geometry.notchRect.maxX + Self.whipWing - Self.whipPullInset, y: grip.y)
    }

    /// `whipPullGrip(in:)` for the island laid out on `geometry`.
    static func whipPullGrip(for geometry: NotchGeometry) -> CGPoint {
        IslandLayout(geometry: geometry).whipPullGrip(in: geometry)
    }
}
