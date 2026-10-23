import AppKit
import Vision

/// Peels the text off a screenshot so it can fall: Vision OCR, then one box, crop and colour pair per character.
///
/// Pipeline: crop the snapshot to the focus → `VNRecognizeTextRequest` → for each line, measure its ink in one
/// bitmap of the region (Vision's boxes are loose) and place its characters with `GlyphBoxes` (monospaced grid
/// for terminal text) → crop, background and ink colour per character.
///
/// `.accurate` vs `.fast`, measured on FakeBackdrop's terminal (M3 Pro, 2× snapshot, 604 characters):
/// - `.accurate`: 604/604 characters found, 99.8 % read right (the cursor block reads as "I"), mean centre error
///   0.2 pt; ~120 ms per harvest in release, ~190 ms in debug. Its per-character boxes are degenerate, which
///   the ink-measured grid more than makes up for.
/// - `.fast`: 591/604 found (drops `$` prompts, splits words), mean centre error 0.35 pt, ~30 ms in release.
/// Both fit the ~700 ms budget easily, so the one that finds and places more letters wins. CaptureHarvestTests
/// re-measures all of this.
enum TextHarvester {
    /// Vision settings for one harvest.
    struct Recognition {
        var level: VNRequestTextRecognitionLevel
        /// Smallest text to look for, in points (11 pt terminal text has ~8 pt capitals).
        var minimumTextHeight: CGFloat

        static let standard = Recognition(level: .accurate, minimumTextHeight: 7)
    }

    /// Font size estimates. Monospaced fonts (Menlo, SF Mono, Monaco, JetBrains Mono, Fira Code, …) advance
    /// ~0.6 em per character, which pins the size down from the measured pitch. Other text falls back to
    /// Vision's line height, which runs ~1.13 em (FakeBackdrop's 15 pt Menlo: ~17 pt boxes, ±3 pt with content).
    static let monospacedAdvancePerPoint: CGFloat = 0.6
    static let fontSizePerLineHeight: CGFloat = 0.88

    /// OCRs the snapshot and returns per-character glyphs in scene coordinates, each with a crop of the
    /// screenshot. Text inside `focus` (scene coords) is preferred when capping at `maxGlyphs`.
    ///
    /// With a `focus`, only that part of the screen is read (it is the terminal window, and it is faster), so
    /// every glyph lies inside it; the cap then keeps glyphs in reading order, top to bottom. A focus that misses
    /// the screen entirely reads the whole screen. Glyphs come back in reading order; each `rect` is exactly the
    /// area of its `image` (the letter's cell plus ~1 px), and colours are in the screenshot's colour space.
    ///
    /// Runs off the main thread (Vision blocks, so it gets a dispatch queue rather than the cooperative pool).
    /// Cancelling the calling task stops the work at the next checkpoint and returns an empty array.
    static func harvest(from snapshot: ScreenSnapshot, focus: CGRect?, maxGlyphs: Int) async -> [GlyphSample] {
        await harvest(from: snapshot, focus: focus, maxGlyphs: maxGlyphs, recognition: .standard)
    }

    /// `harvest(from:focus:maxGlyphs:)` with explicit Vision settings.
    static func harvest(from snapshot: ScreenSnapshot, focus: CGRect?, maxGlyphs: Int,
                        recognition: Recognition) async -> [GlyphSample] {
        guard maxGlyphs > 0 else { return [] }
        let job = HarvestJob(snapshot: snapshot, focus: focus, maxGlyphs: maxGlyphs, recognition: recognition)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workQueue.async { continuation.resume(returning: job.run()) }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// Fake terminal text laid out inside `region` (scene coords) for glass mode (no screenshot).
    /// Each call tells a different (terrible) terminal story; see `SyntheticTerminal`.
    static func synthetic(in region: CGRect, maxGlyphs: Int) -> [GlyphSample] {
        SyntheticTerminal.glyphs(in: region, maxGlyphs: maxGlyphs, seed: .random(in: .min ... .max))
    }

    /// Loads Vision's text recognizer in the background so the first punishment doesn't pay for it. A process
    /// pays ~80 ms for that normally, but a new or moved executable can wait 15–90 s while macOS compiles the model
    /// for the Neural Engine (measured on this M3 Pro, sometimes on every launch of a dev build). Glyphs that late
    /// miss the shatter entirely: the sequencer gives OCR at most ~1.4 s after the last strike.
    ///
    /// Call from the main thread whenever screen capture becomes usable (launch, permission granted, setting turned
    /// on). Idempotent: the work runs once per process; `completion` runs on the main thread once the recognizer is
    /// warm (right away, asynchronously, if it already is).
    static func prewarm(then completion: (() -> Void)? = nil) {
        switch warmUp {
        case .warm:
            if let completion { DispatchQueue.main.async(execute: completion) }
        case .warming(let waiting):
            warmUp = .warming(waiting + (completion.map { [$0] } ?? []))
        case .cold:
            warmUp = .warming(completion.map { [$0] } ?? [])
            workQueue.async {
                if let image = prewarmImage() {
                    let request = VNRecognizeTextRequest()
                    Recognition.standard.configure(request, regionHeight: CGFloat(image.height))
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    } catch {
                        captureLog.error("OCR prewarm failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                DispatchQueue.main.async {
                    guard case .warming(let waiting) = warmUp else { return }
                    warmUp = .warm
                    waiting.forEach { $0() }
                }
            }
        }
    }

    /// Whether `prewarm` has finished in this process (main thread only).
    static var isWarm: Bool {
        if case .warm = warmUp { return true }
        return false
    }

    private enum WarmUp {
        case cold
        /// Running; these run when it is done.
        case warming([() -> Void])
        case warm
    }

    /// Main thread only.
    private static var warmUp = WarmUp.cold

    /// A few words of dark-on-light text: enough for Vision to load its detector *and* recognizer.
    static func prewarmImage() -> CGImage? {
        let size = CGSize(width: 240, height: 48)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("$ whip --crack" as NSString).draw(at: CGPoint(x: 12, y: 12),
                                            withAttributes: [.font: SyntheticTerminal.font, .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Blocking Vision work runs here, not on Swift's cooperative pool.
    private static let workQueue = DispatchQueue(label: "com.lightstick.whiplash.ocr", qos: .userInitiated,
                                                 attributes: .concurrent)
}

extension TextHarvester.Recognition {
    /// `regionHeight` is the height, in points, of the image Vision will read.
    func configure(_ request: VNRecognizeTextRequest, regionHeight: CGFloat) {
        request.recognitionLevel = level
        request.usesLanguageCorrection = false // it's code: `rm -rf` must not become "rm -rd"
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        if regionHeight > 0 {
            request.minimumTextHeight = Float(min(1, minimumTextHeight / regionHeight))
        }
    }
}

/// One harvest: crop → OCR → character boxes → crops and colours. Thread-safe to cancel from anywhere.
private final class HarvestJob: @unchecked Sendable {
    private let snapshot: ScreenSnapshot
    private let focus: CGRect?
    private let maxGlyphs: Int
    private let recognition: TextHarvester.Recognition

    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?

    init(snapshot: ScreenSnapshot, focus: CGRect?, maxGlyphs: Int, recognition: TextHarvester.Recognition) {
        self.snapshot = snapshot
        self.focus = focus
        self.maxGlyphs = maxGlyphs
        self.recognition = recognition
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = request
        lock.unlock()
        running?.cancel()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run() -> [GlyphSample] {
        let image = snapshot.image
        let scale = snapshot.scale
        let sceneHeight = snapshot.screenFrame.height
        let screenBounds = CGRect(origin: .zero, size: snapshot.screenFrame.size)
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard scale > 0 else { return [] }

        // The part of the screen to read: the focus, or the whole screen if there is none (or it is off-screen).
        let wanted = focus.map { $0.intersection(screenBounds) }.flatMap { $0.isNull || $0.isEmpty ? nil : $0 } ?? screenBounds
        let regionPixels = CoordinateSpace.imagePixels(fromScene: wanted, sceneHeight: sceneHeight, scale: scale)
            .intersection(imageBounds)
        guard !regionPixels.isNull, !regionPixels.isEmpty, let regionImage = image.cropping(to: regionPixels) else { return [] }
        let region = scene(fromPixels: regionPixels)

        // OCR.
        let request = VNRecognizeTextRequest()
        recognition.configure(request, regionHeight: region.height)
        lock.lock()
        let wasCancelled = cancelled
        self.request = request
        lock.unlock()
        guard !wasCancelled else { return [] }
        do {
            try VNImageRequestHandler(cgImage: regionImage, options: [:]).perform([request])
        } catch {
            if !isCancelled { captureLog.error("OCR failed: \(error.localizedDescription, privacy: .public)") }
            return []
        }
        guard !isCancelled else { return [] }
        let observations = (request.results ?? []).filter { !$0.boundingBox.isEmpty }

        // Character boxes (scene coordinates), in reading order, capped. Vision's boxes are loose; the region's
        // pixels pull each line and word in to its ink.
        let pixels = RegionPixels(image: regionImage, origin: regionPixels.origin)
        if pixels == nil { captureLog.error("OCR: could not read the region's pixels; boxes stay loose, colours default") }
        func toScene(_ normalized: CGRect) -> CGRect {
            CGRect(x: region.minX + normalized.minX * region.width, y: region.minY + normalized.minY * region.height,
                   width: normalized.width * region.width, height: normalized.height * region.height)
        }
        func toPixels(_ rect: CGRect) -> CGRect {
            CoordinateSpace.imagePixels(fromScene: rect, sceneHeight: sceneHeight, scale: scale).intersection(regionPixels)
        }
        var boxes: [(character: Character, rect: CGRect, fontSize: CGFloat)] = []
        for index in GlyphBoxes.readingOrder(of: observations.map(\.boundingBox)) where boxes.count < maxGlyphs {
            let observation = observations[index]
            guard let candidate = observation.topCandidates(1).first else { continue }
            let visionLine = toScene(observation.boundingBox)
            let ink = pixels.flatMap { LineInk(pixels: $0, line: toPixels(visionLine)) }
            let line = ink?.bounds(in: toPixels(visionLine)).map(scene(fromPixels:)) ?? visionLine
            let layout = GlyphBoxes.layout(
                text: candidate.string, lineBox: line,
                boxFor: { range in (try? candidate.boundingBox(for: range)).map { toScene($0.boundingBox) } },
                inkProfile: { word in
                    ink?.columns(in: toPixels(word)).map {
                        GlyphBoxes.InkProfile(originX: CGFloat($0.firstColumn) / scale, step: 1 / scale, columns: $0.counts)
                    }
                })
            let fontSize = layout.pitch.map { $0 / TextHarvester.monospacedAdvancePerPoint }
                ?? visionLine.height * TextHarvester.fontSizePerLineHeight
            for box in layout.boxes.prefix(maxGlyphs - boxes.count) {
                boxes.append((box.character, box.rect, fontSize))
            }
            if isCancelled { return [] }
        }

        // Crops and colours.
        let pad = 1 / scale // ~1 px of slack so anti-aliased edges come along with the crop
        var glyphs: [GlyphSample] = []
        glyphs.reserveCapacity(boxes.count)
        for (i, box) in boxes.enumerated() {
            if i % 64 == 0, isCancelled { return [] }
            let cropPixels = toPixels(box.rect.insetBy(dx: -pad, dy: -pad))
            guard !cropPixels.isNull, !cropPixels.isEmpty else { continue }
            let background = pixels?.background(around: cropPixels)
            let ink = background.flatMap { pixels?.ink(in: cropPixels, against: $0) }
            glyphs.append(GlyphSample(
                text: String(box.character),
                rect: scene(fromPixels: cropPixels), // exactly what the crop covers
                image: image.cropping(to: cropPixels),
                color: ink.flatMap { pixels?.color($0) } ?? .white,
                background: background.flatMap { pixels?.color($0) } ?? .black,
                fontSize: box.fontSize))
        }
        return glyphs
    }

    /// Snapshot pixel rect (row 0 = top) → scene rect (y-up points). Inverse of CoordinateSpace.imagePixels.
    private func scene(fromPixels rect: CGRect) -> CGRect {
        let scale = snapshot.scale
        return CGRect(x: rect.minX / scale, y: snapshot.screenFrame.height - rect.maxY / scale,
                      width: rect.width / scale, height: rect.height / scale)
    }
}

/// Ink detection for one line of text: the line's background, and how far from it a pixel must be to count as ink
/// (35 % of the line's strongest contrast, so anti-aliased fringes and background noise don't).
private struct LineInk {
    let pixels: RegionPixels
    let background: RegionPixels.RGB
    let minimumDistance: Int

    /// nil when the line has no legible contrast; its boxes then stay as Vision reported them.
    init?(pixels: RegionPixels, line: CGRect) {
        guard let background = pixels.background(around: line),
              let strongest = pixels.ink(in: line, against: background) else { return nil }
        let contrast = Double(strongest.distanceSquared(to: background)).squareRoot()
        guard contrast >= 32 else { return nil }
        self.pixels = pixels
        self.background = background
        self.minimumDistance = Int(contrast * 0.35)
    }

    /// The line's ink band inside `rect` (snapshot pixels), ignoring strays from neighbouring lines.
    func bounds(in rect: CGRect) -> CGRect? {
        pixels.inkBounds(in: rect, against: background, minimumDistance: minimumDistance)
    }

    /// Ink per pixel column of `rect` (snapshot pixels).
    func columns(in rect: CGRect) -> (firstColumn: Int, counts: [Int])? {
        pixels.columnInk(in: rect, against: background, minimumDistance: minimumDistance)
    }
}
