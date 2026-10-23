import CoreGraphics

/// Where the text is on a screenshot, without OCR: a coarse grid counting the fine, high-contrast detail (letter
/// strokes) in each cell. Strikes aim at it, so a hit lands in text and has letters to knock loose instead of
/// cracking the empty right-hand side of a terminal. A few milliseconds for a full screen, so it is ready before the
/// first strike, unlike OCR.
struct InkMap {
    /// Cell size, points.
    let cell: CGFloat
    let columns: Int
    let rows: Int
    /// Summed-area table of per-cell ink, (rows + 1) × (columns + 1); row 0 is the bottom of the screen (y-up).
    private let sums: [Float]

    /// Pixels per point the screenshot is sampled at: enough for 11–16 pt text to keep its stroke edges.
    private static let sampling: CGFloat = 0.5
    /// A step in brightness at least this big (0...255) between neighbouring samples is a stroke edge.
    private static let edgeThreshold: Int = 28

    /// `image` covers the whole scene (row 0 = top of the screen, like any CGImage).
    init?(image: CGImage, sceneSize: CGSize, cell: CGFloat = 24) {
        let width = Int(sceneSize.width * Self.sampling), height = Int(sceneSize.height * Self.sampling)
        guard width > 2, height > 2, cell > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let gray = data.bindMemory(to: UInt8.self, capacity: width * height)

        self.cell = cell
        columns = max(1, Int(ceil(sceneSize.width / cell)))
        rows = max(1, Int(ceil(sceneSize.height / cell)))
        var ink = [Float](repeating: 0, count: columns * rows)
        let pointsPerSample = 1 / Self.sampling
        // The bitmap's first row in memory is the top of the image; flip to y-up rows.
        for y in 0..<(height - 1) {
            let row = gray + y * width, below = gray + (y + 1) * width
            let cellRow = min(rows - 1, Int(CGFloat(height - 1 - y) * pointsPerSample / cell))
            for x in 0..<(width - 1) {
                let v = Int(row[x])
                if abs(v - Int(row[x + 1])) >= Self.edgeThreshold || abs(v - Int(below[x])) >= Self.edgeThreshold {
                    let cellColumn = min(columns - 1, Int(CGFloat(x) * pointsPerSample / cell))
                    ink[cellRow * columns + cellColumn] += 1
                }
            }
        }
        var sums = [Float](repeating: 0, count: (rows + 1) * (columns + 1))
        for r in 0..<rows {
            var rowSum: Float = 0
            for c in 0..<columns {
                rowSum += ink[r * columns + c]
                sums[(r + 1) * (columns + 1) + c + 1] = sums[r * (columns + 1) + c + 1] + rowSum
            }
        }
        self.sums = sums
    }

    /// Ink inside `rect` (scene points), rounded out to whole cells.
    func ink(in rect: CGRect) -> Float {
        let c0 = max(0, min(columns, Int(floor(rect.minX / cell)))), c1 = max(0, min(columns, Int(ceil(rect.maxX / cell))))
        let r0 = max(0, min(rows, Int(floor(rect.minY / cell)))), r1 = max(0, min(rows, Int(ceil(rect.maxY / cell))))
        guard c1 > c0, r1 > r0 else { return 0 }
        let stride = columns + 1
        return sums[r1 * stride + c1] - sums[r0 * stride + c1] - sums[r1 * stride + c0] + sums[r0 * stride + c0]
    }

    /// Ink within a box of half-size `radius` (wider than tall, like a line of text) around `p`.
    func ink(around p: CGPoint, radius: CGFloat) -> Float {
        ink(in: CGRect(x: p.x - radius * 1.25, y: p.y - radius * 0.8, width: radius * 2.5, height: radius * 1.6))
    }
}
