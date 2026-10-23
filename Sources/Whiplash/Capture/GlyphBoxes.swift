import CoreGraphics

/// Pure geometry behind OCR: per-character boxes for a recognized line, and reading order of lines.
///
/// Vision reports solid boxes for lines and words, but its per-character boxes are often degenerate — the
/// `.accurate` recognizer returns the whole word's box for every character — and its word boxes reach about
/// halfway into the neighbouring spaces. So each word is measured again from its pixels (an `InkProfile`), and
/// its characters are placed, in order of preference, by:
/// 1. genuine per-character boxes, when the recognizer produced them;
/// 2. the monospaced grid: cells one pitch wide, placed where their boundaries cut through the least ink
///    (terminal text — exact to about a pixel);
/// 3. an even split of the word's ink (proportional text).
///
/// Everything here works in one rect space chosen by the caller (TextHarvester uses scene points); nothing
/// depends on Vision itself, so it is unit-testable.
enum GlyphBoxes {
    struct Box: Equatable {
        let character: Character
        let rect: CGRect
    }

    /// One laid-out line: its character boxes, and its character pitch when it is monospaced.
    struct Line {
        var boxes: [Box]
        var pitch: CGFloat?
    }

    /// How much ink each pixel column across a word holds.
    struct InkProfile {
        /// Left edge of column 0, and the width of one column (one pixel).
        let originX: CGFloat
        let step: CGFloat
        let columns: [Int]

        /// Left edge of the first inked column to the right edge of the last; nil without ink.
        var extent: ClosedRange<CGFloat>? {
            guard let first = columns.firstIndex(where: { $0 > 0 }),
                  let last = columns.lastIndex(where: { $0 > 0 }) else { return nil }
            return (originX + CGFloat(first) * step)...(originX + CGFloat(last + 1) * step)
        }

        /// Ink in the column containing `x`; 0 outside the profile.
        func ink(at x: CGFloat) -> Int {
            let column = Int(((x - originX) / step).rounded(.down))
            return columns.indices.contains(column) ? columns[column] : 0
        }
    }

    /// Boxes for every non-whitespace character of `text`, left to right.
    ///
    /// - Parameters:
    ///   - lineBox: the whole line's box. Every character box spans the line's full height, so crops of one
    ///     line line up and keep ascenders and descenders.
    ///   - boxFor: the recognizer's box for a range of `text`, nil when it has none.
    ///   - inkProfile: the ink across a word box (already given the line's height); nil when unknown.
    static func layout(text: String, lineBox: CGRect, boxFor: (Range<String.Index>) -> CGRect?,
                       inkProfile: (CGRect) -> InkProfile? = { _ in nil }) -> Line {
        let characterCount = text.count
        guard characterCount > 0, lineBox.width > 0, lineBox.height > 0 else { return Line(boxes: [], pitch: nil) }
        // Width of one character if the whole line were split evenly; only used when a word has no box.
        let lineCell = lineBox.width / CGFloat(characterCount)

        var words: [(range: Range<String.Index>, count: Int, rect: CGRect)] = []
        var wordStart: (index: String.Index, offset: Int)?
        var offset = 0
        func endWord(at end: String.Index) {
            guard let start = wordStart else { return }
            let count = offset - start.offset
            let range = start.index..<end
            let box = boxFor(range).flatMap { $0.width > 0 ? $0 : nil }
            let minX = box?.minX ?? lineBox.minX + CGFloat(start.offset) * lineCell
            let width = box?.width ?? CGFloat(count) * lineCell
            words.append((range, count, CGRect(x: minX, y: lineBox.minY, width: width, height: lineBox.height)))
            wordStart = nil
        }
        for index in text.indices {
            if text[index].isWhitespace {
                endWord(at: index)
            } else if wordStart == nil {
                wordStart = (index, offset)
            }
            offset += 1
        }
        endWord(at: text.endIndex)

        let rects = separate(words.map(\.rect))
        let profiles = rects.map(inkProfile)
        let pitch = monospacedPitch(words: zip(profiles, words).compactMap { profile, word in
            profile.map { ($0, word.count) }
        })

        var boxes: [Box] = []
        for ((word, rect), profile) in zip(zip(words, rects), profiles) {
            let indices = Array(text[word.range].indices)
            let characterRects = indices.map { boxFor($0..<text.index(after: $0)) }
            let inkRect = profile?.extent.map { CGRect(x: $0.lowerBound, y: rect.minY, width: $0.upperBound - $0.lowerBound, height: rect.height) }
            let spans = characterSpans(characterRects, in: rect)
                ?? pitch.flatMap { pitch in profile.flatMap { gridSpans($0, count: word.count, pitch: pitch) } }
                ?? evenSpans(of: inkRect ?? rect, count: word.count)
            for (index, span) in zip(indices, spans) {
                boxes.append(Box(character: text[index],
                                 rect: CGRect(x: span.lowerBound, y: lineBox.minY,
                                              width: span.upperBound - span.lowerBound, height: lineBox.height)))
            }
        }
        return Line(boxes: boxes, pitch: pitch)
    }

    /// Trims horizontally overlapping neighbours (left-to-right boxes of one line) back to the midpoint of their
    /// overlap, so measuring one word's ink never picks up the next word.
    static func separate(_ rects: [CGRect]) -> [CGRect] {
        rects.indices.map { i in
            var rect = rects[i]
            if i > 0, rects[i - 1].maxX > rect.minX {
                let cut = (rects[i - 1].maxX + rects[i].minX) / 2
                rect = CGRect(x: cut, y: rect.minY, width: max(0, rect.maxX - cut), height: rect.height)
            }
            if i + 1 < rects.count, rects[i + 1].minX < rect.maxX {
                let cut = max(rect.minX, (rects[i].maxX + rects[i + 1].minX) / 2)
                rect = CGRect(x: rect.minX, y: rect.minY, width: cut - rect.minX, height: rect.height)
            }
            return rect
        }
    }

    /// The character pitch of a line if it is monospaced, else nil.
    ///
    /// First guess: total ink width over total characters of the words with three or more characters (a word's
    /// ink falls short of its cells by the side bearings of its first and last letters, about a quarter of a
    /// cell — hence `count - 0.25`). Because a 1 % error drifts a 40-character path by 3.6 pt, the guess is then
    /// refined: of the pitches within ±3 % whose cell boundaries cut through the least ink across the whole
    /// line, the middle one wins. Monospaced text leaves those boundaries almost clean (≤ 0.6 % of the line's
    /// ink on FakeBackdrop's terminal); proportional text doesn't (2–50 %), so more than `maximumBoundaryInk`
    /// means "not monospaced".
    static func monospacedPitch(words: [(profile: InkProfile, count: Int)]) -> CGFloat? {
        var inkWidth: CGFloat = 0, cells: CGFloat = 0, totalInk = 0
        for word in words {
            totalInk += word.profile.columns.reduce(0, +)
            guard word.count >= 3, let extent = word.profile.extent else { continue }
            inkWidth += extent.upperBound - extent.lowerBound
            cells += CGFloat(word.count) - 0.25
        }
        guard cells > 0, inkWidth > 0, totalInk > 0 else { return nil }
        let guess = inkWidth / cells
        let scored = (-6...6).map { step -> (pitch: CGFloat, cost: Int) in
            let pitch = guess * (1 + CGFloat(step) * 0.005)
            let cost = words.reduce(0) { total, word in
                // A word the grid can't hold counts as fully cut: that pitch is wrong for it.
                total + (gridPlacement(word.profile, count: word.count, pitch: pitch)?.cost ?? word.profile.columns.reduce(0, +))
            }
            return (pitch, cost)
        }
        guard let lowest = scored.map(\.cost).min(),
              CGFloat(lowest) <= CGFloat(totalInk) * maximumBoundaryInk else { return nil }
        let cheapest = scored.filter { $0.cost == lowest }
        return cheapest[cheapest.count / 2].pitch
    }

    /// Share of a line's ink that its monospaced cell boundaries may cross (dashes and underscores touch them).
    static let maximumBoundaryInk: CGFloat = 0.015

    /// `count` touching cells of width `pitch` laid over the word's ink where the boundaries between cells cross
    /// the least ink: monospaced letters sit inside their cells, so the true boundaries run through the gaps
    /// between letters. nil when the ink is too wide or too narrow for `count` cells — proportional text.
    static func gridSpans(_ profile: InkProfile, count: Int, pitch: CGFloat) -> [ClosedRange<CGFloat>]? {
        guard let start = gridPlacement(profile, count: count, pitch: pitch)?.start else { return nil }
        return (0..<count).map { i in
            let left = start + CGFloat(i) * pitch
            return left...(left + pitch)
        }
    }

    /// Where the grid of `gridSpans` starts, and how much ink its inner boundaries cross. The grid slides in
    /// half-pixel steps over every position that keeps all the ink inside it; of the positions that cross the
    /// least ink, the middle one wins, which runs the boundaries down the middle of the gaps between letters.
    static func gridPlacement(_ profile: InkProfile, count: Int, pitch: CGFloat) -> (start: CGFloat, cost: Int)? {
        guard let ink = profile.extent, count > 0, pitch > 0, profile.step > 0 else { return nil }
        let width = CGFloat(count) * pitch
        let inkWidth = ink.upperBound - ink.lowerBound
        guard inkWidth <= width + profile.step, inkWidth >= CGFloat(count - 1) * pitch * 0.75 else { return nil }

        func cost(at start: CGFloat) -> Int {
            var cost = 0
            for boundary in 1..<max(1, count) {
                cost += profile.ink(at: start + CGFloat(boundary) * pitch)
            }
            return cost
        }
        let earliest = ink.upperBound - width
        var lowest = Int.max
        var cheapest: [CGFloat] = []
        for start in stride(from: earliest, through: max(earliest, ink.lowerBound), by: profile.step / 2) {
            let cost = cost(at: start)
            if cost < lowest {
                lowest = cost
                cheapest = [start]
            } else if cost == lowest {
                cheapest.append(start)
            }
        }
        guard let first = cheapest.first, let last = cheapest.last else { return nil }
        let middle = (first + last) / 2
        return (cost(at: middle) == lowest ? middle : cheapest[cheapest.count / 2], lowest)
    }

    /// Horizontal spans from genuine per-character boxes, tiled so neighbours meet halfway between their ink.
    /// nil when the boxes are degenerate: missing, as wide as the word, out of order or outside the word.
    static func characterSpans(_ rects: [CGRect?], in word: CGRect) -> [ClosedRange<CGFloat>]? {
        guard rects.count > 1 else { return nil } // one character: nothing to learn beyond the word box
        let fairWidth = word.width / CGFloat(rects.count)
        var boxes: [CGRect] = []
        for rect in rects {
            guard let rect, rect.width > 0,
                  rect.width <= fairWidth * 1.75,
                  rect.midX > (boxes.last?.midX ?? -.infinity),
                  rect.midX >= word.minX - fairWidth / 2, rect.midX <= word.maxX + fairWidth / 2
            else { return nil }
            boxes.append(rect)
        }
        var spans: [ClosedRange<CGFloat>] = []
        var left = boxes[0].minX
        for i in boxes.indices {
            let right = i + 1 < boxes.count ? max(left, (boxes[i].maxX + boxes[i + 1].minX) / 2) : max(left, boxes[i].maxX)
            spans.append(left...right)
            left = right
        }
        return spans
    }

    /// `count` equal, touching spans covering `word`.
    static func evenSpans(of word: CGRect, count: Int) -> [ClosedRange<CGFloat>] {
        guard count > 0 else { return [] }
        let width = word.width / CGFloat(count)
        return (0..<count).map { i in
            let left = word.minX + CGFloat(i) * width
            return left...(left + width)
        }
    }

    /// Indices of `lines` (y-up boxes) in reading order: rows top to bottom, left to right within a row.
    /// Boxes whose vertical centres are closer than half the smaller height share a row, which keeps
    /// fragments of one visual line (Vision sometimes splits a line in two) together.
    static func readingOrder(of lines: [CGRect]) -> [Int] {
        let byTop = lines.indices.sorted { lines[$0].midY > lines[$1].midY }
        var rows: [[Int]] = []
        for index in byTop {
            if let anchor = rows.last?.first,
               abs(lines[anchor].midY - lines[index].midY) < min(lines[anchor].height, lines[index].height) / 2 {
                rows[rows.count - 1].append(index)
            } else {
                rows.append([index])
            }
        }
        return rows.flatMap { row in row.sorted { lines[$0].minX < lines[$1].minX } }
    }
}
