import AppKit

/// A believable fake desktop (wallpaper, menu bar with a notch, a browser window and a kitty-style terminal
/// full of text). Stands in for a real screenshot in demos and tests, so shards and OCR have real pixels.
enum FakeBackdrop {
    struct Rendered {
        /// Full image at `scale` pixels per point; row 0 is the top of the screen.
        let image: CGImage
        /// The terminal window, scene coordinates.
        let terminalRect: CGRect
        /// The lines of text drawn inside the terminal, top to bottom.
        let terminalLines: [String]
    }

    static let terminalLines: [String] = [
        "~/Documents/lightstick/Whiplash on main via swift 6.4",
        "$ swift build -c release",
        "Building for production...",
        "[42/42] Linking Whiplash",
        "Build complete! (38.17s)",
        "$ git status",
        "On branch main",
        "Changes not staged for commit:",
        "  modified:   Sources/Whiplash/Whip/WhipNode.swift",
        "  modified:   Sources/Whiplash/FX/DestructionLayer.swift",
        "$ npm install --legacy-peer-deps",
        "added 1337 packages, and audited 1338 packages in 42s",
        "found 0 vulnerabilities",
        "$ ssh prod-db-01 'tail -f /var/log/app.log'",
        "ERROR connection reset by peer (retrying in 5s)",
        "$ sudo rm -rf node_modules && echo done",
        "done",
        "$ claude --dangerously-skip-sleep",
        "zsh: command not found: touch-grass",
        "$ make coffee",
        "make: *** No rule to make target 'coffee'.  Stop.",
        "$ ▌",
    ]

    static let notchColor = NSColor.black

    static func terminalRect(for size: CGSize) -> CGRect {
        CGRect(x: size.width * 0.18, y: size.height * 0.14, width: size.width * 0.62, height: size.height * 0.64).integral
    }

    static func render(size: CGSize = DemoDefaults.screenSize, scale: CGFloat = 1) -> Rendered {
        let pixelW = Int(size.width * scale), pixelH = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx

        // Wallpaper: a Sonoma-ish dusk gradient with soft blobs.
        let wallpaper = NSGradient(colors: [
            NSColor(srgbRed: 0.10, green: 0.07, blue: 0.28, alpha: 1),
            NSColor(srgbRed: 0.42, green: 0.16, blue: 0.48, alpha: 1),
            NSColor(srgbRed: 0.95, green: 0.45, blue: 0.35, alpha: 1),
        ])!
        wallpaper.draw(in: CGRect(origin: .zero, size: size), angle: 65)
        for (i, c) in [NSColor.systemTeal, .systemPurple, .systemOrange].enumerated() {
            let r = size.width * (0.22 + 0.06 * CGFloat(i))
            let center = CGPoint(x: size.width * (0.15 + 0.35 * CGFloat(i)), y: size.height * (0.25 + 0.2 * CGFloat(i % 2)))
            NSGradient(colors: [c.withAlphaComponent(0.35), c.withAlphaComponent(0)])!
                .draw(fromCenter: center, radius: 0, toCenter: center, radius: r, options: [])
        }

        // A background "browser" window.
        let browser = CGRect(x: size.width * 0.52, y: size.height * 0.30, width: size.width * 0.42, height: size.height * 0.55)
        drawWindow(browser, background: NSColor(white: 0.97, alpha: 1), titleBar: NSColor(white: 0.9, alpha: 1))
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.darkGray]
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.black]
        ("10 Signs You've Been in the Terminal Too Long" as NSString)
            .draw(in: CGRect(x: browser.minX + 24, y: browser.maxY - 110, width: browser.width - 48, height: 70), withAttributes: headAttrs)
        let signs = ["1. You alias cd ..", "2. ls in Finder search", "3. Ctrl-C to close tabs", "4. Your cat is `cat`",
                     "5. You dream in ANSI", "6. Sunlight: 404", "7. You grep your fridge", "8. vim: can't quit",
                     "9. Friends? `whoami`"]
        let textX = terminalRect(for: size).maxX + 18
        for (i, sign) in signs.enumerated() {
            (sign as NSString).draw(at: CGPoint(x: textX, y: browser.maxY - 150 - CGFloat(i) * 30), withAttributes: bodyAttrs)
        }

        // The terminal, in front.
        let term = terminalRect(for: size)
        drawWindow(term, background: terminalBackground,
                   titleBar: NSColor(srgbRed: 0.14, green: 0.14, blue: 0.19, alpha: 1))
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                         .foregroundColor: NSColor(white: 0.75, alpha: 1)]
        ("kitty — zsh — 132×40" as NSString).draw(at: CGPoint(x: term.midX - 70, y: term.maxY - 21), withAttributes: titleAttrs)
        for line in lineLayout(for: size) {
            (line.text as NSString).draw(at: line.origin, withAttributes: [.font: terminalFont, .foregroundColor: line.color])
        }

        // Menu bar with the notch.
        let geometry = NotchGeometry.demo(size: size)
        NSColor(white: 0.08, alpha: 0.55).setFill()
        CGRect(x: 0, y: size.height - geometry.menuBarHeight, width: size.width, height: geometry.menuBarHeight).fill()
        let menuAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        ("   kitty    Shell    Edit    View    Window    Help" as NSString)
            .draw(at: CGPoint(x: 20, y: size.height - 26), withAttributes: menuAttrs)
        ("Wed 24 Sep  14:02" as NSString).draw(at: CGPoint(x: size.width - 170, y: size.height - 26), withAttributes: menuAttrs)
        notchColor.setFill()
        NSBezierPath(roundedRect: geometry.notchRect.insetBy(dx: 0, dy: -10), xRadius: 10, yRadius: 10).fill()

        NSGraphicsContext.restoreGraphicsState()
        return Rendered(image: ctx.makeImage()!, terminalRect: term, terminalLines: terminalLines)
    }

    /// The fake desktop as if it were a real capture of a screen at Cocoa origin (0,0).
    static func snapshot(size: CGSize = DemoDefaults.screenSize, scale: CGFloat = 2) -> ScreenSnapshot {
        ScreenSnapshot(image: render(size: size, scale: scale).image, screenFrame: CGRect(origin: .zero, size: size), scale: scale)
    }

    // MARK: - Terminal text layout (shared by drawing and ground truth)

    static let terminalFont = NSFont(name: "Menlo", size: 15) ?? NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let terminalBackground = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.13, alpha: 1)

    struct LineLayout {
        let text: String
        /// Bottom-left of the line box, scene coordinates (what NSString.draw(at:) takes).
        let origin: CGPoint
        let color: NSColor
    }

    static func lineLayout(for size: CGSize) -> [LineLayout] {
        let term = terminalRect(for: size)
        var result: [LineLayout] = []
        var y = term.maxY - 60
        for line in terminalLines {
            let color: NSColor
            if line.hasPrefix("$") { color = NSColor(srgbRed: 0.55, green: 0.9, blue: 0.55, alpha: 1) }
            else if line.contains("ERROR") || line.contains("***") || line.contains("not found") { color = NSColor(srgbRed: 1, green: 0.42, blue: 0.42, alpha: 1) }
            else if line.hasPrefix("~") { color = NSColor(srgbRed: 0.45, green: 0.7, blue: 1, alpha: 1) }
            else { color = NSColor(white: 0.88, alpha: 1) }
            result.append(LineLayout(text: line, origin: CGPoint(x: term.minX + 18, y: y), color: color))
            y -= 23
            if y < term.minY + 10 { break }
        }
        return result
    }

    /// The exact per-character glyphs of the fake terminal (what a perfect OCR would return), with crops of
    /// `render(size:scale:)`'s image. Use as test data for FX demos and as ground truth for TextHarvester.
    static func groundTruthGlyphs(size: CGSize = DemoDefaults.screenSize, scale: CGFloat = 2) -> [GlyphSample] {
        let image = render(size: size, scale: scale).image
        let attrs: [NSAttributedString.Key: Any] = [.font: terminalFont]
        let advance = ("M" as NSString).size(withAttributes: attrs).width
        let lineHeight = ("Mg" as NSString).size(withAttributes: attrs).height
        var glyphs: [GlyphSample] = []
        for line in lineLayout(for: size) {
            for (i, ch) in line.text.enumerated() where !ch.isWhitespace {
                let rect = CGRect(x: line.origin.x + CGFloat(i) * advance, y: line.origin.y, width: advance, height: lineHeight)
                let pixels = CoordinateSpace.imagePixels(fromScene: rect, sceneHeight: size.height, scale: scale)
                glyphs.append(GlyphSample(text: String(ch), rect: rect, image: image.cropping(to: pixels),
                                          color: line.color, background: terminalBackground, fontSize: terminalFont.pointSize))
            }
        }
        return glyphs
    }

    private static func drawWindow(_ rect: CGRect, background: NSColor, titleBar: NSColor) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let bar = CGRect(x: rect.minX, y: rect.maxY - 30, width: rect.width, height: 30)
        let barPath = NSBezierPath(roundedRect: bar, xRadius: 12, yRadius: 12)
        barPath.append(NSBezierPath(rect: bar.insetBy(dx: 0, dy: 0).divided(atDistance: 15, from: .minYEdge).slice))
        titleBar.setFill()
        barPath.fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.minX + 14 + CGFloat(i) * 20, y: rect.maxY - 21, width: 12, height: 12)).fill()
        }
    }
}
