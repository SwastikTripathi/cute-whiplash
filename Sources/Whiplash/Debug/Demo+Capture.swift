import AppKit
import SpriteKit

extension DemoRegistry {
    static var captureDemos: [Demo] {
        [
            Demo(name: "capture.ocr",
                 summary: "OCR of FakeBackdrop's terminal: green = right box & letter, amber = right box, red = not in ground truth",
                 payload: .scene(SceneDemo(duration: 0.1, captureTimes: [0], compositeOverBackdrop: true, scale: 2,
                                           make: CaptureDemo.ocrScene))),
            Demo(name: "capture.peel",
                 summary: "Harvested crops peel off in a wave and drop 40 pt, leaving their sampled background behind",
                 payload: .scene(SceneDemo(duration: 1.8, captureTimes: [0, 0.5, 0.9, 1.8], compositeOverBackdrop: false,
                                           scale: 2, make: { CaptureDemo.PeelScene(size: $0) },
                                           onFrame: { scene, t in (scene as? CaptureDemo.PeelScene)?.pose(at: t) }))),
            Demo(name: "capture.retype",
                 summary: "The terminal rebuilt from OCR data alone: letter, ink colour, background and font size per glyph",
                 payload: .scene(SceneDemo(duration: 0.1, captureTimes: [0], compositeOverBackdrop: false, scale: 2,
                                           make: CaptureDemo.retypeScene))),
            Demo(name: "capture.synthetic",
                 summary: "Glass-mode synthetic terminal text (SKLabelNodes) inside the fake terminal window",
                 payload: .scene(SceneDemo(duration: 0.1, captureTimes: [0], compositeOverBackdrop: true, scale: 2,
                                           make: CaptureDemo.syntheticScene))),
        ]
    }
}

/// Scenes for the capture demos. OCR runs once per process and is shared between them.
private enum CaptureDemo {
    struct Harvest {
        let glyphs: [GlyphSample]
        let coldSeconds: TimeInterval
        let warmSeconds: TimeInterval
    }

    /// Harvests FakeBackdrop's terminal twice (cold, then warm) and keeps the second result. Vision is async, so
    /// the work runs detached while this thread waits; nothing in it needs the main thread.
    static let harvest: Harvest = {
        final class Box: @unchecked Sendable { var value: Harvest? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let size = DemoDefaults.screenSize
        let snapshot = FakeBackdrop.snapshot(size: size)
        let focus = FakeBackdrop.terminalRect(for: size)
        Task.detached {
            var start = Date()
            _ = await TextHarvester.harvest(from: snapshot, focus: focus, maxGlyphs: 4000)
            let cold = Date().timeIntervalSince(start)
            start = Date()
            let glyphs = await TextHarvester.harvest(from: snapshot, focus: focus, maxGlyphs: 4000)
            box.value = Harvest(glyphs: glyphs, coldSeconds: cold, warmSeconds: Date().timeIntervalSince(start))
            done.signal()
        }
        done.wait()
        return box.value ?? Harvest(glyphs: [], coldSeconds: 0, warmSeconds: 0)
    }()

    static let menlo = "Menlo-Regular"
    static let voidColor = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.035, alpha: 1)

    // MARK: capture.ocr

    static func ocrScene(size: CGSize) -> SKScene {
        let scene = SKScene(size: size)
        scene.backgroundColor = .clear
        let truth = FakeBackdrop.groundTruthGlyphs(size: size)
        let glyphs = harvest.glyphs

        var exact = 0, boxOnly = 0, stray = 0, ious: [CGFloat] = []
        for glyph in glyphs {
            let centre = CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)
            let color: NSColor
            if let match = truth.first(where: { $0.rect.contains(centre) }) {
                let overlap = match.rect.intersection(glyph.rect)
                let intersection = overlap.width * overlap.height
                ious.append(intersection / (match.rect.width * match.rect.height + glyph.rect.width * glyph.rect.height - intersection))
                if match.text == glyph.text { exact += 1; color = .systemGreen } else { boxOnly += 1; color = .systemOrange }
            } else {
                stray += 1
                color = .systemRed
            }
            let outline = SKShapeNode(rect: glyph.rect)
            outline.strokeColor = color
            outline.lineWidth = 1
            scene.addChild(outline)
        }
        let missed = truth.filter { gt in !glyphs.contains { gt.rect.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) } }
        for glyph in missed {
            let outline = SKShapeNode(rect: glyph.rect)
            outline.strokeColor = .magenta
            outline.lineWidth = 2
            scene.addChild(outline)
        }

        let matched = truth.count - missed.count
        let meanIoU = ious.isEmpty ? 0 : ious.reduce(0, +) / CGFloat(ious.count)
        addPanel(to: scene, at: CGPoint(x: 40, y: size.height - 64), lines: [
            ("TextHarvester · FakeBackdrop terminal @2x", .white),
            (String(format: "%d/%d ground-truth glyphs matched (%.1f%%)", matched, truth.count,
                    100 * Double(matched) / Double(max(1, truth.count))), .systemGreen),
            (String(format: "%d right letter · %d right box, other letter · %d not in truth · %d missed",
                    exact, boxOnly, stray, missed.count), NSColor(white: 0.85, alpha: 1)),
            (String(format: "mean IoU %.2f · OCR %.0f ms (first call in this process: %.2f s)", meanIoU,
                    harvest.warmSeconds * 1000, harvest.coldSeconds), NSColor(white: 0.85, alpha: 1)),
        ])
        return scene
    }

    // MARK: capture.peel

    /// Crops as sprites over a dark void, peeling off in a wave (left to right, lines staggered top to bottom),
    /// dropping 40 pt with a springy landing and a wobble. Posed from the clock by `pose(at:)`.
    final class PeelScene: SKScene {
        private var peels: [(sprite: SKSpriteNode, home: CGPoint, delay: TimeInterval, wobble: CGFloat)] = []
        static let drop: CGFloat = 40
        static let duration: TimeInterval = 0.55

        override init(size: CGSize) {
            super.init(size: size)
            backgroundColor = voidColor
            let terminal = FakeBackdrop.terminalRect(for: size)
            let frame = SKShapeNode(rect: terminal, cornerRadius: 12)
            frame.strokeColor = NSColor(white: 1, alpha: 0.12)
            frame.lineWidth = 1
            addChild(frame)

            let rows = Set(harvest.glyphs.map { Int($0.rect.midY / 4) }).sorted(by: >)
            for (index, glyph) in harvest.glyphs.enumerated() {
                // The patch that will cover the letter's old spot, in its sampled background colour.
                let home = CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)
                let patch = SKSpriteNode(color: glyph.background, size: glyph.rect.size)
                patch.position = home
                addChild(patch)

                guard let image = glyph.image else { continue }
                let texture = SKTexture(cgImage: image)
                texture.filteringMode = .nearest
                let sprite = SKSpriteNode(texture: texture, size: glyph.rect.size)
                sprite.position = home
                sprite.zPosition = 1
                addChild(sprite)

                let across = (glyph.rect.midX - terminal.minX) / terminal.width
                let row = CGFloat(rows.firstIndex(of: Int(glyph.rect.midY / 4)) ?? 0)
                let wobble = CGFloat((index * 37) % 11 - 5) * 0.07 // deterministic, so runs are comparable
                peels.append((sprite, home, TimeInterval(across * 0.55 + row * 0.012), wobble))
            }
            addPanel(to: self, at: CGPoint(x: 40, y: size.height - 64), lines: [
                ("\(harvest.glyphs.count) crops, each dropped \(Int(Self.drop)) pt", .white),
                ("patches left behind = sampled background colour", NSColor(white: 0.85, alpha: 1)),
            ])
        }

        required init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func pose(at time: TimeInterval) {
            for peel in peels {
                let t = CGFloat(min(1, max(0, (time - peel.delay) / Self.duration)))
                peel.sprite.position = CGPoint(x: peel.home.x, y: peel.home.y - Self.drop * easeOutBack(t))
                peel.sprite.zRotation = peel.wobble * sin(.pi * t) // tilts on the way down, lands straight
            }
        }
    }

    /// Overshoots a little past 1 and settles: a springy landing.
    static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let overshoot: CGFloat = 1.9
        let u = t - 1
        return 1 + u * u * ((overshoot + 1) * u + overshoot)
    }

    // MARK: capture.retype

    static func retypeScene(size: CGSize) -> SKScene {
        let scene = SKScene(size: size)
        scene.backgroundColor = voidColor
        // OCR rects hug each line's ink, so a line's baseline is its bottom edge, unless the line has letters that
        // descend below it (Menlo's descenders reach ~0.24 em). Labels must sit on baselines: SKLabelNode's
        // `.center` centres each glyph's own ink and makes the text dance.
        let descending = Set("gjpqy,;_()[]{}|/$@")
        let lineHasDescender = Dictionary(grouping: harvest.glyphs, by: { $0.rect.minY })
            .mapValues { line in line.contains { descending.contains(Character($0.text)) } }
        for glyph in harvest.glyphs {
            let patch = SKSpriteNode(color: glyph.background, size: glyph.rect.size)
            patch.position = CGPoint(x: glyph.rect.midX, y: glyph.rect.midY)
            scene.addChild(patch)

            let label = SKLabelNode(text: glyph.text)
            label.fontName = menlo
            label.fontSize = glyph.fontSize
            label.fontColor = glyph.color
            label.verticalAlignmentMode = .baseline
            label.horizontalAlignmentMode = .center
            let descent = lineHasDescender[glyph.rect.minY] == true ? glyph.fontSize * 0.24 : 0
            label.position = CGPoint(x: glyph.rect.midX, y: glyph.rect.minY + 0.5 + descent)
            label.zPosition = 1
            scene.addChild(label)
        }
        let sizes = harvest.glyphs.map(\.fontSize).sorted()
        addPanel(to: scene, at: CGPoint(x: 40, y: size.height - 64), lines: [
            ("Rebuilt from GlyphSample data only — no screenshot pixels", .white),
            (String(format: "font size median %.1f pt (truth: 15 pt Menlo)", sizes.isEmpty ? 0 : sizes[sizes.count / 2]),
             NSColor(white: 0.85, alpha: 1)),
        ])
        return scene
    }

    // MARK: capture.synthetic

    static func syntheticScene(size: CGSize) -> SKScene {
        let scene = SKScene(size: size)
        scene.backgroundColor = .clear
        let terminal = FakeBackdrop.terminalRect(for: size)

        // Cover the fake terminal's own text with an empty kitty window.
        let window = SKShapeNode(rect: terminal, cornerRadius: 12)
        window.fillColor = FakeBackdrop.terminalBackground
        window.strokeColor = .clear
        scene.addChild(window)
        let titleBar = SKShapeNode(rect: CGRect(x: terminal.minX, y: terminal.maxY - 30, width: terminal.width, height: 30),
                                   cornerRadius: 12)
        titleBar.fillColor = NSColor(srgbRed: 0.14, green: 0.14, blue: 0.19, alpha: 1)
        titleBar.strokeColor = .clear
        scene.addChild(titleBar)
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            let light = SKShapeNode(circleOfRadius: 6)
            light.fillColor = color
            light.strokeColor = .clear
            light.position = CGPoint(x: terminal.minX + 20 + CGFloat(i) * 20, y: terminal.maxY - 15)
            scene.addChild(light)
        }

        let glyphs = SyntheticTerminal.glyphs(in: terminal, maxGlyphs: 6000, seed: 7)
        for glyph in glyphs {
            let label = SKLabelNode(text: glyph.text)
            label.fontName = menlo
            label.fontSize = glyph.fontSize
            label.fontColor = glyph.color
            label.horizontalAlignmentMode = .center
            label.verticalAlignmentMode = .baseline
            label.position = CGPoint(x: glyph.rect.midX, y: glyph.rect.minY + SyntheticTerminal.baselineOffset)
            scene.addChild(label)
        }
        addPanel(to: scene, at: CGPoint(x: 40, y: size.height - 64), lines: [
            ("TextHarvester.synthetic · \(glyphs.count) glyphs, seed 7", .white),
        ])
        return scene
    }

    // MARK: - Helpers

    /// A dark caption panel whose top-left corner is at `origin`.
    static func addPanel(to scene: SKScene, at origin: CGPoint, lines: [(String, NSColor)]) {
        let lineHeight: CGFloat = 24
        let panel = SKShapeNode(rect: CGRect(x: origin.x - 14, y: origin.y - CGFloat(lines.count) * lineHeight - 10,
                                             width: 760, height: CGFloat(lines.count) * lineHeight + 20), cornerRadius: 10)
        panel.fillColor = NSColor(white: 0, alpha: 0.78)
        panel.strokeColor = NSColor(white: 1, alpha: 0.15)
        panel.zPosition = 10
        scene.addChild(panel)
        for (i, line) in lines.enumerated() {
            let label = SKLabelNode(text: line.0)
            label.fontName = i == 0 ? "Menlo-Bold" : menlo
            label.fontSize = 16
            label.fontColor = line.1
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .top
            label.position = CGPoint(x: origin.x, y: origin.y - CGFloat(i) * lineHeight)
            label.zPosition = 11
            scene.addChild(label)
        }
    }
}
