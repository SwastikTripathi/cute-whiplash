import AppKit
import ImageIO
import SpriteKit
import SwiftUI
import UniformTypeIdentifiers

/// Headless demo driver behind `--demo`. Writes `<out>/<name>@<t>s.png` per captured frame
/// plus `<out>/<name>@sheet.png`, a labelled contact sheet of all frames of that demo.
enum DemoRunner {
    @MainActor
    static func run(options: LaunchOptions) -> Never {
        let query = options.demo ?? "list"
        let demos = DemoRegistry.all
        if query == "list" {
            for demo in demos { print("\(demo.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(demo.summary)") }
            exit(0)
        }
        let selected = demos.filter { query == "all" || $0.name == query || $0.name.hasPrefix(query + ".") }
        guard !selected.isEmpty else {
            FileHandle.standardError.write("No demo matches '\(query)'. Try --demo list\n".data(using: .utf8)!)
            exit(2)
        }
        let out = URL(fileURLWithPath: options.outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var failures = 0
        for demo in selected {
            let started = Date()
            let frames: [(String, CGImage)]
            switch demo.payload {
            case .scene(let spec): frames = renderScene(spec, size: demo.size)
            case .view(let spec): frames = renderView(spec, size: demo.size).map { [("view", $0)] } ?? []
            }
            if frames.isEmpty {
                failures += 1
                print("✗ \(demo.name): no frames rendered")
                continue
            }
            for (label, image) in frames {
                write(image, to: out.appendingPathComponent("\(demo.name)@\(label).png"))
            }
            if frames.count > 1, let sheet = contactSheet(frames, title: demo.name) {
                write(sheet, to: out.appendingPathComponent("\(demo.name)@sheet.png"))
            }
            print(String(format: "✓ %@ (%d frame%@, %.1fs) → %@", demo.name, frames.count, frames.count == 1 ? "" : "s",
                         Date().timeIntervalSince(started), out.path))
        }
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Scenes

    static func renderScene(_ spec: SceneDemo, size: CGSize) -> [(String, CGImage)] {
        let scene = spec.make(size)
        guard let renderer = OffscreenRenderer(scene: scene, pointSize: size, scale: spec.scale) else {
            print("Metal unavailable")
            return []
        }
        let backdrop = spec.compositeOverBackdrop ? FakeBackdrop.render(size: size, scale: spec.scale).image : nil
        let fps = 60.0
        let captures = spec.captureTimes.sorted()
        var nextCapture = 0
        var frames: [(String, CGImage)] = []
        let frameCount = Int((spec.duration * fps).rounded(.up))
        for frame in 0...frameCount {
            let t = Double(frame) / fps
            spec.onFrame?(scene, t)
            // Deliver whatever background work handed back to the main queue (e.g. baked letter atlases), as the
            // app's run loop would between frames.
            while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
            renderer.update(atTime: t)
            // Capture every requested time that falls inside this frame.
            while nextCapture < captures.count, captures[nextCapture] <= t + 0.5 / fps {
                if let image = renderer.snapshot() {
                    var composed = backdrop.flatMap { composite(image, over: $0) } ?? image
                    if let crop = spec.crop, let cropped = self.crop(composed, to: crop, canvas: size, scale: spec.scale) {
                        composed = cropped
                    }
                    frames.append((String(format: "%05.2fs", captures[nextCapture]), composed))
                }
                nextCapture += 1
            }
            if nextCapture >= captures.count { break }
        }
        return frames
    }

    /// `rect` (canvas points, y-up) of a frame rendered at `scale`.
    static func crop(_ image: CGImage, to rect: CGRect, canvas: CGSize, scale: CGFloat) -> CGImage? {
        let pixels = CGRect(x: rect.minX * scale, y: (canvas.height - rect.maxY) * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        return image.cropping(to: pixels)
    }

    static func composite(_ top: CGImage, over bottom: CGImage) -> CGImage? {
        guard let ctx = bitmapContext(width: bottom.width, height: bottom.height) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height)
        ctx.draw(bottom, in: rect)
        ctx.draw(top, in: rect)
        return ctx.makeImage()
    }

    // MARK: - SwiftUI views

    @MainActor
    static func renderView(_ spec: ViewDemo, size: CGSize) -> CGImage? {
        let content = spec.make()
            .frame(width: size.width, height: size.height)
            .background(spec.background.map { Color(nsColor: $0) } ?? Color.clear)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.cgImage
    }

    // MARK: - Output

    static func contactSheet(_ frames: [(String, CGImage)], title: String) -> CGImage? {
        guard let first = frames.first?.1 else { return nil }
        let columns = min(4, frames.count)
        let rows = Int(ceil(Double(frames.count) / Double(columns)))
        let cellW = 640
        let cellH = Int(Double(cellW) * Double(first.height) / Double(first.width))
        let pad = 8, labelH = 26
        let width = columns * (cellW + pad) + pad
        let height = rows * (cellH + labelH + pad) + pad + 34
        guard let ctx = bitmapContext(width: width, height: height) else { return nil }
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .bold), .foregroundColor: NSColor.white]
        (title as NSString).draw(at: CGPoint(x: pad, y: height - 28), withAttributes: titleAttrs)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.systemYellow]
        for (i, (label, image)) in frames.enumerated() {
            let col = i % columns, row = i / columns
            let x = pad + col * (cellW + pad)
            let yTop = height - 34 - row * (cellH + labelH + pad)
            (label as NSString).draw(at: CGPoint(x: x, y: yTop - 20), withAttributes: attrs)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: x, y: yTop - labelH - cellH, width: cellW, height: cellH))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    static func bitmapContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
