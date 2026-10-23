import AppKit

/// One RGB bitmap of the harvested part of a screenshot, drawn once and then used for every pixel question
/// (ink extents, backgrounds, ink colours), so a glyph costs a few hundred memory reads instead of a bitmap of
/// its own.
///
/// Pixels keep the screenshot's own colour space (no conversion), and the colours handed out are tagged with
/// it, so a background patch painted over a glyph matches the screenshot texture it sits on.
///
/// All rects are snapshot pixel coordinates (row 0 = top of the screen). Loops read raw memory: this runs for
/// every glyph while the whip is striking, and must stay quick even in debug builds.
final class RegionPixels {
    struct RGB: Equatable {
        var r: UInt8, g: UInt8, b: UInt8

        func distanceSquared(to other: RGB) -> Int {
            let dr = Int(r) - Int(other.r), dg = Int(g) - Int(other.g), db = Int(b) - Int(other.b)
            return dr * dr + dg * dg + db * db
        }
    }

    /// Where the bitmap's top-left pixel sits in the snapshot.
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int
    let colorSpace: CGColorSpace
    private let nsColorSpace: NSColorSpace
    /// RGBX, 4 bytes per pixel, row 0 = top.
    private let bytes: UnsafeMutablePointer<UInt8>

    /// Gap between a glyph box and the ring sampled for its background, and the ring's thickness (pixels).
    static let ringGap = 1
    static let ringThickness = 2

    /// `image` is the region's crop of the snapshot; `origin` is where that crop starts in the snapshot.
    init?(image: CGImage, origin: CGPoint) {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        bytes.initialize(repeating: 0, count: width * height * 4)
        let native = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let drawnSpace = [native, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }.first { space in
            guard let ctx = CGContext(data: bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard let drawnSpace else {
            bytes.deallocate()
            return nil
        }
        self.bytes = bytes
        self.originX = Int(origin.x.rounded())
        self.originY = Int(origin.y.rounded())
        self.width = width
        self.height = height
        self.colorSpace = drawnSpace
        self.nsColorSpace = NSColorSpace(cgColorSpace: drawnSpace) ?? .sRGB
    }

    deinit {
        bytes.deallocate()
    }

    /// Per-channel median of a thin ring of pixels just outside `rect`. Neighbouring letters poke into the
    /// ring's sides, but most of it is background, and the median ignores the rest. Falls back to the rect's own
    /// pixels when the ring lies entirely off the bitmap.
    func background(around rect: CGRect) -> RGB? {
        let gap = CGFloat(Self.ringGap), thickness = CGFloat(Self.ringThickness)
        var histogram = [Int](repeating: 0, count: 3 * 256)
        var samples = 0
        histogram.withUnsafeMutableBufferPointer { counts in
            guard let counts = counts.baseAddress else { return }
            if let outer = local(rect.insetBy(dx: -gap - thickness, dy: -gap - thickness)) {
                let inner = local(rect.insetBy(dx: -gap, dy: -gap))
                for y in outer.rows {
                    if let inner, inner.rows.contains(y) {
                        samples += accumulate(row: y, columns: outer.columns.lowerBound..<max(outer.columns.lowerBound, inner.columns.lowerBound), into: counts)
                        samples += accumulate(row: y, columns: min(outer.columns.upperBound, inner.columns.upperBound)..<outer.columns.upperBound, into: counts)
                    } else {
                        samples += accumulate(row: y, columns: outer.columns, into: counts)
                    }
                }
            }
            if samples == 0, let area = local(rect) {
                for y in area.rows { samples += accumulate(row: y, columns: area.columns, into: counts) }
            }
        }
        guard samples > 0 else { return nil }
        func median(_ channel: Int) -> UInt8 {
            var seen = 0
            for value in 0..<256 {
                seen += histogram[channel * 256 + value]
                if seen * 2 > samples { return UInt8(value) }
            }
            return 255
        }
        return RGB(r: median(0), g: median(1), b: median(2))
    }

    /// The pixel inside `rect` that differs most from `background`: a fully inked pixel of the letter, not an
    /// anti-aliased edge.
    func ink(in rect: CGRect, against background: RGB) -> RGB? {
        guard let area = local(rect) else { return nil }
        var best = pixel(area.columns.lowerBound, area.rows.lowerBound), bestDistance = -1
        for y in area.rows {
            var p = pixel(area.columns.lowerBound, y)
            var x = 0
            while x < area.columns.count {
                let distance = Self.distanceSquared(p, background)
                if distance > bestDistance {
                    bestDistance = distance
                    best = p
                }
                p += 4
                x += 1
            }
        }
        return RGB(r: best[0], g: best[1], b: best[2])
    }

    /// Bounding box of the pixels inside `rect` that differ from `background` by at least `minimumDistance`
    /// (Euclidean, 0–255 per channel). nil if there are none.
    ///
    /// A faint band of ink that touches the top or bottom edge of `rect` and is cut off from the rest by empty
    /// rows is ignored: in a tightly spaced terminal a loose line box catches the descenders of the line above
    /// or the ascenders of the line below that way. (An i-dot never touches the edge of a box that contains the
    /// whole line, so it survives.)
    func inkBounds(in rect: CGRect, against background: RGB, minimumDistance: Int) -> CGRect? {
        guard let area = local(rect) else { return nil }
        let threshold = minimumDistance * minimumDistance
        var rows: [(count: Int, minX: Int, maxX: Int)] = []
        rows.reserveCapacity(area.rows.count)
        for y in area.rows {
            var row = (count: 0, minX: Int.max, maxX: Int.min)
            var p = pixel(area.columns.lowerBound, y)
            var x = 0
            while x < area.columns.count {
                if Self.distanceSquared(p, background) >= threshold {
                    row.count += 1
                    if x < row.minX { row.minX = x }
                    row.maxX = x
                }
                p += 4
                x += 1
            }
            rows.append(row)
        }

        // Bands: maximal runs of rows that contain ink.
        var bands: [(first: Int, last: Int, ink: Int)] = []
        for (i, row) in rows.enumerated() where row.count > 0 {
            if let last = bands.last, last.last == i - 1 {
                bands[bands.count - 1] = (last.first, i, last.ink + row.count)
            } else {
                bands.append((i, i, row.count))
            }
        }
        guard !bands.isEmpty else { return nil }
        if bands.count > 1 {
            let strongest = bands.map(\.ink).max() ?? 0
            if bands[0].first == 0, bands[0].ink * 4 < strongest { bands.removeFirst() }
            if let last = bands.last, bands.count > 1, last.last == rows.count - 1, last.ink * 4 < strongest {
                bands.removeLast()
            }
        }
        let kept = rows[bands[0].first...bands[bands.count - 1].last].filter { $0.count > 0 }
        let minX = kept.map(\.minX).min() ?? 0, maxX = kept.map(\.maxX).max() ?? 0
        return CGRect(x: area.columns.lowerBound + minX + originX, y: area.rows.lowerBound + bands[0].first + originY,
                      width: maxX - minX + 1, height: bands[bands.count - 1].last - bands[0].first + 1)
    }

    /// Ink pixels per column of `rect`, counted like `inkBounds`. `firstColumn` is the snapshot x of the first
    /// count. nil when `rect` lies outside the bitmap.
    func columnInk(in rect: CGRect, against background: RGB, minimumDistance: Int) -> (firstColumn: Int, counts: [Int])? {
        guard let area = local(rect) else { return nil }
        let threshold = minimumDistance * minimumDistance
        var counts = [Int](repeating: 0, count: area.columns.count)
        counts.withUnsafeMutableBufferPointer { counts in
            guard let counts = counts.baseAddress else { return }
            for y in area.rows {
                var p = pixel(area.columns.lowerBound, y)
                var x = 0
                while x < area.columns.count {
                    if Self.distanceSquared(p, background) >= threshold { counts[x] += 1 }
                    p += 4
                    x += 1
                }
            }
        }
        return (area.columns.lowerBound + originX, counts)
    }

    /// `rgb` as an opaque colour in the screenshot's colour space.
    func color(_ rgb: RGB) -> NSColor {
        var components: [CGFloat] = [CGFloat(rgb.r) / 255, CGFloat(rgb.g) / 255, CGFloat(rgb.b) / 255, 1]
        return NSColor(colorSpace: nsColorSpace, components: &components, count: components.count)
    }

    // MARK: - Private

    /// Snapshot pixel rect → the bitmap rows and columns it covers; nil if none.
    private func local(_ rect: CGRect) -> (rows: Range<Int>, columns: Range<Int>)? {
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let shifted = rect.offsetBy(dx: -CGFloat(originX), dy: -CGFloat(originY)).integral
        let minX = max(0, Int(shifted.minX)), maxX = min(width, Int(shifted.maxX))
        let minY = max(0, Int(shifted.minY)), maxY = min(height, Int(shifted.maxY))
        guard minX < maxX, minY < maxY else { return nil }
        return (minY..<maxY, minX..<maxX)
    }

    private func pixel(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> {
        bytes + (y * width + x) * 4
    }

    /// Adds the pixels of one row span to a 3 × 256 per-channel histogram; returns how many there were.
    private func accumulate(row y: Int, columns: Range<Int>, into histogram: UnsafeMutablePointer<Int>) -> Int {
        guard !columns.isEmpty else { return 0 }
        var p = pixel(columns.lowerBound, y)
        var x = 0
        while x < columns.count {
            histogram[Int(p[0])] += 1
            histogram[256 + Int(p[1])] += 1
            histogram[512 + Int(p[2])] += 1
            p += 4
            x += 1
        }
        return columns.count
    }

    private static func distanceSquared(_ p: UnsafeMutablePointer<UInt8>, _ color: RGB) -> Int {
        let dr = Int(p[0]) - Int(color.r)
        let dg = Int(p[1]) - Int(color.g)
        let db = Int(p[2]) - Int(color.b)
        return dr * dr + dg * dg + db * db
    }
}
