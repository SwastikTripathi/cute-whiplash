import AppKit

/// kitty running full-screen on a 16" notched MacBook Pro (2056×1329 pt, 2x): a black strip beside the notch and
/// a dark terminal packed edge to edge with ~58 lines of text — prompts, a git log, a failing test run with a stack
/// trace, a box-drawing coverage table, inverse-video PASS/FAIL labels and a long tail of server logs. The worst
/// case for peeling text off the screen: thousands of letters, in every part of it. Stands in for the user's real
/// screen in demos and tests, with exact per-character ground truth (`groundTruthGlyphs`) like `FakeBackdrop`.
enum DenseBackdrop {
    static let screenSize = CGSize(width: 2056, height: 1329)
    static let scale: CGFloat = 2
    /// The black strip beside the notch a full-screen app leaves empty.
    static let notchStrip: CGFloat = 38
    static let font = NSFont(name: "Menlo", size: 14) ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    static let background = NSColor(srgbRed: 0.075, green: 0.078, blue: 0.106, alpha: 1)
    static let lineHeight: CGFloat = 21.4
    static let margin: CGFloat = 14

    /// kitty's window: the whole screen below the notch strip, scene (and Cocoa, for a screen at the origin) coords.
    static var terminalRect: CGRect {
        CGRect(x: 0, y: 0, width: screenSize.width, height: screenSize.height - notchStrip)
    }

    /// A run of text in one colour, optionally on its own background (inverse video).
    struct Span {
        let text: String
        let color: NSColor
        var background: NSColor?
    }

    enum Palette {
        static let text = NSColor(white: 0.86, alpha: 1)
        static let dim = NSColor(white: 0.52, alpha: 1)
        static let prompt = NSColor(srgbRed: 0.52, green: 0.88, blue: 0.52, alpha: 1)
        static let path = NSColor(srgbRed: 0.45, green: 0.68, blue: 1, alpha: 1)
        static let branch = NSColor(srgbRed: 0.83, green: 0.55, blue: 1, alpha: 1)
        static let hash = NSColor(srgbRed: 0.95, green: 0.78, blue: 0.35, alpha: 1)
        static let decoration = NSColor(srgbRed: 0.4, green: 0.85, blue: 0.9, alpha: 1)
        static let error = NSColor(srgbRed: 1, green: 0.42, blue: 0.42, alpha: 1)
        static let warning = NSColor(srgbRed: 1, green: 0.8, blue: 0.35, alpha: 1)
        static let info = NSColor(srgbRed: 0.45, green: 0.8, blue: 0.95, alpha: 1)
        static let table = NSColor(srgbRed: 0.42, green: 0.55, blue: 0.62, alpha: 1)
        static let good = NSColor(srgbRed: 0.35, green: 0.8, blue: 0.45, alpha: 1)
        static let bad = NSColor(srgbRed: 0.93, green: 0.33, blue: 0.33, alpha: 1)
        static let label = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1)
    }

    /// The screen's text, top to bottom: one array of spans per line.
    static let lines: [[Span]] = {
        typealias P = Palette
        func plain(_ text: String, _ color: NSColor = P.text) -> [Span] { [Span(text: text, color: color)] }
        func prompt(_ command: String) -> [Span] { [Span(text: "$ ", color: P.prompt), Span(text: command, color: P.text)] }
        func context(_ took: String) -> [Span] {
            [Span(text: "~/work/payments-api", color: P.path), Span(text: " on ", color: P.dim),
             Span(text: "main [!?]", color: P.branch), Span(text: " via node v20.11.1", color: P.prompt),
             Span(text: " took \(took)", color: P.warning)]
        }
        func commit(_ hash: String, _ decoration: String?, _ message: String) -> [Span] {
            [Span(text: "* ", color: P.hash), Span(text: hash, color: P.hash)]
                + (decoration.map { [Span(text: " (\($0))", color: P.decoration)] } ?? [])
                + [Span(text: " " + message, color: P.text)]
        }
        func verdict(_ pass: Bool, _ file: String, _ time: String) -> [Span] {
            [Span(text: " ", color: P.text),
             Span(text: pass ? " PASS " : " FAIL ", color: P.label, background: pass ? P.good : P.bad),
             Span(text: " " + file, color: P.text), Span(text: " (\(time))", color: P.dim)]
        }
        func frame(_ at: String, _ location: String) -> [Span] {
            [Span(text: "      at ", color: P.dim), Span(text: at, color: P.text), Span(text: " (\(location))", color: P.path)]
        }
        func row(_ cells: [String], _ colors: [NSColor]) -> [Span] {
            var spans = [Span(text: "│", color: P.table)]
            for (cell, color) in zip(cells, colors) {
                spans.append(Span(text: cell, color: color))
                spans.append(Span(text: "│", color: P.table))
            }
            return spans
        }
        func log(_ time: String, _ level: String, _ source: String, _ message: String) -> [Span] {
            let color: NSColor = level == "ERROR" ? P.error : level == "WARN " ? P.warning : P.info
            return [Span(text: "2026-09-24T14:02:\(time)Z ", color: P.dim), Span(text: level, color: color),
                    Span(text: " " + source.padding(toLength: 10, withPad: " ", startingAt: 0), color: P.branch),
                    Span(text: message, color: level == "ERROR" ? P.error : P.text)]
        }
        let widths = [32, 9, 10, 9, 9, 40]
        func cells(_ values: [String]) -> [String] {
            zip(values, widths).map { value, width in
                let text = " " + value
                return text.padding(toLength: width, withPad: " ", startingAt: 0)
            }
        }
        func rule(_ left: String, _ middle: String, _ right: String) -> [Span] {
            plain(left + widths.map { String(repeating: "─", count: $0) }.joined(separator: middle) + right, P.table)
        }
        let metric = [P.text, P.good, P.good, P.good, P.good, P.dim]
        let weak = [P.text, P.warning, P.bad, P.warning, P.warning, P.dim]

        return [
            context("3s"),
            prompt("git log --oneline --graph --decorate -n 8"),
            commit("9f3c2a1", "HEAD -> main, origin/main", "fix(ledger): round half-even when settling multi-currency refunds so INR and JPY payouts stop drifting by a paisa (#4127)"),
            commit("44be0d7", nil, "perf(api): batch idempotency-key lookups; p99 latency 212ms -> 38ms on /v2/charges under a 4k rps load test, see dashboards/api-latency for the before and after"),
            commit("e1d09c3", nil, "chore(deps): bump @aws-sdk/client-s3 from 3.540.0 to 3.563.0 and typescript from 5.4.3 to 5.4.5"),
            commit("7a2b8f0", "tag: v4.18.2", "feat(webhooks): exponential backoff with jitter, dead-letter queue after 12 attempts, replay endpoint for support"),
            commit("0c6e5d4", nil, "test: settlement spec now uses fake timers instead of sleeping 250ms and hoping for the best"),
            commit("5d8e2c7", nil, "fix: stop leaking card fingerprints into structured logs (PCI scope reduction, SEC-212)"),
            commit("2a7f4b1", nil, "refactor(ledger)!: split LedgerEntry into Debit and Credit value types; migrate 14 call sites and the nightly reconciliation job"),
            context("1s"),
            prompt("npm run test -- --coverage --runInBand"),
            plain("> payments-api@4.18.2 test", P.dim),
            plain("> jest --config jest.config.ts --coverage --runInBand --detectOpenHandles", P.dim),
            verdict(true, "src/ledger/__tests__/rounding.spec.ts", "4.12 s"),
            verdict(true, "src/api/__tests__/charges.idempotency.spec.ts", "6.87 s"),
            verdict(false, "src/webhooks/__tests__/retry.spec.ts", "12.04 s"),
            plain("  ● webhook retries › gives up after 12 attempts and parks the event in the dead-letter queue", P.error),
            [Span(text: "    expect(", color: P.dim), Span(text: "received", color: P.error), Span(text: ").toBe(", color: P.dim),
             Span(text: "expected", color: P.good), Span(text: ") // Object.is equality", color: P.dim)],
            [Span(text: "    Expected: ", color: P.text), Span(text: "12", color: P.good)],
            [Span(text: "    Received: ", color: P.text), Span(text: "13", color: P.error)],
            frame("Object.<anonymous>", "src/webhooks/__tests__/retry.spec.ts:88:31"),
            frame("RetryScheduler.schedule", "src/webhooks/retry.ts:141:9"),
            frame("processTicksAndRejections", "node:internal/process/task_queues:95:5"),
            frame("async Promise.all", "index 3"),
            frame("async DeliveryWorker.drain", "src/webhooks/worker.ts:62:15"),
            verdict(true, "src/settlement/__tests__/payouts.spec.ts", "9.55 s"),
            rule("┌", "┬", "┐"),
            row(cells(["File", "% Stmts", "% Branch", "% Funcs", "% Lines", "Uncovered Line #s"]),
                [P.text, P.text, P.text, P.text, P.text, P.text]),
            rule("├", "┼", "┤"),
            row(cells(["src/ledger/rounding.ts", "98.41", "95.00", "100.00", "98.36", "77"]), metric),
            row(cells(["src/api/charges.ts", "91.07", "84.61", "93.33", "90.90", "45-51,203,288-290"]), metric),
            row(cells(["src/webhooks/retry.ts", "72.30", "61.53", "80.00", "71.87", "58-66,141-155,190"]), weak),
            row(cells(["src/settlement/payouts.ts", "88.88", "79.16", "90.47", "88.23", "112-118,301"]), metric),
            rule("└", "┴", "┘"),
            [Span(text: "Test Suites: ", color: P.text), Span(text: "1 failed", color: P.error), Span(text: ", ", color: P.text),
             Span(text: "3 passed", color: P.good), Span(text: ", 4 total", color: P.text)],
            [Span(text: "Tests:       ", color: P.text), Span(text: "1 failed", color: P.error), Span(text: ", ", color: P.text),
             Span(text: "211 passed", color: P.good), Span(text: ", 212 total", color: P.text)],
            plain("Time:        33.61 s, estimated 41 s"),
            context("34s"),
            prompt("kubectl logs -n payments deploy/payments-api --since=2m --all-containers | grep -v healthz | tail -n 14"),
            log("11.482", "INFO ", "http", "POST /v2/charges 201 38ms req_id=7f3a9c01 merchant=m_48213 amount=129900 currency=INR idempotency_key=ik_2Hf8sQ"),
            log("11.519", "INFO ", "http", "POST /v2/charges 201 41ms req_id=7f3a9c02 merchant=m_10077 amount=4500 currency=USD idempotency_key=ik_9Lk2pZ"),
            log("11.604", "WARN ", "ledger", "settlement window drift 1.8s exceeds the 1.5s threshold; clock skew on node ip-10-4-17-201.ap-south-1.compute.internal?"),
            log("11.733", "ERROR", "webhooks", "delivery failed endpoint=https://hooks.example.com/payments status=503 attempt=12/12 -> moved to DLQ event=evt_7Qm3"),
            log("11.801", "INFO ", "http", "GET /v2/charges/ch_3PzK9 200 12ms req_id=7f3a9c05 merchant=m_48213 cache=hit region=ap-south-1"),
            log("11.922", "INFO ", "payouts", "batch 2026-09-24/17 scheduled: 1,284 payouts, 9,812,334.50 INR, cutoff 14:30 IST, bank=HDFC NEFT"),
            log("12.047", "WARN ", "db", "slow query 1,204ms: SELECT * FROM ledger_entries WHERE merchant_id = $1 AND created_at > $2 ORDER BY id"),
            log("12.310", "ERROR", "api", "TypeError: Cannot read properties of undefined (reading 'currency') at normalizeAmount (src/api/money.ts:31:18)"),
            log("12.311", "ERROR", "api", "    at ChargeController.create (src/api/charges.ts:203:22) req_id=7f3a9c09 merchant=m_77310"),
            log("12.402", "INFO ", "audit", "{\"event\":\"api_key.rotated\",\"actor\":\"usr_4Kd81\",\"merchant\":\"m_10077\",\"key_prefix\":\"sk_live_51Nx\",\"ip\":\"103.21.244.17\",\"user_agent\":\"payments-cli/2.3.0 (darwin; arm64)\",\"previous_key_revoked_at\":\"2026-09-24T14:02:12.401Z\",\"reason\":\"scheduled 90-day rotation\"}"),
            log("12.450", "INFO ", "http", "POST /v2/refunds 202 55ms req_id=7f3a9c0b merchant=m_10077 refund=re_1Nq7 amount=4500 reason=duplicate"),
            log("12.698", "INFO ", "webhooks", "replayed 3 events from DLQ for merchant=m_20981 by support@payments.internal (ticket SUP-5531)"),
            log("12.955", "INFO ", "http", "POST /v2/charges 201 36ms req_id=7f3a9c0e merchant=m_31415 amount=99900 currency=INR idempotency_key=ik_4Tq1vB"),
            log("13.018", "ERROR", "ledger", "invariant violated: sum(debits) != sum(credits) for batch 2026-09-24/17 (diff 0.01 INR); halting payouts"),
            log("13.102", "INFO ", "pager", "incident INC-2231 opened: payouts halted, assigned to on-call @swastik (ack within 5 min)"),
            log("12.904", "WARN ", "http", "rate limit 80% for merchant=m_48213 (3,210/4,000 req/min); consider raising the plan or batching captures"),
            context("2s"),
            [Span(text: "$ ", color: P.prompt), Span(text: "vim src/webhooks/retry.ts ", color: P.text),
             Span(text: "█", color: P.text)],
        ]
    }()

    struct Rendered {
        /// Full image at `scale` pixels per point; row 0 is the top of the screen.
        let image: CGImage
        let size: CGSize
        let scale: CGFloat
    }

    static func render(scale: CGFloat = scale) -> Rendered {
        let size = screenSize
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSColor.black.setFill()
        CGRect(origin: .zero, size: size).fill()
        background.setFill()
        terminalRect.fill()
        for line in layout() {
            for cell in line where cell.background != nil {
                cell.background?.setFill()
                cell.rect.fill()
            }
            for cell in line {
                (cell.text as NSString).draw(at: CGPoint(x: cell.rect.minX, y: cell.rect.minY + textInset),
                                             withAttributes: [.font: font, .foregroundColor: cell.color])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return Rendered(image: ctx.makeImage()!, size: size, scale: scale)
    }

    /// The screen as if it were a real capture of a screen at Cocoa origin (0,0).
    static func snapshot(_ rendered: Rendered = render()) -> ScreenSnapshot {
        ScreenSnapshot(image: rendered.image, screenFrame: CGRect(origin: .zero, size: rendered.size), scale: rendered.scale)
    }

    /// Every character of the screen (what a perfect OCR would return), with crops of `rendered`'s image.
    static func groundTruthGlyphs(_ rendered: Rendered = render()) -> [GlyphSample] {
        layout().flatMap { line in
            line.filter { !$0.text.first!.isWhitespace }.map { cell in
                let pixels = CoordinateSpace.imagePixels(fromScene: cell.rect, sceneHeight: rendered.size.height, scale: rendered.scale)
                return GlyphSample(text: cell.text, rect: cell.rect, image: rendered.image.cropping(to: pixels), color: cell.color,
                                   background: cell.background ?? background, fontSize: font.pointSize)
            }
        }
    }

    /// Text sits in the middle of its row, like kitty's.
    private static let textInset = (lineHeight - ("Mg" as NSString).size(withAttributes: [.font: font]).height) / 2

    /// One character cell: its box in scene coordinates (the full row height, like a terminal cell).
    struct Cell {
        let text: String
        let rect: CGRect
        let color: NSColor
        let background: NSColor?
    }

    /// Character cells line by line, top to bottom; long lines wrap at the right edge like kitty's.
    static func layout() -> [[Cell]] {
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let columns = Int((screenSize.width - 2 * margin) / advance)
        var rows: [[Cell]] = []
        var current: [Cell] = []
        for spans in lines {
            current = []
            for span in spans {
                for character in span.text {
                    if current.count == columns {
                        rows.append(current)
                        current = []
                    }
                    let column = current.count
                    let row = rows.count
                    let rect = CGRect(x: margin + CGFloat(column) * advance,
                                      y: terminalRect.maxY - 8 - CGFloat(row + 1) * lineHeight,
                                      width: advance, height: lineHeight)
                    current.append(Cell(text: String(character), rect: rect, color: span.color, background: span.background))
                }
            }
            rows.append(current)
        }
        return rows
    }
}
